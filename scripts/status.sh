#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

compose ps
container_id="$(running_container_id)"
[ -n "$container_id" ] || die "VPN container is not running"

printf '\nWireGuard runtime (private keys are never shown):\n'
docker exec "$container_id" wg show wg0

printf '\nSteady-state PID 1 identity and capabilities:\n'
docker exec "$container_id" sh -c \
    "sed -n -e '/^Name:/p' -e '/^Uid:/p' -e '/^Gid:/p' -e '/^CapInh:/p' -e '/^CapPrm:/p' -e '/^CapEff:/p' -e '/^NoNewPrivs:/p' /proc/1/status"
