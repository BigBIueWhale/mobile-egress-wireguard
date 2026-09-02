#!/bin/sh
set -eu

readonly table_family="ip"
readonly table_name="haggai_vpn_bridge"
readonly table_owner="managed by BigBIueWhale/mobile-egress-wireguard"

fail() {
    printf 'haggai-network-reset: %s\n' "$*" >&2
    exit 1
}

[ "$(cat /proc/sys/net/ipv4/conf/eth0/route_localnet)" = 0 ] || \
    fail "Docker did not reset eth0 route_localnet before cleanup"

if nft list table "$table_family" "$table_name" >/dev/null 2>&1; then
    nft list table "$table_family" "$table_name" | \
        grep -Fq "comment \"$table_owner\"" || \
        fail "refusing to delete an nftables table not marked as ours"
    nft delete table "$table_family" "$table_name"
fi

ip route del 169.254.77.1/32 dev eth0 >/dev/null 2>&1 || true
ip address del 169.254.77.3/32 dev eth0 >/dev/null 2>&1 || true
ip address del 169.254.77.2/32 dev eth0 >/dev/null 2>&1 || true

printf 'haggai-network-reset: Haggai network namespace is clean\n'
