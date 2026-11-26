#!/usr/bin/env bash
#
# netns.sh - network topology of the DownlinkScope test bench.
#
# Topology (one Linux host, three network namespaces):
#
#   namespace dls-gw          namespace dls-wan (router)        root namespace
#   +--------------+          +------------------------+        +----------------+
#   | gw0          |==========| wan-gw        wan-srv  |========| dls-srv0       |
#   | 10.10.1.2/24 |          | 10.10.1.1     10.10.2.1|        | 10.10.2.2/24   |
#   +--------------+          +------------------------+        +----------------+
#    gateway simulator         netem delay and loss on           ChirpStack
#    and capture point         the egress of both sides          (UDP 1700)
#
# The delay D is applied one time in each direction, so a round trip is 2 x D.
# The loss L is applied one time in each direction (independent).
# The capture point gw0 has no impairment: a capture timestamp on gw0 is the
# time at which the gateway sends or receives a datagram.
#
# Usage: sudo bench/netns.sh <command> [options]
#   up     [--delay MS] [--loss PCT]   create the topology and apply netem
#   set    [--delay MS] [--loss PCT]   change netem on an existing topology
#   verify                             measure the round trip with ping
#   status                             show addresses, netem settings, counters
#   exec   COMMAND [ARG...]            run a command in the gateway namespace
#   down                               remove the topology

set -euo pipefail

readonly NS_GW="dls-gw"
readonly NS_WAN="dls-wan"
readonly IF_GW="gw0"
readonly IF_WAN_GW="wan-gw"
readonly IF_WAN_SRV="wan-srv"
readonly IF_SRV="dls-srv0"
readonly NET_GW="10.10.1.0/24"
readonly NET_SRV="10.10.2.0/24"
readonly IP_GW="10.10.1.2"
readonly IP_WAN_GW="10.10.1.1"
readonly IP_WAN_SRV="10.10.2.1"
readonly IP_SRV="10.10.2.2"
# Queue size of netem in packets. The traffic of the bench is light; a large
# limit makes sure that netem never drops a packet because its queue is full.
readonly NETEM_LIMIT=100000
readonly STATE_FILE="/run/dls-netns.state"

die() {
    echo "netns.sh: error: $*" >&2
    exit 1
}

usage() {
    sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "this command needs root rights (use sudo)"
}

topology_exists() {
    ip netns list 2>/dev/null | grep -q -E "^${NS_GW}( |$)"
}

