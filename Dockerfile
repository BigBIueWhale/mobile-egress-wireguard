# syntax=docker/dockerfile:1.8@sha256:e87caa74dcb7d46cd820352bfea12591f3dba3ddc4285e19c7dcd13359f7cefd

# Every fetched build input and every installed APK in the added dependency
# closures is immutable here. The service's wg control utility is compiled
# from the vendored, authenticated upstream source archive.
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS patched-base

# 3.24.1 is the current Alpine image release, while these signed repository
# revisions contain newer fixes than the image snapshot. Pin them explicitly
# so a rebuild cannot silently select a different revision.
RUN apk add --no-cache --upgrade \
      apk-tools=3.0.8-r0 \
      libapk=3.0.8-r0 \
      libcrypto3=3.5.8-r0 \
      libssl3=3.5.8-r0

FROM patched-base AS build

RUN apk add --no-cache \
      binutils=2.45.1-r1 \
      gcc=15.2.0-r5 \
      gmp=6.3.0-r4 \
      isl26=0.26-r2 \
      jansson=2.15.0-r0 \
      libatomic=15.2.0-r5 \
      libgcc=15.2.0-r5 \
      libgcc-static=15.2.0-r5 \
      libgomp=15.2.0-r5 \
      libmnl=1.0.5-r2 \
      libmnl-dev=1.0.5-r2 \
      linux-headers=7.0.0-r1 \
      make=4.4.1-r4 \
      mpc1=1.3.1-r1 \
      mpfr4=4.2.2-r0 \
      musl-dev=1.2.6-r2 \
      pkgconf=2.5.1-r0 \
      libstdc++=15.2.0-r5 \
      xz=5.8.3-r0 \
      xz-libs=5.8.3-r0 \
      zstd-libs=1.5.7-r2

COPY vendor/wireguard-tools/wireguard-tools-1.0.20260223.tar.xz /tmp/wireguard-tools.tar.xz

RUN echo "af459827b80bfd31b83b08077f4b5843acb7d18ad9a33a2ef532d3090f291fbf  /tmp/wireguard-tools.tar.xz" | sha256sum -c - \
    && mkdir -p /tmp/wireguard-tools /out \
    && tar -xJf /tmp/wireguard-tools.tar.xz \
         --strip-components=1 -C /tmp/wireguard-tools \
    && make -C /tmp/wireguard-tools/src -j"$(nproc)" \
         LDFLAGS="-Wl,-z,relro,-z,now -pie" \
         WITH_BASHCOMPLETION=no \
         WITH_WGQUICK=no \
         WITH_SYSTEMDUNITS=no \
         wg \
    && install -m 0755 /tmp/wireguard-tools/src/wg /out/wg \
    && strip /out/wg \
    && /out/wg --version | grep -Fx "wireguard-tools v1.0.20260223 - https://git.zx2c4.com/wireguard-tools/"

FROM patched-base AS runtime

RUN apk add --no-cache \
      gmp=6.3.0-r4 \
      jansson=2.15.0-r0 \
      libmnl=1.0.5-r2 \
      libncursesw=6.6_p20260516-r0 \
      libnftnl=1.3.1-r0 \
      ncurses-terminfo-base=6.6_p20260516-r0 \
      readline=8.3.3-r1 \
      nftables=1.1.6-r1

COPY --from=build /out/wg /usr/local/bin/wg
COPY --chmod=0755 container/entrypoint.sh /usr/local/sbin/vpn-entrypoint
COPY --chmod=0444 container/vpn.nft /etc/nftables.d/vpn.nft

LABEL org.opencontainers.image.title="Mobile egress WireGuard" \
      org.opencontainers.image.description="Single-protocol, source-pinned WireGuard control plane using the host kernel data plane" \
      org.opencontainers.image.source="https://git.zx2c4.com/wireguard-tools" \
      org.opencontainers.image.version="1.0.20260223"

ENTRYPOINT ["/usr/local/sbin/vpn-entrypoint"]

FROM runtime AS tools

# This image is only invoked for offline administration and smoke tests. None
# of these programs is present in or reachable through the service container.
RUN apk add --no-cache \
      brotli-libs=1.2.0-r1 \
      c-ares=1.34.8-r0 \
      ca-certificates=20260611-r0 \
      curl=8.21.0-r0 \
      libcurl=8.21.0-r0 \
      libidn2=2.3.8-r0 \
      libpng=1.6.58-r1 \
      libpsl=0.21.5-r3 \
      libqrencode=4.1.1-r3 \
      libqrencode-tools=4.1.1-r3 \
      libunistring=1.4.2-r0 \
      nghttp2-libs=1.69.0-r0 \
      zstd-libs=1.5.7-r2

ENTRYPOINT []
CMD ["/bin/sh"]
