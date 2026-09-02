#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

validate_haggai_environment
docker image inspect "$runtime_image" >/dev/null 2>&1 || \
    die "runtime image is unavailable; refusing an incomplete namespace cleanup"

# Cut authenticated traffic first, then stop the namespace helper so its
# expiring authorization element is removed before resetting route_localnet.
compose stop vpn haggai-network

docker run --rm \
    --network "container:$haggai_container" \
    --sysctl net.ipv4.conf.eth0.route_localnet=0 \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --security-opt no-new-privileges:true \
    --read-only \
    --entrypoint /usr/local/sbin/haggai-network-reset \
    "$runtime_image"

compose down --remove-orphans
[ "$(docker exec "$haggai_container" cat /proc/sys/net/ipv4/conf/eth0/route_localnet)" = 0 ] || \
    die "Haggai eth0 route_localnet was not reset"

printf 'VPN removed and Haggai namespace routing state reset; Haggai kept running.\n'
