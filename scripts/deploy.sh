#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

validate_haggai_environment
ensure_private_dirs
"$project_dir/tests/static.sh"
[ -s "$secrets_dir/server.key" ] || die "missing existing server key; use scripts/init.sh for a new deployment"
[ -s "$secrets_dir/server.public" ] || die "missing existing server public key"
[ -s "$secrets_dir/server.conf" ] || die "missing existing server configuration"

config_digest_before="$(sha256sum "$secrets_dir/server.conf" | awk '{ print $1 }')"
haggai_id_before="$(docker inspect --format '{{.Id}}' "$haggai_container")"
haggai_started_before="$(docker inspect --format '{{.State.StartedAt}}' "$haggai_container")"
running_public=""
if [ -n "$(running_container_id)" ]; then
    running_public="$(docker exec "$(running_container_id)" wg show wg0 public-key)"
fi

build_images
"$project_dir/tests/network-policy.sh"
expected_public="$(server_config_public_key)"
[ "$(sed -n '1p' "$secrets_dir/server.public")" = "$expected_public" ] || \
    die "server.public does not match the private key in server.conf"
[ -z "$running_public" ] || [ "$running_public" = "$expected_public" ] || \
    die "running WireGuard public key differs from the saved server key"

# Recreate only this Compose project. haggai_computer is an external namespace
# donor and is never a Compose service here, so it is neither stopped nor
# recreated. Removing the egress network is required to reserve both Haggai
# destination aliases in Docker IPAM.
compose down --remove-orphans
start_vpn

config_digest_after="$(sha256sum "$secrets_dir/server.conf" | awk '{ print $1 }')"
[ "$config_digest_after" = "$config_digest_before" ] || \
    die "server configuration changed during deployment"
[ "$(docker exec "$(running_container_id)" wg show wg0 public-key)" = "$expected_public" ] || \
    die "redeployed WireGuard public key does not match the saved key"
[ "$(docker inspect --format '{{.Id}}' "$haggai_container")" = "$haggai_id_before" ] || \
    die "Haggai container identity changed unexpectedly"
[ "$(docker inspect --format '{{.State.StartedAt}}' "$haggai_container")" = "$haggai_started_before" ] || \
    die "Haggai container restarted unexpectedly"

printf 'Deployment complete: existing WireGuard key preserved; Haggai was not restarted or recreated.\n'
