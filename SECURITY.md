# Security model

## Public protocol surface

This project owns exactly one non-loopback host socket:
`0.0.0.0:443/udp`. It does not publish TCP, IPv6, HTTP, SSH, DNS, metrics, an
administration interface, or a fallback protocol. The public parser and
cryptographic data plane are the WireGuard implementation in the host's
security-updated Linux kernel. Unknown or unauthenticated packets do not create
an authenticated tunnel or receive a useful application response.

UDP/443 is selected for availability on mobile networks that carry QUIC. The
traffic remains ordinary WireGuard and is not disguised as QUIC or HTTPS. A
network that blocks UDP or WireGuard can block this service; there is no silent
downgrade to a larger or weaker protocol.

## Authentication and mobile recovery

Every device has an independent Curve25519 private key and a distinct 256-bit
pre-shared key. The server grants that peer exactly one tunnel source address.
The pre-shared key adds symmetric-key material without replacing WireGuard's
public-key identity.

`PersistentKeepalive = 25` keeps carrier-NAT mappings usable. WireGuard learns a
peer's new address only from authenticated packets after Wi-Fi/cellular
transitions, public-address changes, tunnels, train dead zones, or sleep/wake.
MTU 1280 trades a little peak efficiency for reliable delivery through nested
or unusually constrained mobile paths.

There is no post-authentication rate limit and no destination blocklist. An
enrolled device receives unrestricted IPv4 forwarding, including home-LAN
destinations the host can route to. That is intentional: a compromised enrolled
device is trusted like a device on the home network. Revoke a lost or
compromised identity immediately.

