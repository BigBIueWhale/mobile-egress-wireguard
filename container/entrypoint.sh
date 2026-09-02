#!/bin/sh
set -eu

readonly interface="wg0"
readonly config="/run/secrets/wg0.conf"
readonly outer_interface="outer0"
readonly haggai_interface="haggai0"
readonly haggai_gateway="169.254.77.1"
readonly haggai_loopback="169.254.77.2"
readonly haggai_ethernet="169.254.77.3"

fail() {
    printf 'vpn-entrypoint: %s\n' "$*" >&2
    exit 1
}

[ -r "$config" ] || fail "configuration is not readable: $config"
[ "$(uname -s)" = "Linux" ] || fail "the kernel WireGuard data plane requires Linux"

attempt=0
while ! ip link show dev "$haggai_interface" >/dev/null 2>&1; do
    interfaces="$(ip -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | LC_ALL=C sort)"
    [ "$interfaces" = "$(printf 'lo\nouter0')" ] || \
        fail "unexpected interface appeared while waiting for haggai0"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || \
        fail "mandatory haggai0 attachment was not supplied by the deployment script"
    sleep 1
done
interfaces="$(ip -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | LC_ALL=C sort)"
[ "$interfaces" = "$(printf 'haggai0\nlo\nouter0')" ] || \
    fail "network namespace must contain exactly lo, outer0, and haggai0"
ip link set dev "$haggai_interface" address 02:77:4d:47:00:01
[ "$(cat /sys/class/net/$haggai_interface/address)" = 02:77:4d:47:00:01 ] || \
    fail "Haggai bridge interface has an unexpected MAC address"

outer_addresses="$(ip -o -4 address show dev "$outer_interface" scope global | awk '{ print $4 }')"
[ "$outer_addresses" = 172.30.77.2/29 ] || \
    fail "outer0 must have exactly 172.30.77.2/29"
default_routes="$(ip -4 route show default)"
[ "$(printf '%s\n' "$default_routes" | grep -c .)" -eq 1 ] || \
    fail "VPN namespace must have exactly one default route"
printf '%s\n' "$default_routes" | grep -Eq '^default via 172\.30\.77\.1 dev outer0( |$)' || \
    fail "VPN default route must use the fixed outer gateway"

if ip link show dev "$interface" >/dev/null 2>&1; then
    fail "refusing to reuse an existing $interface"
fi

cleanup_startup() {
    ip link delete dev "$interface" >/dev/null 2>&1 || true
    ip route del "$haggai_ethernet/32" dev "$haggai_interface" >/dev/null 2>&1 || true
    ip route del "$haggai_loopback/32" dev "$haggai_interface" >/dev/null 2>&1 || true
    ip address del "$haggai_gateway/32" dev "$haggai_interface" >/dev/null 2>&1 || true
    nft delete table ip vpn_nat >/dev/null 2>&1 || true
    nft delete table inet vpn_filter >/dev/null 2>&1 || true
}
trap cleanup_startup EXIT HUP INT TERM

if ip -o -4 address show dev "$haggai_interface" | grep -Fq "inet $haggai_gateway/32 "; then
    fail "reserved Haggai gateway address already exists"
fi
if ip -4 route show "$haggai_loopback/32" | grep -q . || \
    ip -4 route show "$haggai_ethernet/32" | grep -q .; then
    fail "reserved Haggai transit route already exists"
fi

ip address add "$haggai_gateway/32" dev "$haggai_interface" label haggai0:mvwg
ip route add "$haggai_loopback/32" dev "$haggai_interface" src "$haggai_gateway"
ip route add "$haggai_ethernet/32" dev "$haggai_interface" src "$haggai_gateway"

# Do not bring up WireGuard unless the mandatory Haggai namespace helper is
# active and has proved the expected hardened RustDesk listener exists.
attempt=0
while ! nc -z -w 1 "$haggai_loopback" 21118 >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || \
        fail "mandatory Haggai loopback path did not become ready"
    sleep 1
done

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
