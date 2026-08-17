#!/bin/bash
# =============================================================================
#  responder_setup.sh -- WireGuard benchmark setup (RESPONDER side)
#
#  Builds and loads the module, then brings up wg0 with the configuration file
#  matching the requested peer count. Clears dmesg so the buffer only holds the
#  measurements of the upcoming run.
#
#  Usage:
#     sudo ./responder_setup.sh <peer_count> [config_path] [--skip-build]
#
#  The config file is looked up using the CONF_PATTERNS list below; adapt it to
#  your naming convention, or pass the path explicitly as the second argument.
#
#  Examples:
#     sudo ./responder_setup.sh 100
#     sudo ./responder_setup.sh 1000 ./configs/confwgA_1000
#     sudo ./responder_setup.sh 500 --skip-build
# =============================================================================

set -u

WG_SRC="./schwg/drivers/net/wireguard"
CONF_DIR="."
IF_LAN="enp0s3"
IP_LAN="192.168.0.11/24"
IP_WG="10.0.0.11/24"

CONF_PATTERNS=(
    "confwgResp_%s"
    "confwgResp%s"
    "confwg_%speers"
    "confwgResp_%speers"
    "configs/confwgResp_%s"
)

NPEERS=""
CONF=""
SKIP_BUILD=0

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --*)          echo "Unknown option: $arg" >&2; exit 1 ;;
        *)
            if [ -z "$NPEERS" ]; then NPEERS="$arg"
            else CONF="$arg"; fi
            ;;
    esac
done

if [ -z "$NPEERS" ]; then
    echo "Usage: sudo $0 <peer_count> [config_path] [--skip-build]" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

if [ -z "$CONF" ]; then
    for p in "${CONF_PATTERNS[@]}"; do
        # shellcheck disable=SC2059
        candidate="${CONF_DIR}/$(printf "$p" "$NPEERS")"
        if [ -f "$candidate" ]; then CONF="$candidate"; break; fi
    done
fi

if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
    echo "No configuration file found for $NPEERS peers." >&2
    echo "Patterns tried in '$CONF_DIR':" >&2
    for p in "${CONF_PATTERNS[@]}"; do
        # shellcheck disable=SC2059
        printf "   - %s\n" "$(printf "$p" "$NPEERS")" >&2
    done
    echo "Pass the path as the second argument, or edit CONF_PATTERNS at the top of the script." >&2
    exit 1
fi

echo "Selected configuration: $CONF"
ACTUAL=$(grep -c '^\[Peer\]' "$CONF")
echo "Peers declared in file: $ACTUAL (requested: $NPEERS)"
if [ "$ACTUAL" -ne "$NPEERS" ]; then
    echo "WARNING: the peer count in the file does not match the argument." >&2
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo
    echo "=== Building and loading the module ==="

    rmmod wireguard 2>/dev/null

    make -C "/usr/src/linux-headers-$(uname -r)/" M="$WG_SRC" modules -j"$(nproc)" || {
        echo "Build failed." >&2; exit 1; }

    modprobe udp_tunnel
    modprobe ip6_udp_tunnel
    modprobe curve25519-x86_64

    insmod "${WG_SRC}/wireguard.ko" || { echo "insmod failed." >&2; exit 1; }

    echo 'module wireguard +p' | tee /sys/kernel/debug/dynamic_debug/control > /dev/null
else
    echo "(--skip-build: assuming the module is already loaded)"
fi

echo
echo "=== Network configuration ==="

ip addr add "$IP_LAN" dev "$IF_LAN" 2>/dev/null
ip link set "$IF_LAN" up

ip link del wg0 2>/dev/null
ip link add wg0 type wireguard
ip addr add "$IP_WG" dev wg0
wg setconf wg0 "$CONF" || { echo "wg setconf failed." >&2; exit 1; }
ip link set wg0 up

echo "$NPEERS" > /tmp/wg_bench_npeers

dmesg --clear

echo
echo "wg0 is up with $NPEERS peers, dmesg cleared."
echo "Start the initiator script, then run:"
echo "   sudo ./responder_measures.sh $NPEERS"
