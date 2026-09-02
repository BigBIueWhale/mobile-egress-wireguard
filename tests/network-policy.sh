#!/bin/sh
set -eu

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
readonly runtime_image="local/mobile-wireguard:1.0.20260223"
readonly donor="mobile-wireguard-test-haggai-donor"
readonly helper="mobile-wireguard-test-haggai-helper"
readonly source="mobile-wireguard-test-haggai-source"
readonly attacker="mobile-wireguard-test-haggai-attacker"
readonly udp_loop="mobile-wireguard-test-haggai-udp-loop"
readonly udp_eth="mobile-wireguard-test-haggai-udp-eth"

fail() {
    printf 'network-policy-test: %s\n' "$*" >&2
    exit 1
}

for test_container in "$donor" "$helper" "$source" "$attacker" "$udp_loop" "$udp_eth"; do
    if docker inspect "$test_container" >/dev/null 2>&1; then
        fail "refusing to remove a pre-existing container: $test_container"
    fi
done

cleanup() {
    docker rm -f "$attacker" "$source" "$udp_loop" "$udp_eth" "$helper" "$donor" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

docker run --detach --name "$donor" \
    --network bridge \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --read-only \
    --entrypoint /usr/bin/nc \
    "$runtime_image" -l -s 0.0.0.0 -p 21118 -w 120 >/dev/null

docker run --detach --name "$helper" \
    --network "container:$donor" \
    --sysctl net.ipv4.conf.eth0.route_localnet=1 \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --security-opt no-new-privileges:true \
    --read-only \
    --pids-limit 8 \
    --entrypoint /usr/local/sbin/haggai-network-entrypoint \
    "$runtime_image" >/dev/null

attempt=0
until docker logs "$helper" 2>&1 | grep -Fq 'mandatory VPN routing is armed'; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 20 ]; then
        docker logs "$helper" >&2
        fail "helper did not become ready"
    fi
    sleep 1
done

docker run --detach --name "$source" \
    --network bridge \
    --mac-address 02:77:4d:47:00:01 \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --security-opt no-new-privileges:true \
    --read-only \
    --entrypoint /bin/sh \
    "$runtime_image" -ec '
        ip address add 169.254.77.1/32 dev eth0
        ip route add 169.254.77.2/32 dev eth0 src 169.254.77.1
        ip route add 169.254.77.3/32 dev eth0 src 169.254.77.1
        exec sleep 120
    ' >/dev/null

donor_ip="$(docker inspect "$donor" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
docker exec --detach "$donor" nc -l -s 127.0.0.1 -p 60991 -w 30
docker exec --detach "$donor" nc -l -s "$donor_ip" -p 60992 -w 30
sleep 1
docker exec "$source" nc -z -w 3 169.254.77.2 60991
docker exec "$source" nc -z -w 3 169.254.77.3 60992

docker run --detach --name "$udp_loop" \
    --network "container:$donor" \
    --user 65534:65534 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --read-only \
    --entrypoint /usr/bin/nc \
    "$runtime_image" -u -l -s 127.0.0.1 -p 60993 -w 5 >/dev/null
docker run --detach --name "$udp_eth" \
    --network "container:$donor" \
    --user 65534:65534 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --read-only \
    --entrypoint /usr/bin/nc \
    "$runtime_image" -u -l -s "$donor_ip" -p 60994 -w 5 >/dev/null
sleep 1
printf 'udp-loopback-ok\n' | docker exec --interactive "$source" \
    nc -u -w 1 169.254.77.2 60993
printf 'udp-ethernet-ok\n' | docker exec --interactive "$source" \
    nc -u -w 1 169.254.77.3 60994

attempt=0
until [ "$(docker logs "$udp_loop")" = udp-loopback-ok ] && \
    [ "$(docker logs "$udp_eth")" = udp-ethernet-ok ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || fail "UDP mappings did not deliver both payloads"
    sleep 1
done
[ "$(docker logs "$udp_loop")" = udp-loopback-ok ] || fail "loopback UDP mapping failed"
[ "$(docker logs "$udp_eth")" = udp-ethernet-ok ] || fail "eth0 UDP mapping failed"

# The same source IP from the wrong Ethernet identity must not be authorized.
docker stop --time 1 "$source" >/dev/null
docker rm "$source" >/dev/null
docker run --detach --name "$attacker" \
    --network bridge \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --security-opt no-new-privileges:true \
    --read-only \
    --entrypoint /bin/sh \
    "$runtime_image" -ec '
        ip address add 169.254.77.1/32 dev eth0
        ip route add 169.254.77.2/32 dev eth0 src 169.254.77.1
        exec sleep 120
    ' >/dev/null
docker exec --detach "$donor" nc -l -s 127.0.0.1 -p 60995 -w 5
sleep 1
if docker exec "$attacker" nc -z -w 2 169.254.77.2 60995; then
    fail "wrong-MAC source reached Haggai ingress"
fi
docker stop --time 1 "$attacker" >/dev/null
docker rm "$attacker" >/dev/null

docker run --detach --name "$source" \
    --network bridge \
    --mac-address 02:77:4d:47:00:01 \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --security-opt no-new-privileges:true \
    --read-only \
    --entrypoint /bin/sh \
    "$runtime_image" -ec '
        ip address add 169.254.77.1/32 dev eth0
        ip route add 169.254.77.2/32 dev eth0 src 169.254.77.1
        exec sleep 120
    ' >/dev/null
docker exec --detach "$donor" nc -l -s 127.0.0.1 -p 60996 -w 20
sleep 1
docker exec "$source" nc -z -w 2 169.254.77.2 60996

# SIGKILL bypasses the helper's trap. The nftables lease must still expire and
# close existing/new traffic, after which the explicit reset must remove all
# namespace residue.
docker kill --signal KILL "$helper" >/dev/null
sleep 11
docker exec --detach "$donor" nc -l -s 127.0.0.1 -p 60997 -w 5
if docker exec "$source" nc -z -w 2 169.254.77.2 60997; then
    fail "expired helper authorization remained usable"
fi

docker rm "$helper" >/dev/null
docker run --rm \
    --network "container:$donor" \
    --sysctl net.ipv4.conf.eth0.route_localnet=0 \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --security-opt no-new-privileges:true \
    --read-only \
    --entrypoint /usr/local/sbin/haggai-network-reset \
    "$runtime_image" >/dev/null

[ "$(docker exec "$donor" cat /proc/sys/net/ipv4/conf/eth0/route_localnet)" = 0 ] || \
    fail "route_localnet reset failed"
if docker exec "$donor" nft list table ip haggai_vpn_bridge >/dev/null 2>&1; then
    fail "owned nftables table survived reset"
fi
if docker exec "$donor" ip -o -4 address show dev eth0 | grep -Fq '169.254.77.'; then
    fail "owned link-local address survived reset"
fi

printf 'Mandatory Haggai TCP/UDP mappings, source restriction, fail-closed lease, and reset passed.\n'
