#!/bin/bash
# =============================================================================
#  responder_measures.sh -- Extract and average timings (RESPONDER side)
#
#  Run this AFTER the initiator has finished its series of handshakes. Captures
#  dmesg, extracts the CHECKTIME values (encaps, searchpeer), computes statistics
#  and stores them indexed by peer count without overwriting earlier series.
#
#  Usage:
#     sudo ./responder_measures.sh [peer_count] [--keep-dmesg]
#
#  If peer_count is omitted, the value recorded by responder_setup.sh is reused.
#  --keep-dmesg leaves the kernel buffer intact instead of clearing it.
#
#  Output: ./results_responder/ -- appended text report, CSV table, and
#  timestamped raw files including the full dmesg capture.
# =============================================================================

set -u

RESDIR="./results_responder"

NPEERS=""
KEEP=0

for arg in "$@"; do
    case "$arg" in
        --keep-dmesg) KEEP=1 ;;
        --*)          echo "Unknown option: $arg" >&2; exit 1 ;;
        *)            NPEERS="$arg" ;;
    esac
done

if [ -z "$NPEERS" ] && [ -f /tmp/wg_bench_npeers ]; then
    NPEERS="$(cat /tmp/wg_bench_npeers)"
    echo "Peer count taken from responder_setup.sh: $NPEERS"
fi

if [ -z "$NPEERS" ]; then
    echo "Usage: sudo $0 <peer_count> [--keep-dmesg]" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
PREFIX="${RESDIR}/raw_${NPEERS}peers_${STAMP}"
REPORT="${RESDIR}/measures_responder.txt"
CSV="${RESDIR}/measures_responder.csv"
mkdir -p "$RESDIR"

DUMP="${PREFIX}_dmesg.txt"
dmesg > "$DUMP"

if [ "$KEEP" -eq 0 ]; then
    dmesg --clear
fi

echo
echo "=== Results (responder, $NPEERS peers) ==="
echo "dmesg lines captured: $(wc -l < "$DUMP")"

{
    echo "================================================================"
    echo "Date            : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Role            : responder"
    echo "Configured peers: $NPEERS"
    echo "Raw files       : ${PREFIX}_*.txt"
    echo "----------------------------------------------------------------"
} >> "$REPORT"

if [ ! -f "$CSV" ]; then
    echo "date;peers;stage;n;mean;min;max;stddev" > "$CSV"
fi

process_stage() {
    stage="$1"
    out="${PREFIX}_${stage}.txt"

    sed -n "s/.*CHECKTIME: ${stage} \([0-9][0-9]*\).*/\1/p" "$DUMP" > "$out"

    if [ ! -s "$out" ]; then
        echo "  WARNING: no value extracted for '$stage'" >&2
        echo "  Matching dmesg lines: $(grep -c "CHECKTIME: ${stage}" "$DUMP")" >&2
        grep -m1 "CHECKTIME: ${stage}" "$DUMP" >&2
    fi

    line=$(awk '
      { v=$1+0; s+=v; ss+=v*v; n++;
        if (n==1 || v<min) min=v;
        if (n==1 || v>max) max=v }
      END {
        if (n==0) { print "n=0 mean=NA min=NA max=NA stddev=NA"; exit }
        m = s/n; var = ss/n - m*m; if (var < 0) var = 0;
        printf "n=%d mean=%.3f min=%.3f max=%.3f stddev=%.3f\n", n, m, min, max, sqrt(var)
      }' "$out")

    printf "  %-12s : %s\n" "$stage" "$line"
    printf "%s for %s peers : %s\n" "$stage" "$NPEERS" "$line" >> "$REPORT"

    n=$(echo    "$line" | sed -n 's/.*n=\([0-9]*\).*/\1/p')
    mean=$(echo "$line" | sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
    mn=$(echo   "$line" | sed -n 's/.*min=\([0-9.]*\).*/\1/p')
    mx=$(echo   "$line" | sed -n 's/.*max=\([0-9.]*\).*/\1/p')
    sd=$(echo   "$line" | sed -n 's/.*stddev=\([0-9.]*\).*/\1/p')
    echo "$(date '+%Y-%m-%d %H:%M:%S');${NPEERS};${stage};${n};${mean};${mn};${mx};${sd}" >> "$CSV"
}

process_stage encaps
process_stage searchpeer

echo "" >> "$REPORT"

echo
echo "Report       : $REPORT"
echo "CSV table    : $CSV"
echo "Raw measures : ${PREFIX}_*.txt"