An enrolled device can also reach all IPv4 TCP and UDP ports in the mandatory
[`haggai_computer`](https://github.com/BigBIueWhale/haggai_computer) network
namespace. That includes services which deliberately listen only on Haggai's
`127.0.0.1`. Such services must not treat loopback binding as authentication:
for this deployment, possession of an enrolled WireGuard identity is the
security boundary. There is intentionally no per-port policy or Haggai-disabled
operating mode.

Clients route both `0.0.0.0/0` and `::/0` into the interface, but this server
does not forward IPv6. IPv6 is unavailable instead of leaking around the
tunnel. DNS uses Quad9's IPv4 resolvers and therefore exits through the same
IPv4 tunnel.

There is exactly one endpoint and no ordered fallback list. It is read from the
ignored, one-line `config/endpoint` file after being supplied through the
mandatory `--endpoint` initialization or endpoint-update argument. There is no
built-in or environment-selected endpoint. Endpoint rendering requires an
IPv4 result and rejects an IPv6-only deployment.

## Container boundary

The service container:

- has a read-only root filesystem plus tiny `noexec`, `nosuid`, `nodev` tmpfs
  mounts;
- has no Docker socket, host network namespace, host PID namespace, device,
  module tree, or general host-filesystem mount;
- mounts only the generated server configuration, read-only;
- starts with `NET_ADMIN`, `NET_RAW`, `DAC_READ_SEARCH`, `SETUID`, and `SETGID`,
  after dropping every other capability; `NET_RAW` is needed only because the
  BusyBox `ip` utility opens an `AF_PACKET` socket while setting the fixed
  Haggai-side MAC address;
- applies a default-deny nftables policy inside its isolated namespace, creates
  `wg0`, reads the one configuration, and drops its identity;
- runs steady-state PID 1 as UID/GID 65534 with zero permitted/effective
  capabilities and `no_new_privs=1`;
- has no userspace process accepting network connections after startup; and
- bounds PIDs and rotates Docker logs.

It has two Docker interfaces with fixed names. `outer0` is the original
`172.30.77.2/29` egress path and remains the only default route. `haggai0` joins
Docker's legacy default bridge solely for the Haggai transit path. Namespace
input is default-drop on both; only UDP/443 is accepted on `outer0`, and no
input is accepted on `haggai0`. Forwarding from Haggai toward WireGuard is
limited to conntrack replies bearing this project's mark, so Haggai cannot use
the VPN container to initiate traffic toward enrolled peers.

The startup capabilities are scoped to the container's network namespace. The
kernel WireGuard interface and socket remain there after PID 1 drops every
capability and becomes UID/GID 65534. The host receives ordinary Docker
bridge/NAT state for the declared publication;
the project never edits the host's global nftables policy, routes, sysctls,
Docker daemon configuration, or boot services.

## Haggai namespace helper

The required `mobile-wireguard-haggai-network` companion uses Docker's
`network_mode: container:haggai_computer`. That shares only Haggai's network
namespace. It does not share Haggai's PID, mount, user, IPC, or UTS namespaces;
it mounts no files and has no Docker socket, host path, device, published port,
or listening socket. Its root filesystem is read-only, every capability is
dropped except `NET_ADMIN`, `no_new_privs` is set, and its PID limit is sixteen.
Haggai does not inherit the helper's capability and cannot see or signal its
processes through Haggai's PID namespace.

The helper needs `NET_ADMIN` continuously for two reasons: clean signal-driven
removal of its exact addresses/routes and renewal of a ten-second nftables
authorization lease. Keeping this tiny immutable process privileged inside
Haggai's network namespace is narrower and more fail-safe than giving any
process in the Haggai container that capability. The helper has no network
parser or remotely callable userspace API.

Docker applies `net.ipv4.conf.eth0.route_localnet=1` inside the shared Haggai
network namespace; `all.route_localnet` must remain zero. This is not a host
sysctl and does not affect any other namespace or host interface. Before
authorizing traffic, the helper validates all of the following:

- the namespace contains exactly `lo` and `eth0`;
- `eth0` has exactly one ordinary IPv4 address and the sole default route;
- any stale table, link-local address, or route is marked as this project's
  previously owned state; and
- the hardened Haggai listener is present on exactly `0.0.0.0:21118`.

The helper installs two non-Docker-routed link-local transit addresses. Packets
must have the fixed VPN-side source IP and Ethernet identity and must be covered
by the helper's expiring nftables set. A conntrack mark is set before DNAT and
checked again at input. Unmarked traffic arriving on `eth0` for `127.0.0.0/8`
is dropped, as is direct traffic to either transit address. The two mappings,
with ports preserved, are:

```text
VPN 172.30.77.3 -> transit 169.254.77.2 -> Haggai 127.0.0.1
VPN 172.30.77.4 -> transit 169.254.77.3 -> Haggai's validated eth0 IPv4
```

Wildcard `0.0.0.0` listeners accept either destination. Both mappings accept
only TCP and UDP. They do not expose ICMP, IPv6, Unix sockets, abstract sockets,
or other IPC.

If the helper exits normally, it immediately removes the active lease and
transit addresses/routes. If it is killed without running a trap, the lease
expires within ten seconds and the Haggai input chain checks that lease on every
packet, including established flows. Because Docker does not automatically
restore a sysctl applied to a shared namespace, the fail-closed input guard
remains after ordinary helper removal. `scripts/teardown.sh` stops VPN traffic,
uses a no-mount one-shot container to set only Haggai eth0's `route_localnet`
back to zero, verifies ownership, removes the exact nftables table and transit
state, and then removes this Compose project.

The helper makes no change to Haggai's image, writable container layer, bind
mount, installed software, process tree, or published ports. Haggai is an
external namespace donor, not a service in this Compose project, so deployment
neither recreates nor restarts it.

There is intentionally no Docker health check: a health command would be a new
root process inheriting the container's startup capability set on every probe.
Startup is fail-loud, PID 1 cannot outlive its network namespace, Docker restarts
it after process failure, and `audit-host.sh` performs the explicit privileged
state check only when an administrator requests it.

The separate tools image contains QR and HTTPS clients. It is not part of the
default Compose profile and publishes no ports. Key creation and QR generation
run it with no network and no capabilities. End-to-end smoke testing gives
`NET_ADMIN` only to a short-lived test namespace.

## Namespace firewall

Input to the service namespace is default-deny. It accepts only:

- UDP/443 on the outer interface;
- essential ICMP error messages for path behavior; and
- ICMP echo to the tunnel gateway from authenticated tunnel source addresses.

No TCP or UDP administration service is reachable in the VPN container through
`wg0`. Forwarding is default-deny except authenticated tunnel IPv4 traffic
toward the outer interface, marked TCP/UDP traffic toward the two mandatory
Haggai destinations, and their established/related replies. Internet/LAN
source NAT is limited to `10.77.0.0/24` leaving `outer0`; Haggai traffic is
source-NATed to the single private transit address `169.254.77.1` on `haggai0`.

This is not an Internet/LAN destination policy. Authenticated traffic can still
reach any address Docker and the host route normally; no arbitrary IP denylist
is hidden in the ruleset. The two Haggai aliases are the only special routes.

## Reproducible dependency boundary

The Dockerfile pins:

- the Dockerfile frontend by digest;
- the Alpine multi-architecture image index by digest;
- every APK revision added in the patched base, build, runtime, and tools
  dependency closures; and
- the WireGuard tools source version and SHA-256 digest.

`wireguard-tools v1.0.20260223` is compiled from the vendored upstream release
archive after its digest is checked. The detached upstream signature is
included. It was verified with Jason A. Donenfeld's WKD-published key whose
fingerprint is:

```text
AB99 42E6 D4A4 CFC3 4126 20A7 49FC 7012 A5DE 03AE
```

The build disables `wg-quick`, systemd units, and shell completion and copies
only the stripped `wg` executable into the runtime stage. It does not clone a
repository or execute a network-fetched source tree during the build.

The data plane deliberately follows the host's in-tree kernel rather than
freezing an out-of-tree module. The operator remains responsible for timely
host kernel security updates. Alpine may eventually retire pinned APK revisions
from its ordinary mirror; indefinite rebuilding then requires an archival
mirror, but no version may be silently substituted.

## Secrets

`secrets/`, `clients/`, and `revoked/` are mode 0700 and ignored by Git. Files
inside are mode 0600. A client `.conf` or QR code contains everything required
to impersonate that identity. Do not put those files in a repository, chat,
email, cloud photo backup, or screenshot.

The running service sees only the server configuration. Client private keys
are never mounted in it. Administrative scripts avoid printing private keys;
`wg show` does not reveal the interface private key.

Deleting a local profile does not delete a copy already imported by a device.
Revocation removes its public identity from the server. The script keeps a
recoverable ignored archive rather than destroying credentials implicitly.

## Host listener accountability

On a DMZ host, the absence of a blanket input firewall is acceptable only when
every non-loopback bind is intentional and owned. The ignored
`config/public-listeners.tsv` is an exact local allowlist. `audit-host.sh` fails
if the host gains or loses any TCP/UDP listener, and separately verifies this
project's container name, image identity, publication, mounts, namespace,
capabilities, PID limit, steady-state UID/GID, and WireGuard port.
It also verifies the fixed interface identities, Haggai dependency boundary,
helper isolation/capability set, namespace-local routing state, DNAT/SNAT rules,
and active fail-closed lease.

Rows labeled `external:<owner>` are assertions that another project owns and
secures that listener. This repository does not probe, modify, restart, or
certify those external services. The model mirrors
[BigBIueWhale/personal_server](https://github.com/BigBIueWhale/personal_server):
make public surface explicit and fail on unexplained drift, while keeping each
service's security proof with its owner.

Docker-group membership is root-equivalent. Only trusted administrators may
operate this project.

## Deliberate limitations

- No censorship-resistance or protocol camouflage is claimed.
- No IPv6 egress is provided.
- No multi-server failover or endpoint fallback exists.
- Only the exact `haggai_computer:1.4.7` container contract is accepted. A
  renamed, absent, unhealthy, differently networked, or privilege-drifted
  Haggai container prevents VPN deployment/startup.
- The legacy default bridge is an Ethernet segment, not a cryptographic
  isolation boundary. The source-IP/MAC check prevents ordinary cross-container
  access, but another host-controlled bridge peer with raw-packet privileges
  could spoof it. Enrolled remote access remains cryptographically authenticated
  by WireGuard; Haggai itself gains nothing by spoofing access to its own sockets.
- Availability still depends on the host, router, DNS, public IPv4 address,
  carrier policy, and the mobile OS keeping the tunnel enabled.
- A container is defense in depth, not a boundary against a hostile host kernel
  or root-equivalent Docker operator.
