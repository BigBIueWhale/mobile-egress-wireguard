#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

usage="usage: $0 --endpoint <DNS-name-or-IPv4> [client-name ...]"
[ "$#" -ge 2 ] || die "$usage"
[ "$1" = "--endpoint" ] || die "$usage"
endpoint="$2"
shift 2
validate_endpoint_host "$endpoint"

if [ "$#" -eq 0 ]; then
    set -- android ios
fi

seen_clients=' '
for client_name in "$@"; do
    validate_client_name "$client_name"
    case "$seen_clients" in
        *" $client_name "*) die "duplicate client name: $client_name" ;;
    esac
    seen_clients="$seen_clients$client_name "
done

ensure_private_dirs
[ ! -e "$secrets_dir/server.key" ] || \
    die "server keys already exist; refusing to overwrite them"

# The endpoint is a required input, then becomes ignored local deployment state.
persist_endpoint_host "$endpoint"
build_images

server_private="$(tool wg genkey)"
server_public="$(printf '%s\n' "$server_private" | tool_stdin wg pubkey)"
write_private_value "$secrets_dir/server.key" "$server_private"
write_private_value "$secrets_dir/server.public" "$server_public"

for client_name in "$@"; do
    "$script_dir/add-client.sh" --no-restart "$client_name"
done

"$script_dir/render-server.sh"
compose up --detach --no-build vpn
wait_until_ready

printf '\nVPN initialized. Import one profile per device from:\n'
for client_name in "$@"; do
    printf '  %s\n' "$clients_dir/$client_name.conf"
    printf '  %s\n' "$clients_dir/$client_name.png"
done
