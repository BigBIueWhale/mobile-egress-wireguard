# Vendored authenticated source

`wireguard-tools-1.0.20260223.tar.xz` is the upstream cgit release archive from:

<https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-1.0.20260223.tar.xz>

The detached signature is the upstream `tar.asc` signature. It signs the
uncompressed tar stream, so verification is:

```sh
xz -dc vendor/wireguard-tools/wireguard-tools-1.0.20260223.tar.xz |
  gpg --verify vendor/wireguard-tools/wireguard-tools-1.0.20260223.tar.xz.asc -
```

The verified signer fingerprint is:

```text
AB99 42E6 D4A4 CFC3 4126 20A7 49FC 7012 A5DE 03AE
```

The build also checks the SHA-256 digest from `CHECKSUMS.sha256` before
extracting the source. The signature was verified through the signer's WKD on
`zx2c4.com` when this project was created.
