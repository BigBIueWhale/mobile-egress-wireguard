#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

client_name="${1:-}"
validate_client_name "$client_name"
profile="$clients_dir/$client_name.conf"
output="$clients_dir/$client_name.png"
[ -s "$profile" ] || die "client profile does not exist: $profile"

umask 077
temporary="$(mktemp "$clients_dir/$client_name.png.tmp.XXXXXX")"
cleanup() {
    rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

docker run --rm \
    --network none \
    --user "$(id -u):$(id -g)" \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=4m,mode=1777 \
    --mount "type=bind,src=$profile,dst=/input/client.conf,readonly" \
    --mount "type=bind,src=$temporary,dst=/output/client.png" \
    "$tools_image" \
    qrencode --read-from=/input/client.conf --output=/output/client.png \
        --type=PNG --level=Q --size=8 --margin=2

chmod 600 "$temporary"
mv -f -- "$temporary" "$output"
trap - EXIT HUP INT TERM
printf 'QR code written to %s\n' "$output"
