#!/bin/sh
set -eu

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
readonly project_dir
readonly secrets_dir="$project_dir/secrets"
readonly peers_dir="$secrets_dir/peers"
readonly clients_dir="$project_dir/clients"
readonly revoked_dir="$project_dir/revoked"
readonly tools_image="local/mobile-wireguard-tools:1.0.20260223"
readonly runtime_image="local/mobile-wireguard:1.0.20260223"
readonly haggai_container="haggai_computer"
readonly haggai_helper_container="mobile-wireguard-haggai-network"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

compose() {
    docker compose --project-directory "$project_dir" \
        --file "$project_dir/compose.yaml" "$@"
}

build_images() {
    compose --profile admin build vpn tools
}

vpn_container_id() {
    compose ps --all --quiet vpn 2>/dev/null || true
}

attach_haggai_network() {
    local container_id attachment
    container_id="$(vpn_container_id)"
    [ -n "$container_id" ] || die "VPN container was not created"

    attachment="$(docker inspect --format \
        '{{with index .NetworkSettings.Networks "bridge"}}{{json .DriverOpts}}|{{.GwPriority}}{{end}}' \
        "$container_id")"
    if [ -n "$attachment" ]; then
        [ "$attachment" = '{"com.docker.network.endpoint.ifname":"haggai0"}|-1' ] || \
            die "existing VPN attachment to bridge has unexpected settings: $attachment"
        return 0
    fi

    # Compose always supplies a DNS alias and Docker rejects aliases on its
    # built-in bridge. Use the Engine's ordinary endpoint operation directly,
    # with no alias, and make both the interface name and gateway priority exact.
    docker network connect \
        --driver-opt com.docker.network.endpoint.ifname=haggai0 \
        --gw-priority -1 \
        bridge "$container_id"
}

start_vpn() {
    compose up --detach --no-build vpn
    attach_haggai_network
    wait_until_ready
}

validate_haggai_environment() {
    local container_policy mount_policy network_policy route_localnet

    docker inspect "$haggai_container" >/dev/null 2>&1 || \
        die "required Haggai container does not exist: $haggai_container"

    container_policy="$(docker inspect --format \
        '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Config.Image}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.Privileged}}|{{.HostConfig.PidMode}}|{{json .HostConfig.CapAdd}}' \
        "$haggai_container")"
    [ "$container_policy" = 'true|healthy|haggai_computer:1.4.7|bridge|false||null' ] || \
        die "Haggai container does not match the required running 1.4.7 boundary: $container_policy"

    mount_policy="$(docker inspect --format \
        '{{len .Mounts}}|{{range .Mounts}}{{.Type}}|{{.Destination}}|{{.RW}}{{end}}' \
        "$haggai_container")"
    [ "$mount_policy" = '1|bind|/home/user|true' ] || \
        die "Haggai mount boundary drifted: $mount_policy"

    network_policy="$(docker inspect --format \
        '{{len .NetworkSettings.Networks}}|{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}/{{.IPPrefixLen}}|{{.Gateway}}{{end}}' \
        "$haggai_container")"
    printf '%s\n' "$network_policy" | \
        grep -Eq '^1\|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+\|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || \
        die "Haggai must be attached only to Docker's legacy bridge: $network_policy"

    [ "$(docker exec "$haggai_container" cat /proc/sys/net/ipv4/conf/all/route_localnet)" = 0 ] || \
        die "Haggai has an unsafe namespace-wide route_localnet setting"
    route_localnet="$(docker exec "$haggai_container" cat /proc/sys/net/ipv4/conf/eth0/route_localnet)"
    case "$route_localnet" in 0|1) ;; *) die "Haggai eth0 route_localnet is invalid" ;; esac

    docker exec "$haggai_container" ss -H -lnt | \
        awk '$4 == "0.0.0.0:21118" { found = 1 } END { exit !found }' || \
        die "Haggai's required 0.0.0.0:21118 listener is absent"
}

tool() {
    docker run --rm \
        --network none \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=4m,mode=1777 \
        "$tools_image" "$@"
}

tool_stdin() {
    docker run --rm --interactive \
        --network none \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=4m,mode=1777 \
        "$tools_image" "$@"
}

