# Engine and Image Upgrades

Two failures that look like an application bug and are not: an engine upgrade
that silently cuts an old sidecar off from the API, and an image upgrade
refused on a compatibility claim nobody measured.

## An engine upgrade raises `MinAPIVersion` and old clients stop seeing anything

Docker Engine declares the oldest client API version it still serves, and the
number moves **within a major series, in both directions** — so read it per
release, never per major:

| Release | Minimum API version |
|---|---|
| 28.x | 1.24 |
| 29.0.0 | **1.44** ("The daemon now requires API version `v1.44` or later (Docker v25.0+)") |
| 29.3.0 | lowered again to **1.40** ("Lower minimum API version from v1.44 to v1.40 (Docker 19.03)") |

Both figures are from the [Engine 29 release notes](https://docs.docker.com/engine/release-notes/29/); the second is why a host on a late 29.x reports a *lower* floor than the one that broke it. A container that talks to `/var/run/docker.sock` and negotiates something older than the running floor — Traefik 2.8 negotiates 1.24, below every value in that table — is refused, and the refusal does not look like one: its Docker provider enumerates zero containers, Traefik serves an empty routing table, and every host answers `404`.

The class is wider than Traefik. Anything that reads the socket carries a
pinned client version: reverse proxies, log shippers, autoheal sidecars,
monitoring agents, `docker-gen`, watchtower-style updaters. An engine upgrade is
a breaking change for all of them at once, and each one fails in its own domain
language.

Read the engine's floor first, then send the version each sidecar is known to
negotiate and see whether the engine still answers it:

```bash
# what the engine serves, and the oldest it still accepts
docker version --format '{{.Server.Version}} api={{.Server.APIVersion}} min={{.Server.MinAPIVersion}}'
# 29.7.2 api=1.55 min=1.40

# the LOCAL CLI's negotiated version — not any sidecar's; those pin their own
docker version --format '{{.Client.Version}} api={{.Client.APIVersion}}'

# probe one API version directly; substitute the version the sidecar pins
curl -s -w '%{http_code}\n' --unix-socket /var/run/docker.sock \
  "http://localhost/v1.24/containers/json"
# {"message":"client version 1.24 is too old. Minimum supported API version is
#  1.40, please upgrade your client to a newer version"}
# 400
```

Measured on Engine 29.7.2, 2026-09-13. The engine is explicit; whether anything
*else* is depends on the client. A `400` on every list call reaches the
sidecar's own error handling, and what that handling does is the variable — it
may log the daemon error verbatim, log a generic provider error, retry
silently, or treat a failed enumeration as an empty one.

Symptom-side: a proxy that reports no routers or services while the containers
are up and labelled correctly is an API-version problem until proven otherwise,
not a label problem. Read its log for an API-floor or provider error before
concluding anything from the empty routing table — a failed enumeration and a
genuinely empty container list look identical from outside, and only the log
separates them.

The fix is to upgrade the sidecar, not to pin the engine back. Pinning works
and defers the same break to the next unattended security update.

## Verify an image upgrade with a probe container, never from the changelog

"The new major rejects our configuration" is a claim, and reading release notes
does not settle it — notes describe what changed, not what your configuration
uses. Run the candidate beside the running one and measure. It costs one
container and a few minutes, and it answers the question the notes cannot: does
*this* config, with *these* labels, route *our* hosts.

The shape, for any config-driven service (proxy, gateway, cache, broker):

1. Start the candidate image on the **same network** as the production stack,
   so it sees the same containers and the same labels.
2. Bind **alternate ports** on the host — nothing may contend with the live
   listener.
3. Mount the production configuration with **the routing untouched and the
   outward side effects overridden** — those are the only edits allowed, and
   they are why the probe gets its own copy rather than the live file. A
   hand-trimmed config tests something you are not running; an unmodified one
   acts on the world.
4. What has to be overridden, before the first start: the **ACME CA**, at the
   staging directory (`https://acme-staging-v02.api.letsencrypt.org/directory`),
   or the rehearsal burns the real rate limit and may issue certificates you
   then have to revoke; the **certificate store**, at a throwaway path, so the
   probe cannot write the live `acme.json`; and anything that would **register
   with service discovery, publish metrics under a live name, or write a shared
   volume** — its own namespace, its own metric prefix, its own path. Where the
   service reads these from the environment, pass them as `-e`; where it reads
   only the file, edit the copy and diff it against the original so the routing
   is provably unchanged (`diff prod.yml probe.yml` should show exactly those
   lines).
5. Assert on the **routing outcome**, not on "it started". A container that
   boots and routes nothing looks identical to a healthy one from `ps`. Probe a
   known host and a deliberately unknown one, and require both answers: the
   real host's own status (`401` behind Basic Auth is a pass — the request
   reached the backend), and `404` for the unknown host. Two assertions, because
   a proxy failing open answers the first one correctly.
6. Remove the probe before deploying. It holds ports and a network alias.

```bash
#!/usr/bin/env bash
set -euo pipefail
PROBE=proxy-probe-$$          # unique: a stale name must never be what gets removed
cp /etc/<svc>/config.yml /tmp/probe.yml
# edit ONLY the side-effect lines in the copy, then prove that is all that changed
sed -i 's#https://acme-v02.api.letsencrypt.org/directory#https://acme-staging-v02.api.letsencrypt.org/directory#' /tmp/probe.yml
sed -i 's#/etc/<svc>/acme.json#/tmp/probe-acme.json#'                                                            /tmp/probe.yml
diff /etc/<svc>/config.yml /tmp/probe.yml   # expect exactly those two lines

docker run --rm -d --name "$PROBE" \
  --network <prod-network> \
  -p 8080:80 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /tmp/probe.yml:/etc/<svc>/config.yml:ro \
  <image>:<candidate-tag>
trap 'docker rm -f "$PROBE" >/dev/null 2>&1 || true' EXIT   # armed only now that it exists

code() { curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: $1" http://127.0.0.1:8080/; }
for _ in $(seq 30); do [ "$(code real.example.com)" != 000 ] && break; sleep 1; done

real=$(code real.example.com); unknown=$(code nothing.example.com)
echo "real=$real unknown=$unknown"
[ "$real"    = 401 ] || { echo "FAIL: real host expected 401, got $real";       exit 1; }
[ "$unknown" = 404 ] || { echo "FAIL: unknown host expected 404, got $unknown"; exit 1; }
echo "PASS"
```

Substitute your own expected codes — `401` is this stack's Basic Auth, not a
universal pass. The point is that both are asserted and an unexpected status
fails the script: `curl` exits `0` on any HTTP response, so a bare invocation
whose output nobody compares proves nothing.

The socket is mounted here because socket access is *the thing under test* —
this page exists because a client's API negotiation is what breaks on an engine
upgrade, and substituting an allowlisting API proxy would test the proxy's
compatibility instead of the candidate's. Note what that costs: `:ro` restricts
nothing at the API level, so the candidate can do anything the socket allows for
as long as it runs. That is acceptable only because this image is the artefact
you are about to give the same socket in production; if the candidate is not
trusted that far, do the rehearsal on a disposable host or VM rather than
weakening the test.

Measured 2026-09-13 upgrading a Traefik 2.x stack: the claim "v3 rejects v2
router labels" was asserted twice and was wrong. A v3.7 probe on the production
network and configuration routed both real hosts to `401` and the unknown host
to `404` on the first run, and the upgrade shipped the same day.
