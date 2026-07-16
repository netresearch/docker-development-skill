# CI Testing Patterns for Docker Images

Deeper CI/CD gotchas beyond the basics. For entrypoint bypass, DNS mocking,
compose validation, and secret-scan exclusions, see SKILL.md's Quick
Reference § CI Testing Gotchas.

## Pattern 1: Worker/Sidecar Services That Reuse an App Image

A compose service that reuses the app image (e.g. a queue worker on the
php-fpm+nginx web image) **inherits the image's baked-in `HEALTHCHECK`**.
Three traps, in the order they typically bite in CI:

1. **Inherited check probes a daemon the worker doesn't run** (nginx, php-fpm)
   → the worker is permanently `unhealthy` and breaks
   `docker compose up -d --wait` — and anything else gating on health.
2. **`healthcheck: { disable: true }` is not a fix when `--wait` is used** —
   compose fails with `container ... has no healthcheck configured`
   (explicitly listed services without a check are un-waitable).
   Give the worker a real check instead.
3. **A naive `pgrep -f` check is *always* healthy** — the `CMD-SHELL`
   wrapper's own command line contains the search string, so `pgrep`
   matches the probe shell itself, even with a dead worker.

```yaml
services:
  worker:
    image: myapp:latest   # inherits the web image's HEALTHCHECK
    command: php bin/console messenger:consume async
    healthcheck:
      # WRONG: matches the probe's own shell -- healthy forever
      # test: ["CMD-SHELL", "pgrep -f 'messenger:consume' || exit 1"]
      # RIGHT: [c]haracter-class guard prevents self-match
      test: ["CMD-SHELL", "pgrep -f '[m]essenger:consume' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
```

Verify any health probe **both ways**: process up → `healthy` AND process
killed → `unhealthy`. The naive `pgrep` pattern passes the positive test
and hides the bug.

Prefer letting a worker exit on its own limits (`exec` the daemon as PID 1,
restart policy with backoff) over in-container `while true ... || true`
loops that mask fatal errors from orchestration.

## Pattern 2: GitLab CI — image entrypoint must be a shell (or be overridden)

Unlike a test-time `--entrypoint` bypass, GitLab **runs every job's `script:` via `sh -c`**. If the image used as a job `image:` has a non-shell `ENTRYPOINT ["mytool"]`, the runner effectively runs `mytool sh -c '…'` → **`No such command 'sh'`**, and the job fails before the script runs.

```yaml
job:
  image:
    name: registry.example.com/mytool:1.0
    entrypoint: [""]   # let the runner's shell execute the script
  script:
    - mytool --help
```

A CLI image also meant for `docker run mytool …` can keep `ENTRYPOINT ["mytool"]`, but **document** that GitLab consumers must set `entrypoint: [""]`. If the image is *primarily* a CI image, prefer no tool entrypoint (use `CMD`).

## Pattern 3: Restricted runner egress — bundle external assets at build time

CI runners (especially internal/self-hosted) often have **no outbound internet**. An image that fetches something at *runtime* (`page.add_script_tag(url="https://cdn…/axe.min.js")`, `curl https://…` in the entrypoint, a remote `pip`/`npm` install) works locally but fails in CI.

Download the asset at **build time** and load it from the image. Use a multi-stage build so the fetch tooling (`curl`, `ca-certificates`) stays out of the final runtime image:

```dockerfile
# Stage 1: fetch external assets
FROM alpine:3.20 AS asset-builder
RUN apk add --no-cache curl
RUN mkdir -p /opt/axe-core \
 && curl -sSfL https://cdnjs.cloudflare.com/ajax/libs/axe-core/4.9.1/axe.min.js \
      -o /opt/axe-core/axe.min.js

# Stage 2: final image carries only the asset
FROM python:3.12-slim
COPY --from=asset-builder /opt/axe-core/axe.min.js /opt/axe-core/axe.min.js
ENV AXE_PATH=/opt/axe-core/axe.min.js
```

…and have the app prefer the local file (CDN as a dev-only fallback).

## Pattern 4: Test the *built image*, not just the editable dev install

A non-editable install in the image (`pip install .`, `npm install <tarball>`) does not behave like the editable/dev checkout your tests ran against. Classic failure: **data files resolved by walking from `__file__`** (`Path(__file__).resolve().parents[2]/"data"/…`) don't exist under `site-packages`, so the tool can't find its catalog/config inside the container even though `pytest` was green.

- Ship data files as **package data** (Python wheel `force-include`/`package_data`; npm `files`), not via filesystem-relative paths.
- Smoke-test the **built image**, not just the source tree:

```yaml
- run: docker build -t app:test .
- run: docker run --rm --entrypoint python app:test -c "import app; app.load_catalog()"
- run: docker run --rm app:test render fixture.json /tmp/out   # real command, end-to-end
```

## Pattern 5: Bake targets must inherit `docker-metadata-action`

