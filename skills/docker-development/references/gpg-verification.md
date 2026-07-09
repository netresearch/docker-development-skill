# GPG Signature Verification in Image Builds

Patterns for verifying downloaded release tarballs against GPG keys inside
multi-stage builds — and the layer pitfall that breaks the naive approach.
Distilled from NRS-4496 (central release-key image for PHP/nginx builds).

## Pitfall: gpg import bakes a stale keybox lock into the layer

With gnupg 2.4, `gpg --import` in one `RUN` starts keyboxd/gpg-agent and leaves
`/root/.gnupg/public-keys.d/*.lock` behind **inside the committed layer**. The
next `RUN` that touches the keyring (e.g. `gpg --verify`) then hangs on the
stale lock and dies:

```text
gpg: Note: database_open ... waiting for lock (held by 9) ...
gpg: keydb_search failed: Operation timed out
gpg: Can't check signature: No public key
```

If you must import, clean up in the **same** `RUN` that imported:

```dockerfile
RUN gpg --no-tty --batch --import /tmp/keys.asc \
 && gpgconf --kill all \
 && rm -f /root/.gnupg/public-keys.d/*.lock
```

## Prefer gpgv: verify without any keyring state

`gpgv` (part of gnupg, also busybox-compatible environments via the gnupg
package) reads **binary** keyring files directly — no import, no `~/.gnupg`,
no agent, no locks, and the accepted signer set is exactly the key files you
pass:

```dockerfile
COPY --from=release-keys /keys/php/8.3/ /tmp/gpg-keys/
RUN set -eux; \
    for k in /tmp/gpg-keys/*.gpg; do \
        [ -s "$k" ] || exit 1; \
        set -- "$@" --keyring "$k"; \
    done; \
    gpgv "$@" php.tar.xz.asc php.tar.xz
```

Convert armored keys once with `gpg --dearmor` (or ship binary exports);
`--keyring` may be repeated per key file.

## Ship keys as a scratch image, not from keyservers

Public keyservers (`keyserver.ubuntu.com`, `keys.openpgp.org`) time out under
parallel CI fan-out and break scheduled builds. Keep reviewed public keys in a
minimal image and consume them via `COPY --from`:

```dockerfile
FROM registry.example.com/support/gpg-keys:latest@sha256:<digest> AS release-keys
```

- Final stage `FROM scratch`: nothing to patch or trust beyond the key files.
- Tag every published digest immutably (e.g. commit SHA alongside `latest`) so
  digest pins never reference an untagged manifest.
- Key *material* belongs to authoritative origins (e.g.
  `php.net/distributions/php-keyring.gpg`, `nginx.org/keys/*.key`), never to a
  keyserver fetch at build time.

Reference implementation: `support/gpg-keys` on git.netresearch.de — including
`verify-release`/`get-verified-release` helper scripts shipped *in* the image
(POSIX sh, executed by the consumer's shell; a `scratch` image runs nothing).
