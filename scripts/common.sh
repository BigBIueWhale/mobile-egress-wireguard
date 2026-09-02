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

wait_until_ready() {
    local attempts container_id
    attempts=0
    while [ "$attempts" -lt 20 ]; do
        container_id="$(running_container_id)"
        if [ -n "$container_id" ] && \
            [ "$(docker exec "$container_id" wg show wg0 listen-port 2>/dev/null || true)" = 443 ]; then
            return 0
        fi

        attempts=$((attempts + 1))
        sleep 1
    done

    compose logs --no-color --tail 50 vpn >&2 || true
    die "VPN did not become ready on UDP/443 within 20 seconds"
}

recreate_if_running() {
    if [ -n "$(running_container_id)" ]; then
        compose up --detach --force-recreate --no-build vpn
        wait_until_ready
    fi
}
