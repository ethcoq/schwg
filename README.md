# WireGuard handshake timing benchmark

Three scripts to measure the execution time of individual stages of a WireGuard
handshake, as a function of the number of peers configured on the responder.

Timings come from `pr_info` statements added to the module source, which print
lines of the form:

```
[ 1505.102578] wireguard: CHECKTIME: encaps 45107
```

`pr_info` prints unconditionally at `KERN_INFO` level: no dynamic debug setup is
required, and the traces survive a module reload. The scripts capture these
lines from `dmesg`, extract the numeric values and compute per-stage statistics.

| Script | Host | Role |
|---|---|---|
| `initiator_bench.sh` | initiator | build, load, run the handshake series, compute statistics |
| `responder_setup.sh` | responder | build, load, bring up `wg0` with the right peer count |
| `responder_measures.sh` | responder | extract timings from `dmesg`, compute statistics |
| `plot_handshake_total.py` | initiator | aggregate every series and plot total handshake time |

Measured stages:

| Host | Stage | dmesg pattern |
|---|---|---|
| initiator | total handshake | `CHECKTIME: total` |
| initiator | decapsulation | `CHECKTIME: decaps` |
| initiator | ephemeral key generation | `CHECKTIME: keygen` |
| responder | encapsulation | `CHECKTIME: encaps` |
| responder | peer lookup | `CHECKTIME: searchpeer` |

## Requirements

- Two hosts on the same L2 segment, reachable over the underlay network
  (`192.168.0.11` for the responder, `192.168.0.12` for the initiator).
- Kernel headers matching the running kernel, and the module sources.
- Root privileges on both hosts.
- Responder configuration files, one per peer count, prepared in advance.

See *Test environment* below for the exact setup used to produce the published
figures.

## Test environment

The measurements reported in the paper were obtained on the following setup.
Absolute timings depend heavily on the host, so reproduce this configuration as
closely as possible before comparing numbers.

| | |
|---|---|
| Host CPU | Intel Core i7-1165G7 @ 2.80 GHz |
| Guests | 2 virtual machines (VirtualBox) |
| Guest OS | Ubuntu, kernel 6.17.0-35-generic |
| Guest RAM | 2 GB each |
| Network | VirtualBox internal network |
| ML-KEM | ML-KEM-512, PQClean implementation adapted to the kernel |
| Iterations | 100 handshakes per peer count |
| Peer counts | 1, 10, 100, 500, 1000, 3000 |

The internal network mode matters: NAT mode isolates the guests from each other
and the handshake never completes.

Measurements cover the interval from the start of `create_initiation` to the end
of `consume_response`. To force the worst case, the target peer is placed **last**
in the responder's configuration file, so every lookup traverses the full peer
list. Placing it elsewhere measures an average case instead and produces a
`searchpeer` time roughly half as large.

## Configuration

Edit the variables at the top of each script:

```bash
WG_SRC="/home/user/newwireguardv2/drivers/net/wireguard"   # module sources
CONF="./confwgB"                                           # initiator wg config
IF_LAN="enp0s3"                                            # underlay interface
IP_LAN="192.168.0.12/24"                                   # underlay address
IP_WG="10.0.0.12/24"                                       # tunnel address
```

`WG_SRC` must be an **absolute** path. `make -C` changes directory before
resolving `M=`, so a relative path is looked up inside the kernel tree and fails
with *"specified external module directory does not exist"*. To keep the path
relative to the script instead, use:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WG_SRC="${SCRIPT_DIR}/schwg/drivers/net/wireguard"
```

On the responder, `CONF_PATTERNS` lists the filename patterns tried when looking
up the configuration for a given peer count (`%s` is the peer count). Adapt it
to your naming convention, or pass the path explicitly as the second argument.

## Running one series

Order matters: the responder must be ready before the initiator starts, and the
measurements must be collected before the next setup clears the kernel buffer.

**1. Responder — prepare**

```bash
sudo ./responder_setup.sh 100
```

Builds and loads the module, brings up `wg0` with the 100-peer configuration,
and clears `dmesg`.

**2. Initiator — run the series**

```bash
sudo ./initiator_bench.sh 100
```

Waits for the responder, then runs 100 handshakes and prints per-stage
statistics. The argument is the responder's peer count, used to label the
results — it does not change the initiator's own configuration.

**3. Responder — collect**

```bash
sudo ./responder_measures.sh
```

The peer count is read back from `/tmp/wg_bench_npeers`, written by the setup
script. Pass it explicitly to override.

## Running several series

Rebuilding for every peer count is unnecessary. After the first series, use
`--skip-build` on both hosts:

```bash
# responder
sudo ./responder_setup.sh 500 --skip-build
# initiator
sudo ./initiator_bench.sh 500 --skip-build
# responder
sudo ./responder_measures.sh
```

Repeat for each peer count. Results accumulate; nothing is overwritten.

## Plotting the results

Once every peer count has been measured, run the plotting script on the
initiator, from the directory holding `results_initiator/`:

```bash
python3 plot_handshake_total.py
```

It requires Python 3 with `numpy` and `matplotlib`:

```bash
sudo apt install python3-numpy python3-matplotlib
```

The script only reads existing measurements — it never runs a benchmark. It
covers the **total** handshake time only; the per-stage files (`keygen`,
`decaps`) are ignored.

It produces:

- a summary table on standard output;
- `handshake_total_summary.csv`, one row per peer count;
- `handshake_total.png` and `handshake_total.pdf` — a bar chart of the mean
  handshake time against peer count, with standard-deviation error bars, median
  markers and the sample count above each bar. Use the PDF for inclusion in a
  LaTeX document.

**Check the unit first.** The script assumes the kernel prints nanoseconds. If
the module uses another unit, pass `--unit us` or `--unit ms`. A single-peer mean
around 1 ms indicates the unit is right; a value near 1000 or 0.001 means it is
not.

Note that `results_initiator/` already contains an example set of measurements;
see *Bundled example results* below before running your own campaign.

| Option | Effect |
|---|---|
| `--dir DIR` | directory holding the raw files (default `results_initiator`) |
| `--peers N [N ...]` | peer counts to plot (default `1 10 100 500 1000 3000`) |
| `--unit ns\|us\|ms` | unit of the raw kernel values (default `ns`) |
| `--latest` | use only the most recent series per peer count instead of pooling all |
| `--trim PCT` | discard the slowest PCT% of samples per peer count |
| `--show-range` | overlay min/max whiskers on the standard deviation |
| `--title`, `--out`, `--formats`, `--dpi` | figure title, output basename, formats, resolution |

By default every series recorded for a given peer count is pooled, which raises
`n` but mixes runs made under different conditions; `--latest` keeps a single
run. `--trim` limits the effect of scheduling outliers, which dominate the
variance — if used for published figures, state it in the caption, as it is a
methodological choice rather than formatting.

## Options of the benchmark scripts

### `initiator_bench.sh <peer_count> [iterations] [options]`

| Option | Effect |
|---|---|
| `--skip-build` | do not rebuild or reload the module |
| `--no-wait` | do not wait for confirmation before starting the loop |
| `--only-stats` | recompute statistics from the last run, run no test |

`iterations` defaults to 100. Higher values risk overflowing the kernel ring
buffer on the responder; see *Kernel ring buffer* below.

### `responder_setup.sh <peer_count> [config_path] [--skip-build]`

Warns if the number of `[Peer]` sections in the configuration file does not
match the requested peer count.

### `responder_measures.sh [peer_count] [--keep-dmesg]`

`--keep-dmesg` leaves the kernel buffer intact instead of clearing it, useful
when re-running the extraction on the same series.

## Output

```
results_initiator/
    measures_initiator.txt          human-readable report, appended
    measures_initiator.csv          one row per stage per series
    raw_100peers_20260818-143012_total.txt
    raw_100peers_20260818-143012_decaps.txt
    raw_100peers_20260818-143012_keygen.txt
    raw_100peers_20260818-143012_ping.txt

