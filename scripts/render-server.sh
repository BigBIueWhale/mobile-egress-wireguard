#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

ensure_private_dirs
[ -s "$secrets_dir/server.key" ] || die "run scripts/init.sh first"

umask 077
temporary="$(mktemp "$secrets_dir/server.conf.tmp.XXXXXX")"
cleanup() {
    rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

{
    printf '[Interface]\n'
    printf 'PrivateKey = '
    sed -n '1p' "$secrets_dir/server.key"
    printf 'ListenPort = 443\n'

    for peer_file in "$peers_dir"/*.server.conf; do
        [ -e "$peer_file" ] || continue
        printf '\n'
        sed -n '1,80p' "$peer_file"
    done
} > "$temporary"
chmod 600 "$temporary"

# Parse the generated configuration in a throw-away network namespace before
# making it live. Neither keys nor configuration are printed.
docker run --rm \
    --network none \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --cap-add DAC_READ_SEARCH \
    --security-opt no-new-privileges:true \
    --read-only \
    --mount "type=bind,src=$temporary,dst=/config/wg0.conf,readonly" \
    --entrypoint /bin/sh \
    "$runtime_image" \
    -ec 'ip link add dev wg-validate type wireguard; wg setconf wg-validate /config/wg0.conf'

mv -f -- "$temporary" "$secrets_dir/server.conf"
trap - EXIT HUP INT TERM
