#!/bin/bash
# =============================================================================
#  initiator_bench.sh -- WireGuard timing benchmark (INITIATOR side)
#
#  Builds and loads the module, waits for the responder, runs a series of
#  handshakes by tearing down and recreating wg0, then extracts the CHECKTIME
#  values from dmesg and computes per-stage statistics (total, decaps, keygen).
#
#  Usage:
#     sudo ./initiator_bench.sh <responder_peer_count> [iterations] [options]
#
#  Options:
#     --skip-build   do not rebuild/reload the module (for chaining several
#                    series with different peer counts)
#     --no-wait      do not ask for confirmation before starting the loop
#     --only-stats   recompute statistics only, run no test
#
#  Examples:
#     sudo ./initiator_bench.sh 100             # 100 handshakes (default)
#     sudo ./initiator_bench.sh 500 100 --skip-build
#
#  Output: ./results_initiator/ -- appended text report, CSV table, and
#  timestamped raw files (nothing is ever overwritten).
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WG_SRC="${SCRIPT_DIR}/schwg/drivers/net/wireguard/"
CONF="./Config_files/confwgInit"
IF_LAN="enp0s3"
IP_LAN="192.168.0.12/24"
IP_WG="10.0.0.12/24"
PEER_LAN="192.168.0.11"
PEER_WG="10.0.0.11"
RESDIR="./results_initiator"
PING_TIMEOUT=3
SETTLE=0.2

STAGES=("total:CHECKTIME: total" "decaps:CHECKTIME: decaps" "keygen:CHECKTIME: keygen")

NPEERS=""
ITER=100
SKIP_BUILD=0
NO_WAIT=0
ONLY_STATS=0

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --no-wait)    NO_WAIT=1 ;;
        --only-stats) ONLY_STATS=1 ;;
        --*)          echo "Unknown option: $arg" >&2; exit 1 ;;
        *)
            if [ -z "$NPEERS" ]; then NPEERS="$arg"
            else ITER="$arg"; fi
            ;;
    esac
done

if [ -z "$NPEERS" ]; then
    echo "Usage: sudo $0 <responder_peer_count> [iterations] [--skip-build] [--no-wait] [--only-stats]" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
PREFIX="${RESDIR}/raw_${NPEERS}peers_${STAMP}"
REPORT="${RESDIR}/measures_initiator.txt"
CSV="${RESDIR}/measures_initiator.csv"
PINGLOG="${PREFIX}_ping.txt"
mkdir -p "$RESDIR"

banner() { echo; echo "=== $* ==="; }

stats() {
    awk '
      { v=$1+0; s+=v; ss+=v*v; n++;
        if (n==1 || v<min) min=v;
        if (n==1 || v>max) max=v }
      END {
        if (n==0) { print "n=0 mean=NA min=NA max=NA stddev=NA"; exit }
        m = s/n; var = ss/n - m*m; if (var < 0) var = 0;
        printf "n=%d mean=%.3f min=%.3f max=%.3f stddev=%.3f\n", n, m, min, max, sqrt(var)
      }' "$1"
}

if [ "$ONLY_STATS" -eq 0 ] && [ "$SKIP_BUILD" -eq 0 ]; then
    banner "Building and loading the WireGuard module"

    rmmod wireguard 2>/dev/null

    make -C "/usr/src/linux-headers-$(uname -r)/" M="$WG_SRC" modules -j"$(nproc)" || {
        echo "Build failed." >&2; exit 1; }

    modprobe udp_tunnel
    modprobe ip6_udp_tunnel
    modprobe curve25519-x86_64

    insmod "${WG_SRC}/wireguard.ko" || { echo "insmod failed." >&2; exit 1; }

    echo 'module wireguard +p' | tee /sys/kernel/debug/dynamic_debug/control > /dev/null

    ip addr add "$IP_LAN" dev "$IF_LAN" 2>/dev/null
    ip link set "$IF_LAN" up

    ip link del wg0 2>/dev/null
    ip link add wg0 type wireguard
    ip addr add "$IP_WG" dev wg0
    wg setconf wg0 "$CONF" || { echo "wg setconf failed ($CONF)." >&2; exit 1; }
    ip link set wg0 up

    echo "Module loaded, wg0 configured."
