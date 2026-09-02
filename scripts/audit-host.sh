#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

inventory="$project_dir/config/public-listeners.tsv"
candidate=false
case "${1:-}" in
    '') ;;
    --print-candidate) candidate=true ;;
    *) die "usage: $0 [--print-candidate]" ;;
esac

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/mobile-wireguard-audit.XXXXXX")"
cleanup() {
    rm -f -- "$temporary_dir/actual" "$temporary_dir/expected"
    rmdir -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

# ss emits LOCAL as the fifth field for both TCP and UDP with these options.
# Keep the literal bind address because 127.0.0.1 and 0.0.0.0 are materially
# different security boundaries. Only IPv4 and IPv6 loopback are exempt.
ss -H -lntu | awk '
    {
        protocol = $1
        local = $5
        port = local
        sub(/^.*:/, "", port)
        address = substr(local, 1, length(local) - length(port) - 1)
        if (address ~ /^127\./ || address == "[::1]" || address == "::1") next
        printf "%s\t%s\t%s\n", protocol, address, port
    }
' | LC_ALL=C sort -u > "$temporary_dir/actual"

if [ "$candidate" = true ]; then
    printf '# protocol\tbind-address\tport\towner\n'
    while IFS="$(printf '\t')" read -r protocol address port; do
        if [ "$protocol" = udp ] && [ "$address" = 0.0.0.0 ] && [ "$port" = 443 ]; then
            owner=this-project
        else
            owner=external:REVIEW-AND-NAME-OWNER
        fi
        printf '%s\t%s\t%s\t%s\n' "$protocol" "$address" "$port" "$owner"
    done < "$temporary_dir/actual"
    exit 0
fi

[ -f "$inventory" ] || die "missing local listener inventory: copy config/public-listeners.example.tsv to config/public-listeners.tsv, review every row, then rerun"

: > "$temporary_dir/expected"
own_rows=0
line_number=0
while IFS="$(printf '\t')" read -r protocol address port owner extra; do
    line_number=$((line_number + 1))
    case "$protocol" in ''|'#'*) continue ;; esac
    [ -z "${extra:-}" ] || die "$inventory:$line_number has extra columns"
    case "$protocol" in tcp|udp) ;; *) die "$inventory:$line_number has invalid protocol" ;; esac
    [ -n "$address" ] || die "$inventory:$line_number has an empty bind address"
    case "$port" in ''|*[!0-9]*) die "$inventory:$line_number has an invalid port" ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "$inventory:$line_number has an out-of-range port"
    case "$owner" in
        this-project)
            [ "$protocol" = udp ] && [ "$address" = 0.0.0.0 ] && [ "$port" = 443 ] || \
                die "$inventory:$line_number may attribute only 0.0.0.0:443/udp to this project"
            own_rows=$((own_rows + 1))
            ;;
        external:[A-Za-z0-9]*)
            case "$owner" in *[!A-Za-z0-9._:/-]*) die "$inventory:$line_number has an invalid external owner label" ;; esac
            ;;
        *) die "$inventory:$line_number must name this-project or an external:<owner>" ;;
    esac
    printf '%s\t%s\t%s\n' "$protocol" "$address" "$port" >> "$temporary_dir/expected"
done < "$inventory"

[ "$own_rows" -eq 1 ] || die "$inventory must contain exactly one this-project row"
LC_ALL=C sort -u -o "$temporary_dir/expected" "$temporary_dir/expected"

if ! diff -u "$temporary_dir/expected" "$temporary_dir/actual"; then
    die "non-loopback listener surface differs from the reviewed inventory; use --print-candidate for a non-authoritative snapshot"
fi

container_id="$(running_container_id)"
[ -n "$container_id" ] || die "VPN container is not running"
helper_id="$(haggai_helper_container_id)"
[ -n "$helper_id" ] || die "mandatory Haggai helper is not running"
validate_haggai_environment
haggai_id="$(docker inspect --format '{{.Id}}' "$haggai_container")"

[ "$(docker inspect --format '{{.Name}}' "$container_id")" = /mobile-wireguard ] || \
    die "the VPN container has an unexpected name"
[ "$(docker inspect --format '{{.Config.Image}}' "$container_id")" = "$runtime_image" ] || \
    die "the VPN container uses an unexpected image tag"
[ "$(docker inspect --format '{{.Image}}' "$container_id")" = \
  "$(docker image inspect --format '{{.Id}}' "$runtime_image")" ] || \
    die "the running VPN container does not use the locally pinned image"
[ "$(docker inspect --format '{{.Name}}' "$helper_id")" = /mobile-wireguard-haggai-network ] || \
    die "the Haggai helper has an unexpected name"
[ "$(docker inspect --format '{{.Config.Image}}' "$helper_id")" = "$runtime_image" ] || \
    die "the Haggai helper uses an unexpected image tag"