results_responder/
    measures_responder.txt
    measures_responder.csv
    raw_100peers_20260818-143530_dmesg.txt      full capture
    raw_100peers_20260818-143530_encaps.txt
    raw_100peers_20260818-143530_searchpeer.txt
```

Raw filenames carry a timestamp, so repeated series never overwrite each other.
The CSV files are the ones to plot: they hold one row per stage per series, with
the peer count as a column.

The plotting script adds, in the current directory:

```
handshake_total_summary.csv     one row per peer count, in milliseconds
handshake_total.png
handshake_total.pdf
```

```
date;peers;stage;n;mean;min;max;stddev
2026-08-18 14:35:31;100;encaps;100;49633.000;45107.000;54013.000;3637.325
```

## Bundled example results

`results_initiator/` ships with a complete set of measurements from our own
runs, on the machine described in *Test environment*. They are provided as an
example of the expected file layout and as a reference point for the published
figures — running `plot_handshake_total.py` on a fresh checkout reproduces our
chart without measuring anything.

**Delete them before running your own campaign.** The scripts append rather than
overwrite, and the plotting script pools every series it finds for a given peer
count, so leaving these files in place silently mixes our timings with yours on
different hardware or a different configuration:

```bash
rm -rf results_initiator results_responder
```

Alternatively, keep them and pass `--latest` to the plotting script, which uses
only the most recent series per peer count. Deleting is safer: `--latest` still
leaves the stale rows in the appended `measures_*.csv`.

## Troubleshooting

**`n=0`, or "no value extracted"** — the kernel wrote nothing matching the
pattern. Check what actually reached the buffer:

```bash
sudo dmesg | grep -c CHECKTIME
sudo dmesg | grep -m1 CHECKTIME
```

A non-zero count with a different-looking line means the `sed` pattern does not
fit the format; a zero count means the module produced no trace at all — check
that the running module is the instrumented build (`sudo rmmod wireguard` then
reload from `WG_SRC`, not the distribution module) and that the kernel is not
filtering `KERN_INFO` out of the buffer (`cat /proc/sys/kernel/printk`, first
value below 6 only affects the console, not `dmesg`).

**Console output slowing the measurements** — `pr_info` is printed to the system
console as well as the ring buffer. On a virtual machine with a slow emulated
console, this adds latency inside the measured code paths and inflates the
numbers. Quieten the console before a series:

```bash
sudo dmesg -n 1
```

This only affects console printing; `dmesg` still returns everything.

**Measurements lost between runs** — `responder_setup.sh` clears `dmesg` on
exit, and so does `responder_measures.sh`. Running the setup script again before
collecting discards the series. Keep to the three-step order above.

**Responder never reachable** — check that the underlay address is actually set
(`ip -br addr show enp0s3`) and that the interface is not on a NAT-mode virtual
adapter, in which case the two VMs cannot see each other. ICMP may also simply
be filtered, in which case the tunnel still works: the wait loop gives up after
15 attempts and offers to continue.

**Kernel ring buffer overflow** — the responder logs several lines per
handshake. With large iteration counts the oldest entries are dropped, silently
lowering `n`. Either boot with a larger buffer (`log_buf_len=16M`) or keep
series short and run several of them; the CSV keeps one row per series.

**Non-integer timings** — extraction uses `[0-9][0-9]*`, which truncates at the
decimal point without any error. If the module prints decimals, change the
pattern to `[0-9][0-9.]*` in both scripts.

