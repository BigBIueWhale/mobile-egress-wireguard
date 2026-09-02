# Mobile egress WireGuard with Haggai access

This project exposes one deliberately fixed VPN mode: standard WireGuard over
`UDP/443`, unrestricted IPv4 egress through the host, and authenticated access
to every TCP/UDP port in the running `haggai_computer` network namespace. A
phone or computer uses the official WireGuard client. There is no egress-only
mode, Haggai-disabled mode, port allowlist, web UI, control API, alternate
transport, obfuscation layer, or protocol fallback.

The deployment is location-neutral. Its endpoint, keys, device profiles, QR
codes, and host-specific listener inventory are local ignored files, so the
repository can be published without publishing access credentials or tying the
software to one operator, domain, address, or country.

## Design in one minute

- The host's in-tree Linux WireGuard module handles public packets.
- The only userspace WireGuard component is `wireguard-tools v1.0.20260223`,
  compiled from the authenticated source archive vendored in this repository.
- Docker publishes exactly `0.0.0.0:443/udp`; Haggai adds no host-published port.
- Each device receives its own Curve25519 key and 256-bit pre-shared key.
- `PersistentKeepalive = 25` and an MTU of 1280 favor recovery across sleep,
  underground sections, train dead zones, and Wi-Fi/cellular address changes.
- An authenticated device gets the host's existing LAN/Internet reachability
  plus `172.30.77.3:<port>` for Haggai loopback/wildcard listeners and
  `172.30.77.4:<port>` for Haggai eth0/wildcard listeners.
- The container drops to UID/GID 65534 with zero capabilities after creating
  the interface and installing its namespace-local firewall.
- A minimal, read-only helper shares only Haggai's network namespace. It has no
  mount, PID namespace, Docker socket, host namespace, or network listener.
- Nothing writes global host sysctls, nftables rules, routes, service units, or
  files under `/etc`. `scripts/teardown.sh` also removes the namespace-local
  addresses, nftables table, and interface-scoped sysctl.

See [SECURITY.md](SECURITY.md) for exact trust boundaries and limitations.

## Requirements