### Problem

When a workflow migrates from `docker/build-push-action` to
`docker/bake-action`, the tags computed by `docker/metadata-action`
(semver from release tags, branch tags, `latest`) are **silently dropped**.
There is no CI error — the registry only ever updates the tags hardcoded in
`docker-bake.hcl`, so release and branch tags go stale or missing.

`docker/metadata-action` writes a generated bake definition exposing a
`docker-metadata-action` target that carries the computed `tags`/`labels`.
A bake target only picks them up if it explicitly inherits that target.

### Solution

Declare a stub `docker-metadata-action` target with local defaults and have
the real target inherit it. In CI, the metadata-action's generated bake file
replaces the stub; locally, the defaults apply.

```hcl
# docker-bake.hcl
target "docker-metadata-action" {
  tags = ["myapp:dev"]   # local default; replaced by metadata-action in CI
}

target "app" {
  inherits  = ["docker-metadata-action"]
  platforms = ["linux/amd64", "linux/arm64"]
  # Do NOT set `tags` here: a target's own attributes override inherited
  # ones, so a local `tags` would discard the CI-computed tags.
}
```

Re-add rolling tags such as `latest`/`production` through the
metadata-action config, not the bake file:

```yaml
- uses: docker/metadata-action@v5
  with:
    images: ghcr.io/org/myapp
    tags: |
      type=raw,value=latest,enable={{is_default_branch}}
```

### Verify Both Paths

```bash
# Local: stub defaults apply
docker buildx bake --print

# CI: simulate the generated metadata file replacing the stub
docker buildx bake -f docker-bake.hcl -f /tmp/metadata-bake.json --print
```

## Pattern 6: On-demand image tags — build on ONE trigger, and bake the version explicitly

A prod-like *variant* image (a profiler build, a debug build) is often published under a content-addressed tag like `:profiling-<sha>` so operators can switch to it on demand. Two traps appear when that image also surfaces its own build provenance (commit, ref, version) on a status page.

**Trap A — the tag race.** If the variant builds on *both* `push: main` and `push: tags`, both runs write the SAME `:profiling-<sha>` tag (same commit → same sha), and last-writer-wins decides which run's baked git-ref survives. A release deploy can then read `ref=main` instead of `ref=v1.2.3`. Fix: build the on-demand variant on ONE trigger that carries the right provenance — tags (plus manual dispatch), not `main`:

```yaml
- name: Build and push profiling image
  # Tag/dispatch only: a main-push build would race the tag build for :profiling-<sha>
  if: startsWith(github.ref, 'refs/tags/') || github.event_name == 'workflow_dispatch'
```

**Trap B — no version in a `.git`-less build.** A Docker build has no `.git`, so anything that derives the version from git or the package's own metadata reads a placeholder — e.g. Composer's `InstalledVersions::getPrettyVersion(<root-package>)` returns `1.0.0+no-version-set`. Bake the version in explicitly: pass a build arg before the dependency install (`COMPOSER_ROOT_VERSION=1.2.3`, or the language's equivalent) so the metadata records it, or have the app read a baked env (`APP_BUILD_REF`) that the Dockerfile declares and the workflow sets from `github.ref_name`:

```dockerfile
ARG APP_BUILD_REF
ENV APP_BUILD_REF=$APP_BUILD_REF
```

With Trap A fixed, that ref is deterministically the release tag.

## Local boot-test pitfalls

When smoke/boot-testing an image by hand (not in the CI matrix):

- **Host-port collisions mislead.** If the published port (`-p HOST:CONTAINER`) is already taken by another container, `docker run -d` leaves the new container unstarted (it stays in `Created` state; the CLI typically exits non-zero, often `125`) while your `curl localhost:HOST` is answered by the *other* container — a false pass, or a baffling failure. Use a free/unique host port, or skip `-p` and probe from inside: `docker exec <c> sh -c 'curl -sf localhost:<port>'`.
- **Foreground apps that log to a file leave `docker logs` empty.** E.g. Tomcat started with `-fg` writes to `logs/catalina.out`, not stdout — an empty `docker logs` does *not* mean "nothing happened". Read the in-container log files (`docker exec <c> sh -c 'tail -n 80 .../catalina.out'`), and check the process and state (`docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' <c>`).
- **Minimal/distroless images have no shell.** `docker exec … sh`/`tail`/`pgrep` won't exist on `scratch`/distroless runtimes — probe with host-side `curl` against a published port, `docker inspect` for state, or a debug sidecar (`docker run --rm --pid container:<c> busybox …`).
- **Grep for real failure signals, not benign noise.** After a bundled-dependency swap, scan logs for `NoSuchMethodError|AbstractMethodError|LinkageError|IncompatibleClassChangeError` (binary incompatibility) — not bare `ClassNotFoundException`, which OSGi/plugin frameworks emit normally.
