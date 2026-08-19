#!/usr/bin/env python3
"""
plot_handshake_total.py -- Aggregate and plot total handshake times.

Reads the raw measurement files produced by initiator_bench.sh, keeping only the
total handshake duration (the per-stage files -- keygen, decaps, encaps,
searchpeer -- are ignored), and draws a bar chart of the mean handshake time
against the number of peers known to the responder, with standard deviation
error bars.

This script only reads existing measurements; it never runs a benchmark. Run the
full series first, for every peer count of interest.

Usage:
    python3 plot_handshake_total.py
    python3 plot_handshake_total.py --dir results_initiator --peers 1 10 100
    python3 plot_handshake_total.py --latest --unit us --show-range

Expected input files:
    <dir>/raw_<peers>peers_<timestamp>_total.txt
one integer per line, as written by initiator_bench.sh.
"""

import argparse
import csv
import glob
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

DEFAULT_PEERS = [1, 10, 100, 500, 1000, 3000]

# Multiplier converting one raw kernel unit into milliseconds.
UNIT_TO_MS = {"ns": 1e-6, "us": 1e-3, "ms": 1.0}


def parse_args():
    p = argparse.ArgumentParser(
        description="Plot total SCH-WireGuard handshake time versus peer count."
    )
    p.add_argument("--dir", default="results_initiator",
                   help="directory holding the raw files (default: results_initiator)")
    p.add_argument("--peers", type=int, nargs="+", default=DEFAULT_PEERS,
                   help="peer counts to plot (default: 1 10 100 500 1000 3000)")
    p.add_argument("--unit", choices=sorted(UNIT_TO_MS), default="ns",
                   help="unit of the raw kernel values (default: ns)")
    p.add_argument("--latest", action="store_true",
                   help="use only the most recent series per peer count "
                        "instead of pooling every series")
    p.add_argument("--trim", type=float, default=0.0, metavar="PCT",
                   help="discard the slowest PCT%% of samples per peer count, "
                        "to limit the effect of scheduling outliers (default: 0)")
    p.add_argument("--show-range", action="store_true",
                   help="overlay min/max whiskers on top of the standard deviation")
    p.add_argument("--title", default="SCH-WireGuard handshake time versus number of known peers",
                   help="figure title")
    p.add_argument("--out", default="handshake_total",
                   help="output basename, without extension (default: handshake_total)")
    p.add_argument("--formats", nargs="+", default=["png", "pdf"],
                   help="output formats (default: png pdf)")
    p.add_argument("--dpi", type=int, default=200, help="raster output resolution")
    return p.parse_args()


def load_samples(directory, peers, latest):
    """Return {peer_count: (values, n_series)} of raw integer samples."""
    data = {}
    for n in peers:
        pattern = os.path.join(directory, f"raw_{n}peers_*_total.txt")
        files = sorted(glob.glob(pattern))
        if not files:
            print(f"  {n:>5} peers: no file matching {pattern}", file=sys.stderr)
            continue
        if latest:
            files = [files[-1]]

        values = []
        for path in files:
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        values.append(float(line))
                    except ValueError:
                        print(f"  skipping unparsable line in {path}: {line!r}",
                              file=sys.stderr)

        if not values:
            print(f"  {n:>5} peers: files found but no usable value", file=sys.stderr)
            continue

        data[n] = (np.asarray(values), len(files))
    return data


def trim_outliers(values, pct):
    """Drop the slowest pct% of samples."""
    if pct <= 0:
        return values
    cutoff = np.percentile(values, 100.0 - pct)
    return values[values <= cutoff]


def summarize(data, unit, trim):
    """Return a list of per-peer-count statistics, in milliseconds."""
    factor = UNIT_TO_MS[unit]
    rows = []
    for n in sorted(data):
        values, n_series = data[n]
        kept = trim_outliers(values, trim)
        ms = kept * factor
        rows.append({
            "peers": n,
            "series": n_series,
            "n": len(ms),
            "dropped": len(values) - len(kept),
            "mean": float(np.mean(ms)),
            "std": float(np.std(ms, ddof=1)) if len(ms) > 1 else 0.0,
            "median": float(np.median(ms)),
            "min": float(np.min(ms)),
            "max": float(np.max(ms)),
        })
    return rows


def print_table(rows):
    header = (f"{'peers':>6} {'series':>7} {'n':>6} {'mean':>9} {'std':>9} "
              f"{'median':>9} {'min':>9} {'max':>9}")
    print(header)
    print("-" * len(header))
    for r in rows:
        print(f"{r['peers']:>6} {r['series']:>7} {r['n']:>6} "
              f"{r['mean']:>9.3f} {r['std']:>9.3f} {r['median']:>9.3f} "
              f"{r['min']:>9.3f} {r['max']:>9.3f}")
    print("\nAll values in milliseconds.")


def write_csv(rows, path):
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def plot(rows, args):
    labels = [str(r["peers"]) for r in rows]
    means = np.array([r["mean"] for r in rows])
    stds = np.array([r["std"] for r in rows])
    x = np.arange(len(rows))

    fig, ax = plt.subplots(figsize=(8, 5))

    bars = ax.bar(x, means, width=0.6,
                  yerr=stds, capsize=5,
                  color="#4C72B0", edgecolor="black", linewidth=0.6,
                  error_kw={"ecolor": "black", "elinewidth": 1.0},
                  label="Mean handshake time (± std. dev.)")

    if args.show_range:
        lower = means - np.array([r["min"] for r in rows])
        upper = np.array([r["max"] for r in rows]) - means
        ax.errorbar(x, means, yerr=[lower, upper],
                    fmt="none", ecolor="#C44E52", elinewidth=1.0,
                    capsize=9, capthick=1.0, label="Min / max range")

    ax.plot(x, [r["median"] for r in rows], linestyle="none",
            marker="_", markersize=18, markeredgewidth=1.8,
            color="#DD8452", label="Median")

    top = max(r["max"] if args.show_range else r["mean"] + r["std"] for r in rows)
    for xi, bar, r in zip(x, bars, rows):
        ax.text(xi, bar.get_height() + stds[list(x).index(xi)] + 0.03 * top,
                f"{r['mean']:.3f}\nn={r['n']}",
                ha="center", va="bottom", fontsize=8)

    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_xlabel("Number of peers known to the responder")
    ax.set_ylabel("Handshake execution time (ms)")
    ax.set_title(args.title)
    ax.set_ylim(0, top * 1.25)
    ax.yaxis.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.set_axisbelow(True)
    ax.legend(loc="upper left", frameon=True)

    fig.tight_layout()
    for fmt in args.formats:
        path = f"{args.out}.{fmt}"
        fig.savefig(path, dpi=args.dpi)
        print(f"Figure written to {path}")
    plt.close(fig)


def main():
    args = parse_args()

    if not os.path.isdir(args.dir):
        sys.exit(f"Directory not found: {args.dir}")

    print(f"Reading total handshake times from {args.dir}/")
    data = load_samples(args.dir, args.peers, args.latest)
    if not data:
        sys.exit("No usable measurement found. Run the benchmark series first.")

    missing = [n for n in args.peers if n not in data]
    if missing:
        print(f"Warning: no data for peer counts {missing}", file=sys.stderr)

    rows = summarize(data, args.unit, args.trim)
    print()
    print_table(rows)

    csv_path = f"{args.out}_summary.csv"
    write_csv(rows, csv_path)
    print(f"\nSummary written to {csv_path}")

    plot(rows, args)


if __name__ == "__main__":
    main()
