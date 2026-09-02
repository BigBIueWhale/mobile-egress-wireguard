#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

compose ps
validate_haggai_environment
container_id="$(running_container_id)"
[ -n "$container_id" ] || die "VPN container is not running"
helper_id="$(haggai_helper_container_id)"
[ -n "$helper_id" ] || die "mandatory Haggai network helper is not running"

printf '\nWireGuard runtime (private keys are never shown):\n'
docker exec "$container_id" wg show wg0

printf '\nSteady-state PID 1 identity and capabilities:\n'
docker exec "$container_id" sh -c \
    "sed -n -e '/^Name:/p' -e '/^Uid:/p' -e '/^Gid:/p' -e '/^CapInh:/p' -e '/^CapPrm:/p' -e '/^CapEff:/p' -e '/^NoNewPrivs:/p' /proc/1/status"

printf '\nMandatory Haggai destinations:\n'
printf '  172.30.77.3:<port> -> Haggai 127.0.0.1:<port> (also wildcard binds)\n'
printf '  172.30.77.4:<port> -> Haggai eth0:<port> (also wildcard binds)\n'
docker exec "$helper_id" nft list set ip haggai_vpn_bridge active_gateway
