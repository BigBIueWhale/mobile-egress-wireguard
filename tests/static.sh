#!/bin/sh
set -eu

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"

for script in container/*.sh scripts/*.sh tests/*.sh; do
    sh -n "$script"
done

[ "$(git branch --show-current)" = master ] || {
    printf 'the public project must remain on the master branch\n' >&2
    exit 1
}

docker compose --project-directory "$project_dir" \
    --file "$project_dir/compose.yaml" config --quiet

if rg -n '(^|[^[:alpha:]])(latest|privileged:[[:space:]]*true|network_mode:[[:space:]]*host|pid:[[:space:]]*host|/var/run/docker.sock|/run/docker.sock)' \
    Dockerfile compose.yaml; then
    printf 'forbidden mutable or host-privileged construct found\n' >&2
    exit 1
fi

if rg -n '^(ARG|ENV)[[:space:]]' Dockerfile; then
    printf 'Dockerfile input override found; release inputs must be literal and reviewed\n' >&2
    exit 1
fi

grep -Fqx '# syntax=docker/dockerfile:1.8@sha256:e87caa74dcb7d46cd820352bfea12591f3dba3ddc4285e19c7dcd13359f7cefd' Dockerfile
grep -Fq 'FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS patched-base' Dockerfile

unpinned_apks="$(awk '
    /^RUN apk add / { in_apk = 1 }
    in_apk {
        line = $0
        continued = sub(/\\$/, "", line)
        count = split(line, words, /[[:space:]]+/)
        for (i = 1; i <= count; i++) {
            word = words[i]
            if (word == "" || word == "RUN" || word == "apk" || word == "add" || word ~ /^--/) continue
            if (word !~ /^[A-Za-z0-9+_.-]+=[A-Za-z0-9+_.-]+$/) print word
        }
        if (!continued) in_apk = 0
    }
' Dockerfile)"
[ -z "$unpinned_apks" ] || {
    printf 'unpinned APK token(s):\n%s\n' "$unpinned_apks" >&2
    exit 1
}

published_count="$(docker compose --project-directory "$project_dir" \
    --file "$project_dir/compose.yaml" config --format json |
    awk 'BEGIN { count=0 } /"published": "443"/ { count++ } END { print count }')"
[ "$published_count" -eq 1 ]

compose_rendered="$(docker compose --project-directory "$project_dir" --file compose.yaml config)"
printf '%s\n' "$compose_rendered" | grep -Fq 'host_ip: 0.0.0.0'
printf '%s\n' "$compose_rendered" | grep -Fq 'protocol: udp'
printf '%s\n' "$compose_rendered" | grep -Fq 'read_only: true'
printf '%s\n' "$compose_rendered" | grep -Fq 'no-new-privileges:true'

(cd vendor/wireguard-tools && sha256sum --check CHECKSUMS.sha256)

git check-ignore --quiet config/endpoint
git check-ignore --quiet config/public-listeners.tsv
git check-ignore --quiet secrets/server.key
git check-ignore --quiet clients/android.conf
git check-ignore --quiet revoked/example.client.conf

if git ls-files --error-unmatch \
    config/endpoint config/public-listeners.tsv secrets/server.key \
    clients/android.conf clients/ios.conf >/dev/null 2>&1; then
    printf 'deployment-local endpoint, inventory, or credential is tracked\n' >&2
    exit 1
fi

if ./scripts/init.sh >/dev/null 2>&1; then
    printf 'initialization accepted a missing required endpoint argument\n' >&2
    exit 1
fi

if ./scripts/render-client-endpoints.sh >/dev/null 2>&1; then
    printf 'endpoint rendering accepted a missing required endpoint argument\n' >&2
    exit 1
fi

if [ -f config/endpoint ]; then
    deployment_endpoint="$(sed -n '1p' config/endpoint)"
    if [ -n "$deployment_endpoint" ] && git grep -Fn -- "$deployment_endpoint"; then
        printf 'the local deployment endpoint appears in tracked content\n' >&2
        exit 1
    fi

    resolved_addresses="$(getent ahostsv4 "$deployment_endpoint" 2>/dev/null | \
        awk '{ print $1 }' | LC_ALL=C sort -u || true)"
    for resolved_address in $resolved_addresses; do
        if git grep -Fn -- "$resolved_address"; then
            printf 'the endpoint resolved address appears in tracked content\n' >&2
            exit 1
        fi
    done
fi

if rg -n 'WG_CONFIG|\$\{[^}]*:-[^}]*\}' container compose.yaml; then
    printf 'runtime fallback or environment-selected server configuration found\n' >&2
    exit 1
fi

for directory in secrets secrets/peers clients revoked; do
    [ "$(stat -c '%a' "$directory")" = 700 ] || {
        printf '%s must be mode 0700\n' "$directory" >&2
        exit 1
    }
done

find secrets clients revoked -type f ! -name .gitkeep -print | while IFS= read -r secret_file; do
    [ "$(stat -c '%a' "$secret_file")" = 600 ] || {
        printf '%s must be mode 0600\n' "$secret_file" >&2
        exit 1
    }
done

printf 'Static and publication-safety checks passed.\n'