validate_endpoint_host() {
    local endpoint_value
    endpoint_value="$1"
    [ -n "$endpoint_value" ] || die "endpoint host is empty"
    [ "${#endpoint_value}" -le 253 ] || die "endpoint host is too long"

    case "$endpoint_value" in
        *[!0-9.]*)
            printf '%s\n' "$endpoint_value" | awk -F. '
                NR != 1 { exit 1 }
                NF < 2 { exit 1 }
                {
                    for (i = 1; i <= NF; i++) {
                        if (length($i) < 1 || length($i) > 63) exit 1
                        if ($i !~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) exit 1
                    }
                }
            ' || die "endpoint must be a plain IPv4 address or fully qualified DNS name"
            ;;
        *)
            printf '%s\n' "$endpoint_value" | awk -F. '
                NR != 1 { exit 1 }
                NF != 4 { exit 1 }
                {
                    for (i = 1; i <= 4; i++) {
                        if ($i !~ /^[0-9]+$/ || $i > 255 || (length($i) > 1 && substr($i, 1, 1) == "0")) exit 1
                    }
                }
            ' || die "endpoint IPv4 address is invalid"
            ;;
    esac
}

endpoint_host() {
    local endpoint_file endpoint_value
    endpoint_file="$project_dir/config/endpoint"
    [ -f "$endpoint_file" ] || \
        die "missing local endpoint configuration: supply --endpoint during initialization"
    [ "$(wc -l < "$endpoint_file" | tr -d ' ')" -eq 1 ] || \
        die "endpoint file must contain exactly one line"
    endpoint_value="$(sed -n '1p' "$endpoint_file")"
    validate_endpoint_host "$endpoint_value"
    printf '%s\n' "$endpoint_value"
}

persist_endpoint_host() {
    local endpoint_value
    endpoint_value="$1"
    validate_endpoint_host "$endpoint_value"
    write_private_value "$project_dir/config/endpoint" "$endpoint_value"
}

validate_client_name() {
    case "${1:-}" in
        ''|*[!a-z0-9_-]*|[!a-z]*|*--*|*__*)
            die "client name must start with a-z and contain only a-z, 0-9, _ or -"
            ;;
    esac
    [ "${#1}" -le 32 ] || die "client name must be at most 32 characters"
}

ensure_private_dirs() {
    mkdir -p "$secrets_dir" "$peers_dir" "$clients_dir" "$revoked_dir"
    chmod 700 "$secrets_dir" "$peers_dir" "$clients_dir" "$revoked_dir"
}

write_private_value() {
    local destination value old_umask temporary
    destination="$1"
    value="$2"
    old_umask="$(umask)"
    umask 077
    temporary="$(mktemp "${destination}.tmp.XXXXXX")"
    printf '%s\n' "$value" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$destination"
    umask "$old_umask"
}

running_container_id() {
    compose ps --status running --quiet vpn 2>/dev/null || true
}

haggai_helper_container_id() {
    compose ps --status running --quiet haggai-network 2>/dev/null || true
}

server_config_public_key() {
    local private_key_lines
    [ -s "$secrets_dir/server.conf" ] || die "missing server configuration"
    private_key_lines="$(grep -c '^PrivateKey *=' "$secrets_dir/server.conf" || true)"
    [ "$private_key_lines" -eq 1 ] || \
        die "server configuration must contain exactly one private key"
    sed -n 's/^PrivateKey *= *//p' "$secrets_dir/server.conf" | tool_stdin wg pubkey
}

wait_until_ready() {
    local attempts container_id helper_id
    attempts=0
    while [ "$attempts" -lt 45 ]; do
        container_id="$(running_container_id)"
        helper_id="$(haggai_helper_container_id)"
        if [ -n "$container_id" ] && [ -n "$helper_id" ] && \
            [ "$(docker exec "$container_id" wg show wg0 listen-port 2>/dev/null || true)" = 443 ] && \
            docker exec "$helper_id" nft list set ip haggai_vpn_bridge active_gateway \
                2>/dev/null | grep -Fq '169.254.77.1'; then
            return 0
        fi

        attempts=$((attempts + 1))
        sleep 1
    done

    compose logs --no-color --tail 80 haggai-network vpn >&2 || true
    die "VPN and its mandatory Haggai path did not become ready within 45 seconds"
}

recreate_if_running() {
    if [ -n "$(running_container_id)" ]; then
        compose up --detach --force-recreate --no-build vpn
        attach_haggai_network
        wait_until_ready
    fi
}
