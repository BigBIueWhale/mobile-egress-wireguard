#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

client_name="${1:-}"
validate_client_name "$client_name"
ensure_private_dirs

profile="$clients_dir/$client_name.conf"
peer_fragment="$peers_dir/$client_name.server.conf"
qr="$clients_dir/$client_name.png"
[ -s "$peer_fragment" ] || die "client is not active: $client_name"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive_prefix="$revoked_dir/$client_name.$timestamp"

mv -- "$peer_fragment" "$archive_prefix.server.conf"
[ ! -e "$profile" ] || mv -- "$profile" "$archive_prefix.client.conf"
[ ! -e "$qr" ] || mv -- "$qr" "$archive_prefix.png"

if ! "$script_dir/render-server.sh"; then
    mv -- "$archive_prefix.server.conf" "$peer_fragment"
    [ ! -e "$archive_prefix.client.conf" ] || mv -- "$archive_prefix.client.conf" "$profile"
    [ ! -e "$archive_prefix.png" ] || mv -- "$archive_prefix.png" "$qr"
    die "configuration validation failed; revocation was rolled back"
fi

recreate_if_running
printf 'Client %s revoked. Recoverable private archive: %s.*\n' \
    "$client_name" "$archive_prefix"
