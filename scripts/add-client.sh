#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

skip_restart=false
if [ "${1:-}" = "--no-restart" ]; then
    skip_restart=true
    shift
fi

client_name="${1:-}"
validate_client_name "$client_name"
ensure_private_dirs
[ -s "$secrets_dir/server.public" ] || die "run scripts/init.sh first"

profile="$clients_dir/$client_name.conf"
peer_fragment="$peers_dir/$client_name.server.conf"
[ ! -e "$profile" ] && [ ! -e "$peer_fragment" ] || \
    die "client already exists: $client_name"

next_octet=2
while [ "$next_octet" -le 254 ]; do
    if ! grep -Fqs "AllowedIPs = 10.77.0.$next_octet/32" \
        "$peers_dir"/*.server.conf 2>/dev/null; then
        break
    fi
    next_octet=$((next_octet + 1))
done
[ "$next_octet" -le 254 ] || die "the 10.77.0.0/24 peer pool is full"

client_private="$(tool wg genkey)"
client_public="$(printf '%s\n' "$client_private" | tool_stdin wg pubkey)"
preshared_key="$(tool wg genpsk)"
server_public="$(sed -n '1p' "$secrets_dir/server.public")"
endpoint="$(endpoint_host)"

umask 077
profile_tmp="$(mktemp "$clients_dir/$client_name.conf.tmp.XXXXXX")"
peer_tmp="$(mktemp "$peers_dir/$client_name.server.conf.tmp.XXXXXX")"
committed=false
cleanup() {
    if [ "$committed" != true ]; then
        rm -f -- "$profile_tmp" "$peer_tmp"
    fi
}
trap cleanup EXIT HUP INT TERM

{
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$client_private"
    printf 'Address = 10.77.0.%s/32\n' "$next_octet"
    printf 'DNS = 9.9.9.9, 149.112.112.112\n'
    printf 'MTU = 1280\n'
    printf '\n[Peer]\n'
    printf 'PublicKey = %s\n' "$server_public"
    printf 'PresharedKey = %s\n' "$preshared_key"
    printf 'AllowedIPs = 0.0.0.0/0, ::/0\n'
    printf 'Endpoint = %s:443\n' "$endpoint"
    printf 'PersistentKeepalive = 25\n'
} > "$profile_tmp"

{
    printf '[Peer]\n'
    printf '# Name = %s\n' "$client_name"
    printf 'PublicKey = %s\n' "$client_public"
    printf 'PresharedKey = %s\n' "$preshared_key"
    printf 'AllowedIPs = 10.77.0.%s/32\n' "$next_octet"
} > "$peer_tmp"

chmod 600 "$profile_tmp" "$peer_tmp"
mv -f -- "$profile_tmp" "$profile"
mv -f -- "$peer_tmp" "$peer_fragment"
committed=true
trap - EXIT HUP INT TERM

"$script_dir/render-server.sh"
"$script_dir/render-qr.sh" "$client_name"

if [ "$skip_restart" != true ]; then
    recreate_if_running
fi

printf 'Client %s created at 10.77.0.%s. Private material was not printed.\n' \
    "$client_name" "$next_octet"
