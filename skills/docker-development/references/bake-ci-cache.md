<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Bake in CI: the Shared Reusable and the GHA Cache

Netresearch repositories build and publish container images with Docker
Bake. A repository defines its images in `docker-bake.hcl` and calls the
shared reusable workflow:

```yaml
jobs:
  publish:
    uses: netresearch/.github/.github/workflows/build-container-bake.yml@main
    with:
      bake-file: docker-bake.hcl
      bake-source: "."
      targets: app,nginx
      push: ${{ github.event_name != 'pull_request' }}
      load: ${{ github.event_name == 'pull_request' }}
      scan: true
      cache: ${{ github.event_name != 'schedule' }}
      pre-build-command: |
        { echo "REF_TAG=..."; echo "GIT_SHA=$GITHUB_SHA"; } >> "$GITHUB_ENV"
```

Use this also for a repository with a single image: one target is a valid
bake file, and the reusable adds scanning, SBOM and signing in the same way
for every repository. `pre-build-command` writes the variables that the HCL
reads (tags, labels) to `$GITHUB_ENV`. The org reusable is called at `@main`,
never pinned to a commit.

## Name the bake file

Without `-f`, `docker buildx bake` reads every default file it finds,
`compose.yml` included. A compose file that needs secrets from `.env` then
fails the build or the `--print` step. Pass `bake-file: docker-bake.hcl` to
the reusable, and `-f docker-bake.hcl` on the command line.

## Declare no cache in the HCL

The reusable adds the GHA cache itself, one scope per target:

```text
<target>.cache-from=type=gha,scope=<target>
<target>.cache-to=type=gha,mode=max,scope=<target>
```

With `cache-scope: foo` the scope becomes `foo-<target>`. Without a scope,
every build writes to the GHA scope `buildkit`, so two targets overwrite each
other's cache and each build restores the wrong layers
([GHA cache backend, scope](https://docs.docker.com/build/cache/backends/gha/#scope)).
Keep `cache-from` and `cache-to` out of the bake file.

## Rebuild without the cache, keep writing it

A scheduled rebuild exists to pick up a rebuilt base image and OS packages
(`apk upgrade`, `apt-get upgrade`). With the layer cache on, those layers are
restored from the previous run and the rebuild publishes the old packages
again. Turn the cache off for the schedule:

```yaml
on:
  schedule:
    - cron: '0 6 * * 1'
...
      cache: ${{ github.event_name != 'schedule' }}
```

With `cache: false` the reusable

- sets an empty `<target>.cache-from=`, which also clears a `cache-from`
  that a bake file declares (check with `docker buildx bake --print`), and
- keeps `cache-to`. Without it the cache keeps the layers from before the
  rebuild, and the next cached push build publishes the old packages again.

A job that calls `docker/bake-action` directly, for example to load a test
image, does the same: `no-cache: ${{ github.event_name == 'schedule' }}` and
`set: <target>.cache-from=type=gha,scope=<target>` to read the scope the
reusable writes.

## Run helper steps where bake-action runs

With a local `source`, `docker/bake-action` runs Bake from that directory.
A step that resolves targets with `docker buildx bake --print` must `cd`
into the same directory first, or a relative bake file the build can read
is not found in the helper step.
