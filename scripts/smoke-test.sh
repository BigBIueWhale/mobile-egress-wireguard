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
[ -n "$(haggai_helper_container_id)" ] || die "mandatory Haggai helper is not running"
validate_haggai_environment

loopback_probe_port=60991
ethernet_probe_port=60992
if docker exec "$haggai_container" ss -H -lnt | \
    awk -v first=":$loopback_probe_port" -v second=":$ethernet_probe_port" \
        '$4 ~ first "$" || $4 ~ second "$" { found = 1 } END { exit !found }'; then
    die "a Haggai integration probe port is already in use"
fi

loopback_probe_container="mobile-wireguard-smoke-haggai-loopback"
ethernet_probe_container="mobile-wireguard-smoke-haggai-ethernet"
if docker inspect "$loopback_probe_container" "$ethernet_probe_container" >/dev/null 2>&1; then
    die "a stale Haggai smoke-test container exists; inspect it before removal"
fi

cleanup_probes() {
    docker rm -f "$loopback_probe_container" "$ethernet_probe_container" \
        >/dev/null 2>&1 || true
}
trap cleanup_probes EXIT HUP INT TERM

docker run --detach --name "$loopback_probe_container" \
    --network "container:$haggai_container" \
    --user 65534:65534 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --read-only \
    --pids-limit 4 \
    --entrypoint /bin/sh \
    "$runtime_image" -ec \
    'printf "haggai-loopback-ok\n" | exec nc -l -s 127.0.0.1 -p 60991 -w 30' \
    >/dev/null

docker run --detach --name "$ethernet_probe_container" \
    --network "container:$haggai_container" \
    --user 65534:65534 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --read-only \
    --pids-limit 4 \
    --entrypoint /bin/sh \
    "$runtime_image" -ec '
        haggai_eth0="$(ip -o -4 address show dev eth0 scope global |
            awk '\''$4 !~ /^169[.]254[.]77[.]/ { sub(/\/.*/, "", $4); print $4; exit }'\'')"
        [ -n "$haggai_eth0" ]
        printf "haggai-ethernet-ok\n" | exec nc -l -s "$haggai_eth0" -p 60992 -w 30
    ' >/dev/null

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
        # The internal test container itself sits on 172.30.77.0/29 to reach
        # the outer server socket. Override only the two reserved Haggai
        # destinations so they exercise the encrypted interface like a real
        # remote client rather than following that connected Docker route.
        ip route replace 172.30.77.3/32 dev wg-test
        ip route replace 172.30.77.4/32 dev wg-test

        trace="$(curl --fail --silent --show-error --max-time 20 \
            https://1.1.1.1/cdn-cgi/trace)"
        handshake="$(wg show wg-test latest-handshakes | cut -f2)"
        [ "${handshake:-0}" -gt 0 ]

        observed_ip="$(printf "%s\\n" "$trace" | grep "^ip=" | cut -d= -f2-)"
        observed_country="$(printf "%s\\n" "$trace" | grep "^loc=" | cut -d= -f2-)"
        loopback_probe="$(timeout 5 nc -w 3 172.30.77.3 60991)"
        ethernet_probe="$(timeout 5 nc -w 3 172.30.77.4 60992)"
        [ "$loopback_probe" = haggai-loopback-ok ]
        [ "$ethernet_probe" = haggai-ethernet-ok ]
        printf "Observed VPN egress IPv4: %s\\n" "$observed_ip"
        printf "Observed country: %s\\n" "$observed_country"
        printf "Authenticated WireGuard handshake: yes\\n"
        printf "Haggai loopback-only TCP path: yes\\n"
        printf "Haggai eth0-only TCP path: yes\\n"
    '

cleanup_probes
trap - EXIT HUP INT TERM
