<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Which Roots an Image Trusts

When a certificate authority is compromised, the question "is our image still
exposed?" has two layers, and each needs its own measurement:

1. **The application's own TLS stack.** A Go binary verifies chains in
   `crypto/x509`; a fix there (a new toolchain that rejects specific
   intermediates) protects only that binary.
2. **The system bundle**, `/etc/ssl/certs/ca-certificates.crt`. Everything else
   in the image reads it: `curl`, `wget`, OpenSSL, a shell job that a scheduler
   runs inside the container. A root removed upstream protects these programs
   only once the image carries a `ca-certificates` package that dropped it.

Do not state that the second layer is or is not covered before measuring the
published image. Reasoning from "non-Go programs use the system bundle" alone
gives the wrong answer as soon as the distribution has shipped a new package.

## Measure the published image, not the Dockerfile

```bash
img=ghcr.io/<org>/<app>:<tag>
docker run --rm --entrypoint sh "$img" -c \
  'cat /etc/ssl/certs/ca-certificates.crt; echo ===; cat /lib/apk/db/installed' > ca.txt
```

`/lib/apk/db/installed` is Alpine's package database; the `P:ca-certificates`
record is followed by its `V:` version line. On Debian or Ubuntu, run
`dpkg -s ca-certificates` in the container instead.

Then list the subject of every root, one PEM at a time:

```python
import re, subprocess

bundle = open("ca.txt").read().split("===", 1)[0]
pems = re.findall(
    r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", bundle, re.S
)
print(len(pems), "roots")
for p in pems:
    print(
        subprocess.run(
            ["openssl", "x509", "-noout", "-subject"],
            input=p,
            capture_output=True,
            text=True,
        ).stdout.strip()
    )
```

Look for the affected root by its subject. Check every root the compromised
intermediates chain to, cross-signs included: an intermediate cross-signed by a
second root still validates through that root.

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

- An image rebuilt after the distribution shipped the new package is covered.
- Every image built before that day keeps the old bundle, whatever the base
  image tag says. Rebuild, or tell users of older tags which version first
  carries the new bundle.
- A release note claiming coverage names the package version measured in the
  published image.
