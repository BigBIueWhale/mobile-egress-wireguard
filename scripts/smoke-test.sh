#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

client_name="${1:-android}"
test_mode="${2:-internal}"
validate_client_name "$client_name"
profile="$clients_dir/$client_name.conf"
[ -s "$profile" ] || die "missing client profile: $profile"
[ -n "$(running_container_id)" ] || die "VPN container is not running"

case "$test_mode" in
    internal)
        test_endpoint="172.30.77.2:443"
        test_route_ip="172.30.77.2"
        ;;
    public)
        public_host="$(endpoint_host)"
        test_route_ip="$(getent ahostsv4 "$public_host" 2>/dev/null | \
            awk 'NR == 1 { print $1 }')"
        if [ -z "$test_route_ip" ]; then
            case "$public_host" in
                *[!0-9.]*) die "public endpoint has no IPv4 DNS result: $public_host" ;;
                *) test_route_ip="$public_host" ;;
            esac
        fi
        test_endpoint="$public_host:443"
        ;;
    *)
        die "test mode must be 'internal' or 'public'"
        ;;
esac

printf 'Running an isolated %s end-to-end tunnel test with client %s...\n' \
    "$test_mode" "$client_name"

docker run --rm \
    --network mobile-wireguard-egress \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --cap-add DAC_READ_SEARCH \
    --security-opt no-new-privileges:true \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=4m,mode=1777 \
    --env "TEST_ENDPOINT=$test_endpoint" \
    --env "TEST_ROUTE_IP=$test_route_ip" \
    --mount "type=bind,src=$profile,dst=/input/client.conf,readonly" \
    "$tools_image" sh -ec '
        set -- $(ip route show default)
        outer_gateway="$3"
        outer_device="$5"
        client_address="$(grep "^Address *=" /input/client.conf | cut -d= -f2 | tr -d " ")"

        ip route add "$TEST_ROUTE_IP/32" via "$outer_gateway" dev "$outer_device"

        sed \
            -e "/^Address *=/d" \
            -e "/^DNS *=/d" \
            -e "/^MTU *=/d" \
            -e "s|^Endpoint *=.*|Endpoint = $TEST_ENDPOINT|" \
            /input/client.conf > /tmp/wg.conf

        ip link add dev wg-test type wireguard
        wg setconf wg-test /tmp/wg.conf
        ip address add "$client_address" dev wg-test
        ip link set dev wg-test mtu 1280 up
        ip route replace default dev wg-test

        trace="$(curl --fail --silent --show-error --max-time 20 \
            https://1.1.1.1/cdn-cgi/trace)"
        handshake="$(wg show wg-test latest-handshakes | cut -f2)"
        [ "${handshake:-0}" -gt 0 ]

        observed_ip="$(printf "%s\\n" "$trace" | grep "^ip=" | cut -d= -f2-)"
        observed_country="$(printf "%s\\n" "$trace" | grep "^loc=" | cut -d= -f2-)"
        printf "Observed VPN egress IPv4: %s\\n" "$observed_ip"
        printf "Observed country: %s\\n" "$observed_country"
        printf "Authenticated WireGuard handshake: yes\\n"
    '
