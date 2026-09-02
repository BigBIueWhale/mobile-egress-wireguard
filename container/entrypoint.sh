#!/bin/sh
set -eu

readonly interface="wg0"
readonly config="/run/secrets/wg0.conf"

fail() {
    printf 'vpn-entrypoint: %s\n' "$*" >&2
    exit 1
}

[ -r "$config" ] || fail "configuration is not readable: $config"
[ "$(uname -s)" = "Linux" ] || fail "the kernel WireGuard data plane requires Linux"

if ip link show dev "$interface" >/dev/null 2>&1; then
    fail "refusing to reuse an existing $interface"
fi

cleanup_startup() {
    ip link delete dev "$interface" >/dev/null 2>&1 || true
    nft delete table ip vpn_nat >/dev/null 2>&1 || true
    nft delete table inet vpn_filter >/dev/null 2>&1 || true
}
trap cleanup_startup EXIT HUP INT TERM

nft --check --file /etc/nftables.d/vpn.nft
nft --file /etc/nftables.d/vpn.nft

ip link add dev "$interface" type wireguard
wg setconf "$interface" "$config"

[ "$(wg show "$interface" listen-port)" = "443" ] || \
    fail "server configuration must listen on exactly UDP/443"

ip address add 10.77.0.1/24 dev "$interface"
ip link set dev "$interface" mtu 1280 up

peer_count="$(wg show "$interface" peers | wc -w | tr -d ' ')"
printf 'vpn-entrypoint: WireGuard is ready on UDP/443 with %s peer(s)\n' "$peer_count"

# Startup needed NET_ADMIN plus temporary read/set-ID privileges. The steady
# state is a no-network-daemon sleep process owned by nobody. setuid clears all
# effective/permitted capabilities, and Compose also sets no-new-privileges.
trap - EXIT HUP INT TERM
exec su -s /bin/sh nobody -c 'exec sleep 2147483647'