fi

if [ "$ONLY_STATS" -eq 0 ]; then
    banner "Waiting for the responder ($PEER_LAN)"
    until ping -c 1 -W 1 "$PEER_LAN" > /dev/null 2>&1; do
        echo "  ... responder unreachable, retrying in 2 s"
        sleep 2
    done
    echo "Responder is reachable."

    if [ "$NO_WAIT" -eq 0 ]; then
        echo
        read -r -p "Is the responder configured with $NPEERS peers? [Enter to start] " _
    fi
fi

if [ "$ONLY_STATS" -eq 0 ]; then
    banner "Running $ITER handshakes (responder: $NPEERS peers)"

    : > "$PINGLOG"
    for s in "${STAGES[@]}"; do : > "${PREFIX}_${s%%:*}.txt"; done

    TMPDMESG="$(mktemp)"
    trap 'rm -f "$TMPDMESG"' EXIT
    FAILED=0

    for i in $(seq 1 "$ITER"); do
        ip link del wg0 2>/dev/null
        ip link add wg0 type wireguard
        ip addr add "$IP_WG" dev wg0
        wg setconf wg0 "$CONF"
        ip link set wg0 up

        dmesg --clear

        if ! ping -c 1 -W "$PING_TIMEOUT" "$PEER_WG" >> "$PINGLOG" 2>&1; then
            FAILED=$((FAILED+1))
        fi

        sleep "$SETTLE"
        dmesg > "$TMPDMESG"

        for s in "${STAGES[@]}"; do
            key="${s%%:*}"; pattern="${s#*:}"
            sed -n "s/.*${pattern} \([0-9][0-9]*\).*/\1/p" "$TMPDMESG" >> "${PREFIX}_${key}.txt"
        done

        if [ $((i % 25)) -eq 0 ] || [ "$i" -eq "$ITER" ]; then
            echo "  iteration $i / $ITER (ping failures: $FAILED)"
        fi
    done

    rm -f "$TMPDMESG"; trap - EXIT
    echo "Loop finished. Failed pings: $FAILED / $ITER"
fi

banner "Results (responder: $NPEERS peers)"

{
    echo "================================================================"
    echo "Date            : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Role            : initiator"
    echo "Responder peers : $NPEERS"
    echo "Iterations      : $ITER"
    echo "Raw files       : ${PREFIX}_*.txt"
    echo "----------------------------------------------------------------"
} >> "$REPORT"

if [ ! -f "$CSV" ]; then
    echo "date;peers;iterations;stage;n;mean;min;max;stddev" > "$CSV"
fi

for s in "${STAGES[@]}"; do
    key="${s%%:*}"
    f="${PREFIX}_${key}.txt"
    [ -f "$f" ] || { echo "  ($key: no file)"; continue; }

    line="$(stats "$f")"
    printf "  %-8s : %s\n" "$key" "$line"
    printf "%-8s : %s\n" "$key" "$line" >> "$REPORT"

    n=$(echo    "$line" | sed -n 's/.*n=\([0-9]*\).*/\1/p')
    mean=$(echo "$line" | sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
    mn=$(echo   "$line" | sed -n 's/.*min=\([0-9.]*\).*/\1/p')
    mx=$(echo   "$line" | sed -n 's/.*max=\([0-9.]*\).*/\1/p')
    sd=$(echo   "$line" | sed -n 's/.*stddev=\([0-9.]*\).*/\1/p')
    echo "$(date '+%Y-%m-%d %H:%M:%S');${NPEERS};${ITER};${key};${n};${mean};${mn};${mx};${sd}" >> "$CSV"
done

echo "" >> "$REPORT"

echo
echo "Report       : $REPORT"
echo "CSV table    : $CSV"
echo "Raw measures : ${PREFIX}_*.txt"