[ "$(docker inspect --format '{{.Image}}' "$helper_id")" = \
  "$(docker image inspect --format '{{.Id}}' "$runtime_image")" ] || \
    die "the Haggai helper does not use the locally pinned image"

runtime_policy="$(docker inspect --format '{{.State.Running}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.PidMode}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.CapAdd}}|{{json .HostConfig.SecurityOpt}}|{{.HostConfig.PidsLimit}}' "$container_id")"
[ "$runtime_policy" = 'true|true|false|mobile-wireguard-egress||["ALL"]|["CAP_DAC_READ_SEARCH","CAP_NET_ADMIN","CAP_NET_RAW","CAP_SETGID","CAP_SETUID"]|["no-new-privileges:true"]|32' ] || \
    die "the VPN container hardening policy drifted: $runtime_policy"

helper_policy="$(docker inspect --format '{{.State.Running}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.PidMode}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.CapAdd}}|{{json .HostConfig.SecurityOpt}}|{{.HostConfig.PidsLimit}}|{{len .Mounts}}|{{json .HostConfig.Sysctls}}' "$helper_id")"
[ "$helper_policy" = "true|true|false|container:$haggai_id||[\"ALL\"]|[\"CAP_NET_ADMIN\"]|[\"no-new-privileges:true\"]|8|0|{\"net.ipv4.conf.eth0.route_localnet\":\"1\"}" ] || \
    die "the Haggai helper boundary drifted: $helper_policy"

mount_policy="$(docker inspect --format '{{len .Mounts}}|{{range .Mounts}}{{.Type}}|{{.Destination}}|{{.RW}}{{end}}' "$container_id")"
[ "$mount_policy" = '1|bind|/run/secrets/wg0.conf|false' ] || \
    die "the VPN container mount boundary drifted: $mount_policy"

[ "$(docker port "$container_id" 443/udp)" = '0.0.0.0:443' ] || \
    die "the VPN container publication is not exactly 0.0.0.0:443/udp"
[ -z "$(docker port "$helper_id")" ] || die "the Haggai helper unexpectedly publishes a port"

network_policy="$(docker inspect --format '{{len .NetworkSettings.Networks}}|{{with index .NetworkSettings.Networks "mobile-wireguard-egress"}}{{.IPAddress}}/{{.IPPrefixLen}}|{{.Gateway}}|{{.GwPriority}}|{{index .DriverOpts "com.docker.network.endpoint.ifname"}}{{end}}|{{with index .NetworkSettings.Networks "bridge"}}{{.GwPriority}}|{{json .Aliases}}|{{index .DriverOpts "com.docker.network.endpoint.ifname"}}{{end}}' "$container_id")"
[ "$network_policy" = '2|172.30.77.2/29|172.30.77.1|1|outer0|-1|[]|haggai0' ] || \
    die "the VPN network attachments drifted: $network_policy"
[ "$(docker exec "$container_id" cat /sys/class/net/haggai0/address)" = 02:77:4d:47:00:01 ] || \
    die "the live Haggai transit interface has an unexpected MAC address"
[ "$(docker exec "$container_id" ip -4 route show default)" = 'default via 172.30.77.1 dev outer0 ' ] || \
    die "the VPN default route is not exclusively outer0"

pid1_policy="$(docker exec "$container_id" sh -ec '
    awk '\''
        /^Uid:/ { print "uid=" $2 "," $3 "," $4 "," $5 }
        /^Gid:/ { print "gid=" $2 "," $3 "," $4 "," $5 }
        /^CapPrm:/ { print "permitted=" $2 }
        /^CapEff:/ { print "effective=" $2 }
        /^NoNewPrivs:/ { print "no-new-privs=" $2 }
    '\'' /proc/1/status
')"
printf '%s\n' "$pid1_policy" | grep -Fx 'uid=65534,65534,65534,65534' >/dev/null
printf '%s\n' "$pid1_policy" | grep -Fx 'gid=65534,65534,65534,65534' >/dev/null
printf '%s\n' "$pid1_policy" | grep -Fx 'permitted=0000000000000000' >/dev/null
printf '%s\n' "$pid1_policy" | grep -Fx 'effective=0000000000000000' >/dev/null
printf '%s\n' "$pid1_policy" | grep -Fx 'no-new-privs=1' >/dev/null

helper_pid1_policy="$(docker exec "$helper_id" sh -ec '
    awk '\''
        /^Uid:/ { print "uid=" $2 "," $3 "," $4 "," $5 }
        /^Gid:/ { print "gid=" $2 "," $3 "," $4 "," $5 }
        /^CapPrm:/ { print "permitted=" $2 }
        /^CapEff:/ { print "effective=" $2 }
        /^NoNewPrivs:/ { print "no-new-privs=" $2 }
    '\'' /proc/1/status