- A Linux host whose kernel includes WireGuard.
- Docker Engine with the Compose v2 plugin.
- The exact hardened
  [`BigBIueWhale/haggai_computer`](https://github.com/BigBIueWhale/haggai_computer)
  deployment: a running, healthy container named `haggai_computer`, image
  `haggai_computer:1.4.7`, attached only to Docker's legacy `bridge`. This
  dependency is mandatory and is validated; there is no substitute target or
  fallback mode.
- A public IPv4 path to this host. Forward only UDP/443 when using an ordinary
  router. If the host is in a router DMZ, every unrelated non-loopback listener
  must be independently understood and secured.
- An IPv4 DNS name is recommended. This deliberately IPv4-only deployment
  should not publish an AAAA record for that name.

## First deployment

Pass the public DNS name or IPv4 address explicitly during initialization. The
`--endpoint` argument is mandatory: there is no environment-variable, example-
file, or built-in endpoint fallback. It contains no port and no fallback list.

Review the host's complete non-loopback listening surface. The snapshot command
only prints a candidate; it never approves listeners for you:

```sh
./scripts/audit-host.sh --print-candidate
cp config/public-listeners.example.tsv config/public-listeners.tsv
```

Edit `config/public-listeners.tsv` with your preferred editor.

Keep exactly one `this-project` row for `0.0.0.0:443/udp`. Every other row must
be labeled `external:<owning-project-or-service>`. The local inventory is
ignored because it describes a particular machine. This convention follows
the explicit-listener philosophy used by
[BigBIueWhale/personal_server](https://github.com/BigBIueWhale/personal_server):
unknown public listeners are failures; an inventory is attribution, not a
substitute for securing the owning service.

Initialize with the required endpoint argument:

```sh
./scripts/init.sh --endpoint vpn.example.com
```

The command first validates the required Haggai container and refuses to
continue if its image, health, network, mount, or privilege boundary has
drifted. It refuses to overwrite existing server keys. It creates private local
artifacts under `secrets/` and `clients/`, validates the assembled server
configuration in a throw-away network namespace, and never prints key material.
It also stores the validated endpoint in the ignored, mode-`0600` local
`config/endpoint` file for later client creation and public smoke tests.
With no client names after the required endpoint, it creates separate `android`
and `ios` identities. Explicit names may instead follow the endpoint argument.

## Connect Android or iOS

Get the official WireGuard application from
<https://www.wireguard.com/install/>.

On Android, choose **+ → Scan from QR code** and scan
`clients/android.png`. On iPhone or iPad, choose **Add a tunnel → Create from QR
code** and scan `clients/ios.png`. The adjacent `.conf` files are equivalent
imports for mobile or desktop clients.

Do not import one profile into multiple devices. WireGuard securely roams a
peer to its most recently authenticated network endpoint, so two devices using
one identity will displace each other. Create a distinct client instead:

```sh
./scripts/add-client.sh laptop
```

Every client `.conf` and QR image contains a private key and pre-shared key.
Treat either file as a complete access credential.

## Haggai destinations

Every authenticated client profile already routes both fixed destinations
through WireGuard because `AllowedIPs` is `0.0.0.0/0, ::/0`:

```text
172.30.77.3:<port>  ->  haggai_computer 127.0.0.1:<port>
172.30.77.4:<port>  ->  haggai_computer eth0:<port>
```

A process bound to `0.0.0.0` is reachable through either address. The port is
never translated. TCP and UDP are supported from port 1 through 65535; ICMP,
Unix-domain sockets, IPv6 `::1`, and non-IP IPC are not exposed. Literal
`127.0.0.1` on a VPN client still means that client itself, which is why the
fixed `172.30.77.3` address exists.

No software runs inside the Haggai filesystem and no Docker image is nested
inside it. The helper is a sibling container that shares only the existing
network namespace. Deployment does not stop, restart, or recreate Haggai and
does not touch its writable layer or `/home/user` bind mount.

## Operations

```sh
./scripts/status.sh
./scripts/audit-host.sh
./tests/static.sh
./tests/network-policy.sh

./scripts/smoke-test.sh android internal
./scripts/smoke-test.sh android public

./scripts/add-client.sh laptop
./scripts/render-qr.sh laptop
./scripts/revoke-client.sh lost-phone

./scripts/deploy.sh
./scripts/teardown.sh
```

The internal smoke test creates an ephemeral client network namespace and tests
an authenticated tunnel directly through the Docker bridge. It also creates
two short-lived, unprivileged TCP probe processes that share Haggai's network
namespace—one bound only to loopback and one only to eth0—and proves both fixed
destinations through the tunnel. They have no mounts or capabilities and are
removed when the test exits. The public mode uses the configured DNS endpoint
and additionally tests the router's public path when NAT loopback is available.
A public-mode failure from inside the home network is inconclusive on routers
without NAT loopback; test from cellular as well.

`deploy.sh` is the update path for an initialized installation. It validates
Haggai, builds the pinned images, runs the disposable TCP/UDP policy suite,
derives the expected WireGuard public key from the existing ignored
`secrets/server.conf`, and recreates only this Compose project. It then proves
the configuration digest and public key are unchanged and that Haggai kept the
same container ID and start time. Existing clients therefore keep working with
the same server identity.

The deploy script performs one explicit Docker endpoint attachment: it connects
the VPN container to the built-in `bridge` with interface name `haggai0`, no
network alias, and gateway priority `-1`. Compose cannot express this exact
attachment because it always supplies a DNS alias and Docker correctly rejects
aliases on the built-in bridge. The VPN entrypoint waits for and validates this
attachment and refuses to create `wg0` without it; the explicit Engine operation
is therefore mandatory orchestration, not an optional mode or fallback. Docker
persists the endpoint across ordinary container and daemon restarts.

Use `teardown.sh`, not a bare `docker compose down`. Docker can apply the
required `route_localnet` setting to a shared network namespace but does not
restore it automatically when the helper is removed. The helper deliberately
leaves a fail-closed nftables guard in place; `teardown.sh` first stops VPN
traffic, resets that one Haggai-namespace sysctl, deletes the owned networking
state, and then removes the Compose project. Haggai remains running throughout.

`status.sh` displays handshakes and traffic counters without revealing the
server private key. A recent handshake after a phone enables the tunnel proves
authentication; checking the phone's observed public address confirms routing.

To intentionally change the one endpoint, supply the new value as a required
argument. The command updates the ignored local setting, rewrites the exact
single `Endpoint` line, and regenerates every local QR image:

```sh
./scripts/render-client-endpoints.sh --endpoint new-vpn.example.com
```

Already imported devices keep their old endpoint until the profile is edited
or reimported.

Revocation removes a peer from the active server configuration and recreates
the VPN container. For recoverability, its local credential files move to
`revoked/`; delete that archive separately when recovery is no longer wanted.

## Why UDP WireGuard

WireGuard is connectionless and updates a peer's network address only after an
authenticated packet. It therefore handles ordinary mobile address changes
without rebuilding a TCP session or creating TCP-over-TCP failure modes. A
25-second keepalive maintains typical carrier-NAT state, while MTU 1280 avoids
many nested-path fragmentation failures.

UDP/443 is often carried for QUIC, but this service does not impersonate QUIC
or HTTPS. Networks that block all UDP or identify and block WireGuard will stop
the tunnel. Adding a covert transport or TCP fallback would be a different
security design with more code and parsers; this repository intentionally does
not do that.

## Public-repository hygiene

Git ignores all of the following deployment state:

- `config/endpoint` and `config/public-listeners.tsv`;
- every server key and generated server configuration under `secrets/`;
- every client profile and QR image under `clients/`;
- revoked credentials and temporary audit output.

Before publishing, run `./tests/static.sh` and inspect `git status --ignored`.
The test rejects personal endpoint/location strings, mutable image tags,
privileged or host-network containers, and accidental tracking of local state.

The project files are dedicated to the public domain under [LICENSE](LICENSE).
The vendored WireGuard source retains its upstream GPL-2.0 license; see
[THIRD_PARTY.md](THIRD_PARTY.md).
