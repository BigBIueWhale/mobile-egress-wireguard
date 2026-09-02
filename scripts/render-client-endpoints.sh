#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/common.sh"

usage="usage: $0 --endpoint <DNS-name-or-IPv4>"
[ "$#" -eq 2 ] || die "$usage"
[ "$1" = "--endpoint" ] || die "$usage"
endpoint="$2"
validate_endpoint_host "$endpoint"

ensure_private_dirs

case "$endpoint" in
    *[!0-9.]*)
        resolved="$(getent ahostsv4 "$endpoint" 2>/dev/null | awk 'NR == 1 { print $1 }')"
        [ -n "$resolved" ] || die "endpoint has no IPv4 DNS result: $endpoint"
        [ -z "$(getent ahostsv6 "$endpoint" 2>/dev/null || true)" ] || \
            die "endpoint publishes IPv6 but this deployment listens on IPv4 only: $endpoint"
        ;;
    *)
        resolved="$endpoint"
        ;;
esac

# Validate every profile before changing the saved endpoint or any profile.
profile_count=0
for profile in "$clients_dir"/*.conf; do
    [ -e "$profile" ] || continue
    profile_count=$((profile_count + 1))
    client_name="$(basename "$profile" .conf)"
    validate_client_name "$client_name"

    endpoint_lines="$(grep -c '^Endpoint *=' "$profile" || true)"
    [ "$endpoint_lines" -eq 1 ] || \
        die "$profile must contain exactly one Endpoint line"
done

[ "$profile_count" -gt 0 ] || die "no client profiles exist"
persist_endpoint_host "$endpoint"

for profile in "$clients_dir"/*.conf; do
    client_name="$(basename "$profile" .conf)"

    umask 077
    temporary="$(mktemp "$clients_dir/$client_name.conf.tmp.XXXXXX")"
    sed "s|^Endpoint *=.*|Endpoint = $endpoint:443|" "$profile" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$profile"
    "$script_dir/render-qr.sh" "$client_name"
done

printf 'Rendered %s client endpoint(s) as %s:443 (IPv4 %s).\n' \
    "$profile_count" "$endpoint" "$resolved"