')"
printf '%s\n' "$helper_pid1_policy" | grep -Fx 'uid=0,0,0,0' >/dev/null
printf '%s\n' "$helper_pid1_policy" | grep -Fx 'gid=0,0,0,0' >/dev/null
printf '%s\n' "$helper_pid1_policy" | grep -Fx 'permitted=0000000000001000' >/dev/null
printf '%s\n' "$helper_pid1_policy" | grep -Fx 'effective=0000000000001000' >/dev/null
printf '%s\n' "$helper_pid1_policy" | grep -Fx 'no-new-privs=1' >/dev/null
if docker exec "$helper_id" sh -ec "ls -l /proc/1/fd | grep -F 'socket:['"; then
    die "the Haggai helper PID 1 unexpectedly owns a network socket"
fi

[ "$(docker exec "$container_id" wg show wg0 listen-port)" = 443 ] || \
    die "WireGuard is not listening on its one configured port"

filter_rules="$(docker exec "$container_id" nft list table inet vpn_filter)"
[ "$(printf '%s\n' "$filter_rules" | grep -Fc 'policy drop;')" -eq 2 ] || \
    die "the namespace firewall must have exactly two default-drop policies"
[ "$(printf '%s\n' "$filter_rules" | grep -Fc 'iifname "outer0" udp dport 443 accept')" -eq 1 ] || \
    die "the namespace firewall does not expose exactly UDP/443"
if printf '%s\n' "$filter_rules" | grep -Fq 'tcp dport'; then
    die "the namespace firewall unexpectedly accepts TCP"
fi
printf '%s\n' "$filter_rules" | grep -F 'iifname "wg0" oifname "outer0" ip saddr 10.77.0.0/24 accept' >/dev/null
printf '%s\n' "$filter_rules" | grep -F 'iifname "outer0" oifname "wg0" ip daddr 10.77.0.0/24 ct state' >/dev/null
printf '%s\n' "$filter_rules" | grep -F 'iifname "wg0" oifname "haggai0" ip saddr 10.77.0.0/24' >/dev/null
printf '%s\n' "$filter_rules" | grep -F 'iifname "haggai0" oifname "wg0" ip daddr 10.77.0.0/24' >/dev/null

nat_rules="$(docker exec "$container_id" nft list table ip vpn_nat)"
printf '%s\n' "$nat_rules" | grep -F 'ip daddr 172.30.77.3' | grep -F 'dnat to 169.254.77.2' >/dev/null
printf '%s\n' "$nat_rules" | grep -F 'ip daddr 172.30.77.4' | grep -F 'dnat to 169.254.77.3' >/dev/null
printf '%s\n' "$nat_rules" | grep -F 'snat to 169.254.77.1' >/dev/null
printf '%s\n' "$nat_rules" | grep -F 'oifname "outer0" ip saddr 10.77.0.0/24 masquerade' >/dev/null

helper_rules="$(docker exec "$helper_id" nft list table ip haggai_vpn_bridge)"
printf '%s\n' "$helper_rules" | grep -F 'comment "managed by BigBIueWhale/mobile-egress-wireguard"' >/dev/null
printf '%s\n' "$helper_rules" | grep -F '169.254.77.1 expires' >/dev/null
printf '%s\n' "$helper_rules" | grep -F 'ether saddr 02:77:4d:47:00:01' | grep -F 'dnat to 127.0.0.1' >/dev/null
printf '%s\n' "$helper_rules" | grep -F 'ether saddr 02:77:4d:47:00:01' | grep -F 'dnat to ' | grep -Fv 'dnat to 127.0.0.1' >/dev/null
printf '%s\n' "$helper_rules" | grep -F 'iifname "eth0" ip daddr 127.0.0.0/8 drop' >/dev/null

[ "$(docker exec "$haggai_container" cat /proc/sys/net/ipv4/conf/eth0/route_localnet)" = 1 ] || \
    die "Haggai's eth0-scoped route_localnet setting is absent"
haggai_addresses="$(docker exec "$haggai_container" ip -o -4 address show dev eth0)"
printf '%s\n' "$haggai_addresses" | grep -F 'inet 169.254.77.2/32 ' | grep -F 'eth0:mvwg-lo' >/dev/null
printf '%s\n' "$haggai_addresses" | grep -F 'inet 169.254.77.3/32 ' | grep -F 'eth0:mvwg-eth' >/dev/null
[ "$(docker exec "$haggai_container" ip -4 route show 169.254.77.1/32)" = '169.254.77.1 dev eth0 scope link src 169.254.77.2 ' ] || \
    die "Haggai's reply route to the VPN transit endpoint drifted"

printf 'Host listener inventory: exact match (%s non-loopback socket(s)).\n' \
    "$(wc -l < "$temporary_dir/actual" | tr -d ' ')"
printf 'VPN container boundary: exact match; steady-state UID/GID 65534, zero capabilities.\n'
printf 'Haggai integration: exact match; helper has only namespace NET_ADMIN and no socket.\n'
printf 'Endpoint: %s:443/udp\n' "$(endpoint_host)"