# Read --delay and --loss. Results in DELAY_MS and LOSS_PCT.
DELAY_MS=""
LOSS_PCT=""
parse_impairment() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --delay)
            [[ $# -ge 2 ]] || die "--delay needs a value in milliseconds"
            DELAY_MS="$2"
            shift 2
            ;;
        --loss)
            [[ $# -ge 2 ]] || die "--loss needs a value in percent"
            LOSS_PCT="$2"
            shift 2
            ;;
        *) die "unknown option: $1" ;;
        esac
    done
}

validate_impairment() {
    [[ ${DELAY_MS} =~ ^[0-9]{1,5}$ ]] || die "delay must be an integer from 0 to 10000 (ms)"
    ((10#${DELAY_MS} <= 10000)) || die "delay must be an integer from 0 to 10000 (ms)"
    [[ ${LOSS_PCT} =~ ^[0-9]{1,3}(\.[0-9]{1,3})?$ ]] || die "loss must be a number from 0 to 100 (percent)"
    awk -v l="${LOSS_PCT}" 'BEGIN { exit !(l <= 100) }' || die "loss must be a number from 0 to 100 (percent)"
}

check_netem() {
    # A probe on a temporary veth pair shows if the kernel has the netem qdisc.
    # A veth pair is used because the bench needs veth support in any case.
    local probe="dls-probe0"
    ip link del "${probe}" 2>/dev/null || true
    ip link add "${probe}" type veth peer name "dls-probe1" 2>/dev/null ||
        die "cannot create a veth interface (is veth supported on this host?)"
    if ! tc qdisc add dev "${probe}" root netem delay 1ms 2>/dev/null; then
        ip link del "${probe}"
        die "the kernel has no netem qdisc (module sch_netem). The bench cannot run on this host."
    fi
    ip link del "${probe}"
}

check_no_conflict() {
    # Refuse to start if the bench subnets are in use on this host.
    local net
    for net in "${NET_GW}" "${NET_SRV}"; do
        if ip -4 route show | grep -q -F "${net%.*}."; then
            die "the subnet ${net} is already in the routing table of this host"
        fi
    done
}

apply_netem() {
    local dev
    for dev in "${IF_WAN_GW}" "${IF_WAN_SRV}"; do
        ip netns exec "${NS_WAN}" tc qdisc replace dev "${dev}" root netem \
            delay "${DELAY_MS}ms" loss "${LOSS_PCT}%" limit "${NETEM_LIMIT}"
    done
    printf 'delay_ms=%s\nloss_pct=%s\n' "${DELAY_MS}" "${LOSS_PCT}" >"${STATE_FILE}"
}

cmd_up() {
    require_root
    DELAY_MS="0"
    LOSS_PCT="0"
    parse_impairment "$@"
    validate_impairment
    topology_exists && die "the topology exists. Use 'set' to change netem, or 'down' first."
    check_netem
    check_no_conflict

    ip netns add "${NS_GW}"
    ip netns add "${NS_WAN}"
    ip link add "${IF_GW}" netns "${NS_GW}" type veth peer name "${IF_WAN_GW}" netns "${NS_WAN}"
    ip link add "${IF_SRV}" type veth peer name "${IF_WAN_SRV}" netns "${NS_WAN}"

    ip -n "${NS_GW}" addr add "${IP_GW}/24" dev "${IF_GW}"
    ip -n "${NS_GW}" link set lo up
    ip -n "${NS_GW}" link set "${IF_GW}" up
    ip -n "${NS_GW}" route add default via "${IP_WAN_GW}"

    ip -n "${NS_WAN}" addr add "${IP_WAN_GW}/24" dev "${IF_WAN_GW}"
    ip -n "${NS_WAN}" addr add "${IP_WAN_SRV}/24" dev "${IF_WAN_SRV}"
    ip -n "${NS_WAN}" link set lo up
    ip -n "${NS_WAN}" link set "${IF_WAN_GW}" up
    ip -n "${NS_WAN}" link set "${IF_WAN_SRV}" up
    ip netns exec "${NS_WAN}" sysctl -q -w net.ipv4.ip_forward=1

    ip addr add "${IP_SRV}/24" dev "${IF_SRV}"
    ip link set "${IF_SRV}" up
    ip route add "${NET_GW}" via "${IP_WAN_SRV}" dev "${IF_SRV}"

    apply_netem
    echo "topology up: gateway ${IP_GW} <-> server ${IP_SRV}, delay ${DELAY_MS} ms and loss ${LOSS_PCT} % in each direction"
}

cmd_set() {
    require_root
    topology_exists || die "the topology does not exist. Use 'up' first."
    # Default: keep the current values.
    # shellcheck disable=SC1090
    [[ -r ${STATE_FILE} ]] && source <(grep -E '^(delay_ms|loss_pct)=[0-9.]+$' "${STATE_FILE}")
    DELAY_MS="${delay_ms:-0}"
    LOSS_PCT="${loss_pct:-0}"
    parse_impairment "$@"
    validate_impairment
    apply_netem
    echo "netem set: delay ${DELAY_MS} ms and loss ${LOSS_PCT} % in each direction"
}

cmd_verify() {
    require_root
    topology_exists || die "the topology does not exist. Use 'up' first."
    local delay_ms=0 loss_pct=0
    # shellcheck disable=SC1090
    [[ -r ${STATE_FILE} ]] && source <(grep -E '^(delay_ms|loss_pct)=[0-9.]+$' "${STATE_FILE}")

    local count=20 out avg
    # The deadline lets ping finish when the delay is large or packets are lost.
    out="$(ip netns exec "${NS_GW}" ping -n -q -c "${count}" -i 0.2 -W 5 "${IP_SRV}" 2>&1)" || true
    echo "${out}" | tail -n 2
    avg="$(echo "${out}" | awk -F'/' '/^(rtt|round-trip)/ { print $5 }')"
    [[ -n ${avg} ]] || die "no ping reply from ${IP_SRV}"

    # Expected round trip: 2 x delay. Tolerance: -1 ms to +max(3 ms, 5 %).
    if awk -v a="${avg}" -v d="${delay_ms}" 'BEGIN {
            e = 2 * d; tol = (e * 0.05 > 3) ? e * 0.05 : 3
            printf "expected round trip %.1f ms, measured average %.3f ms\n", e, a
            exit !(a >= e - 1 && a <= e + tol) }'; then
        echo "verify: PASS (loss setting ${loss_pct} % in each direction)"
    else
        die "verify: FAIL, the measured round trip is not 2 x ${delay_ms} ms"
    fi
}

cmd_status() {
    topology_exists || {
        echo "topology: down"
        return 0
    }
    require_root
    echo "topology: up"
    [[ -r ${STATE_FILE} ]] && cat "${STATE_FILE}"
    echo "--- ${NS_GW}"
    ip -n "${NS_GW}" -4 -brief addr show
    echo "--- ${NS_WAN}"
    ip -n "${NS_WAN}" -4 -brief addr show
    echo "--- root namespace"
    ip -4 -brief addr show dev "${IF_SRV}"
    echo "--- netem (check that 'dropped' stays at 0 when loss is 0)"
    ip netns exec "${NS_WAN}" tc -s qdisc show dev "${IF_WAN_GW}"
    ip netns exec "${NS_WAN}" tc -s qdisc show dev "${IF_WAN_SRV}"
}

cmd_exec() {
    require_root
    topology_exists || die "the topology does not exist. Use 'up' first."
    [[ $# -ge 1 ]] || die "exec needs a command"
    # Run the command as the user who called sudo, not as root.
    if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
        exec ip netns exec "${NS_GW}" sudo -u "${SUDO_USER}" -- "$@"
    fi
    exec ip netns exec "${NS_GW}" "$@"
}

cmd_down() {
    require_root
    # Deleting a namespace deletes its veth interfaces and their peers.
    ip netns del "${NS_GW}" 2>/dev/null || true
    ip netns del "${NS_WAN}" 2>/dev/null || true
    ip link del "${IF_SRV}" 2>/dev/null || true
    rm -f "${STATE_FILE}"
    echo "topology down"
}

main() {
    [[ $# -ge 1 ]] || {
        usage
        exit 2
    }
    local cmd="$1"
    shift
    case "${cmd}" in
    up) cmd_up "$@" ;;
    set) cmd_set "$@" ;;
    verify) cmd_verify ;;
    status) cmd_status ;;
    exec) cmd_exec "$@" ;;
    down) cmd_down ;;
    -h | --help | help) usage ;;
    *) die "unknown command: ${cmd} (use --help)" ;;
    esac
}

main "$@"
