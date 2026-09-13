# Engine and Image Upgrades

Two failures that look like an application bug and are not: an engine upgrade
that silently cuts an old sidecar off from the API, and an image upgrade
refused on a compatibility claim nobody measured.

## An engine upgrade raises `MinAPIVersion` and old clients stop seeing anything

Docker Engine declares the oldest client API version it still serves. Engine 29
raised that floor to **1.40**. A container that talks to `/var/run/docker.sock`
and negotiates something older — Traefik 2.8 negotiates 1.24 — is refused, and
the refusal does not look like one: its Docker provider simply enumerates zero
containers. Traefik then serves an empty routing table and every host answers
`404`, with nothing in its own log naming the cause.

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

# probe one API version directly; substitute the version the sidecar pins
curl -s -w '%{http_code}\n' --unix-socket /var/run/docker.sock \
  "http://localhost/v1.24/containers/json"
# {"message":"client version 1.24 is too old. Minimum supported API version is
#  1.40, please upgrade your client to a newer version"}
# 400
```

Measured on Engine 29.7.2, 2026-09-13. The engine is explicit — it is the
client that is not: a `400` on every list call reaches the sidecar's own error
handling, and a provider that treats a failed enumeration as an empty one turns
the message above into "no containers". That is why the symptom carries no
version number.

Symptom-side: a proxy that reports no routers/services while the containers are
up and labelled correctly is an API-version problem until proven otherwise, not
a label problem. `docker logs <proxy>` shows nothing because from its side
nothing failed — the container list was legitimately empty.

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
3. Mount the **production configuration** unchanged. A hand-trimmed copy tests
   a config you are not running.
4. Neutralise every outward side effect first. For anything doing ACME, point
   the CA at the staging directory (`https://acme-staging-v02.api.letsencrypt.org/directory`)
   or the rehearsal burns the real rate limit and may issue certificates you
   then have to revoke. The same applies to a probe that would register with
   service discovery, publish metrics under a live name, or write a shared
   volume: give it its own namespace or a throwaway path.
5. Assert on the **routing outcome**, not on "it started". A container that
   boots and routes nothing looks identical to a healthy one from `ps`. Probe a
   known host and a deliberately unknown one, and require both answers: the
   real host's own status (`401` behind Basic Auth is a pass — the request
   reached the backend), and `404` for the unknown host. Two assertions, because
   a proxy failing open answers the first one correctly.
6. Remove the probe before deploying. It holds ports and a network alias.

```bash
docker run --rm -d --name proxy-probe \
  --network <prod-network> \
  -p 8080:80 -p 8443:443 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /etc/<svc>/config.yml:/etc/<svc>/config.yml:ro \
  <image>:<candidate-tag>

curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: real.example.com'    http://127.0.0.1:8080/
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: nothing.example.com' http://127.0.0.1:8080/
docker rm -f proxy-probe
```

Measured 2026-09-13 upgrading a Traefik 2.x stack: the claim "v3 rejects v2
router labels" was asserted twice and was wrong. A v3.7 probe on the production
network and configuration routed both real hosts to `401` and the unknown host
to `404` on the first run, and the upgrade shipped the same day.
