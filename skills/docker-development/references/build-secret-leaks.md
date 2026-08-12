# Where a build credential actually leaks

`docker history` is the check everyone runs, and for a multi-stage build it is
the wrong one. A credential passed as `ARG` into a builder stage never reaches
the shipped layers — that stage is not in the final image — so the history is
clean while the credential is public anyway.

buildx attaches an SLSA provenance attestation to every pushed image and records
the build arguments in it **verbatim**:

```bash
docker buildx imagetools inspect <ref> --format '{{json .Provenance}}' \
  | jq -r '.[].SLSA.buildDefinition.externalParameters.request.args | keys[]'
# build-arg:COMPOSER_AUTH   <- the value sits right there, in cleartext
```

Measured case (2026-08-12): a public GHCR package carried a working GitLab
`glpat-` token in the attestation of **1461** published versions. The `ARG` was
in a `composer-builder` stage that is never shipped.

## Verify it, with a check that can fail

Grep for the **credential pattern**, never for the argument name. The
attestation embeds the push's commit messages and the `RUN` command lines, so
the name matches your own commit text and reports a leak that is not there —
that false positive cost a round of "still broken" in the session that found
this.

```bash
for ref in "$OLD_TAG" "$NEW_TAG"; do
  n=$(docker buildx imagetools inspect "$ref" --format '{{json .Provenance}}' \
      | grep -oE 'glpat-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}' | sort -u | wc -l)
  echo "$ref: $n credential values"
done
```

A pre-fix tag returning `1` and a post-fix tag returning `0` is the proof. A
single post-fix `0` on its own proves nothing about the check.

## The fix

```dockerfile
RUN --mount=type=secret,id=composer_auth \
    COMPOSER_AUTH="$(cat /run/secrets/composer_auth 2>/dev/null || true)" \
    composer install --no-dev
```

```hcl
target "app" {
  secret = ["type=env,id=composer_auth,env=COMPOSER_AUTH"]
}
```

`type=env` reads the variable the CI already exports, so the calling workflow
usually needs no change at all. Tolerate a missing secret (`|| true`): forks and
local builds have no credential and should still resolve public dependencies
rather than fail.

## After a leak

Rotation is the only remedy that acts on what is already published — the
attestations of existing versions keep their copy of the value forever, or until
someone deletes those package versions. Rotate first, fix the build second.
