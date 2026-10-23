<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Which Roots an Image Trusts

When a certificate authority is compromised, the question "is our image still
exposed?" has two layers, and each needs its own measurement:

1. **The application's own TLS stack.** A Go binary verifies chains in
   `crypto/x509`; a fix there (a new toolchain that rejects specific
   intermediates) protects only that binary.
2. **The system bundle**, `/etc/ssl/certs/ca-certificates.crt`. `curl`,
   `wget`, OpenSSL and a shell job that a scheduler runs inside the container
   read it, and so does Go's `crypto/x509` on Linux when it builds a chain. A
   root removed upstream protects these programs only once the image carries a
   `ca-certificates` package that dropped it.

Do not state that the second layer is or is not covered before measuring the
published image. Reasoning from "non-Go programs use the system bundle" alone
gives the wrong answer as soon as the distribution has shipped a new package.

## Measure the published image, not the Dockerfile

A local tag can point to an older image than the registry serves, because
`docker run` does not refresh it. Pull first and measure the digest:

```bash
docker pull ghcr.io/ORG/APP:TAG
img=$(docker image inspect --format '{{index .RepoDigests 0}}' ghcr.io/ORG/APP:TAG)
```

Copy the files out without running anything in the image. This also works for
distroless images, which have no shell:

```bash
c=$(docker create "$img")
docker cp "$c:/etc/ssl/certs/ca-certificates.crt" bundle.crt
docker cp "$c:/lib/apk/db/installed" apk-installed || true   # Alpine only
docker rm "$c"
```

`/lib/apk/db/installed` is Alpine's package database; the `P:ca-certificates`
record is followed by its `V:` version line. On Debian or Ubuntu, read
`/var/lib/dpkg/status` the same way. An image without a package database has
no version to read: the root list below is then the whole measurement.

List the subject and the SHA-256 fingerprint of every root, one PEM at a time:

```python
import re, subprocess

bundle = open("bundle.crt").read()
pems = re.findall(
    r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", bundle, re.S
)
print(len(pems), "roots")
for p in pems:
    print(
        subprocess.run(
            ["openssl", "x509", "-noout", "-subject", "-fingerprint", "-sha256"],
            input=p,
            capture_output=True,
            text=True,
        ).stdout.strip()
    )
```

Compare fingerprints, not subjects: a reissued root can carry the same subject
as the removed one. Take the affected fingerprints from the advisory or the
CCADB record. Check every root the compromised intermediates chain to,
cross-signs included: an intermediate cross-signed by a second root still
validates through that root.

## `grep` for the CA's name proves nothing

Alpine's bundle is bare concatenated PEM blocks with no label lines. A
`grep -ci <vendor>` over it returns `0` whether the vendor's roots are present
or not, and that `0` reads exactly like "removed". Measured on Alpine 3.24 with
`ca-certificates` 20261020-r0: the grep for `emudhra` returned `0` while
`openssl x509 -subject` listed `emSign Root CA - G1` from eMudhra in the same
bundle.

## The bundle is as old as the build

`apk add --no-cache ca-certificates` without a version installs whatever the
repository held on the day of the build. So:

- An image is covered only if the install layer actually ran after the
  distribution shipped the new package. `--no-cache` on `apk add` does not
  invalidate Docker's cached `RUN` layer, so a rebuild can reuse the old
  bundle. Rebuild with `docker build --pull --no-cache`, or bust the cache in
  CI, then measure the published image again.
- Every image built before that day keeps the old bundle, whatever the base
  image tag says. Rebuild, or tell users of older tags which version first
  carries the new bundle.
- A release note claiming coverage names the package version measured in the
  published image.
