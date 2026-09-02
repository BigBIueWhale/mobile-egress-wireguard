# Mobile egress WireGuard

This project exposes one deliberately small VPN mode: standard WireGuard over
`UDP/443`. A phone or computer can send its Internet traffic through the host's
connection using the official WireGuard client. There is no web UI, control
API, alternate transport, obfuscation layer, or protocol fallback.

The deployment is location-neutral. Its endpoint, keys, device profiles, QR
codes, and host-specific listener inventory are local ignored files, so the
repository can be published without publishing access credentials or tying the
software to one operator, domain, address, or country.

## Design in one minute

- The host's in-tree Linux WireGuard module handles public packets.
- The only userspace WireGuard component is `wireguard-tools v1.0.20260223`,
  compiled from the authenticated source archive vendored in this repository.
- Docker publishes exactly `0.0.0.0:443/udp` from a dedicated bridge namespace.
- Each device receives its own Curve25519 key and 256-bit pre-shared key.
- `PersistentKeepalive = 25` and an MTU of 1280 favor recovery across sleep,
  underground sections, train dead zones, and Wi-Fi/cellular address changes.
- The service has no post-authentication rate limit and no destination
  blocklist. An authenticated device gets the same reachability the host has.
- The container drops to UID/GID 65534 with zero capabilities after creating
  the interface and installing its namespace-local firewall.
- Nothing writes host sysctls, nftables rules, routes, service units, or files
  under `/etc`; removal is `docker compose down` plus deletion of this folder.

See [SECURITY.md](SECURITY.md) for exact trust boundaries and limitations.

## Requirements

- A Linux host whose kernel includes WireGuard.
- Docker Engine with the Compose v2 plugin.
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

The command refuses to overwrite existing server keys. It creates private local
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

## Operations

```sh
./scripts/status.sh
./scripts/audit-host.sh
./tests/static.sh

./scripts/smoke-test.sh android internal
./scripts/smoke-test.sh android public

./scripts/add-client.sh laptop
./scripts/render-qr.sh laptop
./scripts/revoke-client.sh lost-phone

docker compose up --detach --build vpn
docker compose down
```

The internal smoke test creates an ephemeral client network namespace and tests
an authenticated tunnel directly through the Docker bridge. The public mode
uses the configured DNS endpoint and additionally tests the router's public
path when NAT loopback is available. A public-mode failure from inside the home
network is inconclusive on routers without NAT loopback; test from cellular as
well.

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
