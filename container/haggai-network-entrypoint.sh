#!/bin/sh
set -eu

readonly table_family="ip"
readonly table_name="haggai_vpn_bridge"
readonly table_owner="managed by BigBIueWhale/mobile-egress-wireguard"
readonly gateway_address="169.254.77.1"
readonly loopback_address="169.254.77.2"
readonly ethernet_address="169.254.77.3"
readonly nft_config="/etc/nftables.d/haggai-network.nft"

fail() {
    printf 'haggai-network-entrypoint: %s\n' "$*" >&2
    exit 1
}

table_exists() {
    nft list table "$table_family" "$table_name" >/dev/null 2>&1
}

remove_owned_runtime_state() {
    nft delete element "$table_family" "$table_name" active_gateway \
        "{ $gateway_address }" >/dev/null 2>&1 || true
    ip route del "$gateway_address/32" dev eth0 >/dev/null 2>&1 || true
    ip address del "$ethernet_address/32" dev eth0 >/dev/null 2>&1 || true
    ip address del "$loopback_address/32" dev eth0 >/dev/null 2>&1 || true
}

cleanup() {
    # Keep the input_guard table installed. Docker applies route_localnet before
    # this process starts and cannot restore it on ordinary container removal;
    # an empty expiring set plus the guard is the safe stopped state. The host
    # teardown script resets the sysctl before deleting this table.
    remove_owned_runtime_state
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

[ "$(uname -s)" = Linux ] || fail "Linux is required"
[ -r "$nft_config" ] || fail "missing nftables policy: $nft_config"
[ "$(cat /proc/sys/net/ipv4/conf/eth0/route_localnet)" = 1 ] || \
    fail "Docker did not apply the required eth0-scoped route_localnet sysctl"
[ "$(cat /proc/sys/net/ipv4/conf/all/route_localnet)" = 0 ] || \
    fail "refusing a namespace-wide route_localnet setting"

interfaces="$(ip -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | LC_ALL=C sort)"
[ "$interfaces" = "$(printf 'eth0\nlo')" ] || \
    fail "Haggai network namespace must contain exactly lo and eth0"

owned_table=false
if table_exists; then
    nft list table "$table_family" "$table_name" | \
        grep -Fq "comment \"$table_owner\"" || \
        fail "refusing to replace an nftables table not marked as ours"
    owned_table=true
fi

address_state="$(ip -o -4 address show dev eth0)"
for specification in \
    "$loopback_address/32|eth0:mvwg-lo" \
    "$ethernet_address/32|eth0:mvwg-eth"
do
    address="${specification%%|*}"
    label="${specification#*|}"
    if printf '%s\n' "$address_state" | grep -Fq "inet $address "; then
        [ "$owned_table" = true ] || \
            fail "found an unowned reserved address on Haggai's eth0: $address"
        printf '%s\n' "$address_state" | \
            grep -F "inet $address " | grep -Fq " $label" || \
            fail "reserved address has an unexpected interface label: $address"
    fi
done

if ip -4 route show "$gateway_address/32" | grep -q .; then
    [ "$owned_table" = true ] || \
        fail "found an unowned reserved route in Haggai's namespace"
fi

if [ "$owned_table" = true ]; then
    nft delete table "$table_family" "$table_name"
fi
remove_owned_runtime_state

ipv4_cidrs="$(ip -o -4 address show dev eth0 scope global | awk '{ print $4 }')"
[ "$(printf '%s\n' "$ipv4_cidrs" | grep -c .)" -eq 1 ] || \
    fail "Haggai eth0 must have exactly one ordinary IPv4 address"
haggai_eth0="${ipv4_cidrs%/*}"
printf '%s\n' "$haggai_eth0" | awk -F. '
    NF != 4 { exit 1 }
    {
        for (i = 1; i <= 4; i++) {
            if ($i !~ /^[0-9]+$/ || $i > 255) exit 1
        }
    }
' || fail "Haggai eth0 address is not a valid IPv4 address"

default_routes="$(ip -4 route show default)"
[ "$(printf '%s\n' "$default_routes" | grep -c .)" -eq 1 ] || \
    fail "Haggai namespace must have exactly one default route"
printf '%s\n' "$default_routes" | grep -Eq '(^| )dev eth0( |$)' || \
    fail "Haggai's default route must use eth0"

nft --define "haggai_eth0=$haggai_eth0" --check --file "$nft_config"
nft --define "haggai_eth0=$haggai_eth0" --file "$nft_config"

ip address add "$loopback_address/32" dev eth0 label eth0:mvwg-lo
ip address add "$ethernet_address/32" dev eth0 label eth0:mvwg-eth
ip route add "$gateway_address/32" dev eth0 src "$loopback_address"

# The pinned Haggai deployment always has its hardened RustDesk listener on
# 0.0.0.0:21118. Waiting for it validates that this really is the expected live
# namespace before authorizing any VPN traffic.
attempt=0
while ! awk '$2 == "00000000:527E" && $4 == "0A" { found = 1 } END { exit !found }' \
    /proc/net/tcp
do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 90 ] || \
        fail "Haggai's required 0.0.0.0:21118 listener did not appear"
    sleep 1
done

nft add element "$table_family" "$table_name" active_gateway \
    "{ $gateway_address timeout 10s }"
printf 'haggai-network-entrypoint: mandatory VPN routing is armed for Haggai %s\n' \
    "$haggai_eth0"

while :; do
    sleep 3 &
    wait "$!"
    printf '%s\n' \
        "delete element $table_family $table_name active_gateway { $gateway_address }" \
        "add element $table_family $table_name active_gateway { $gateway_address timeout 10s }" | \
        nft --file -
done
