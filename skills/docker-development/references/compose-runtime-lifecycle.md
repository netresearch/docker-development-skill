<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Compose Runtime Lifecycle

Two behaviours that look fine in a compose file and only show up when the stack
is redeployed, or when a remote log endpoint stalls. Neither raises an error.

## A disabled profile's container is invisible to `down`

`profiles:` decides what `up` starts. It also decides what `down` stops — and
that is the trap. Turning a profile **off** for a service that is already
running does not stop it: `down` acts only on the profiles enabled for that
command, and `up --remove-orphans` does not treat a service in a disabled
profile as an orphan, because the service is still defined.

Measured with Docker Compose 5.5.1, two services, `side` in profile
`s3-sidecar`:

| Sequence | `side` afterwards |
|---|---|
| `up` with the profile, then `down` without it | **still running** |
| then `up --remove-orphans` without it | **still running** |
| `down --profile '*'`, then `up` without the profile | removed |
| `down` and `up` with the profile again (rollback) | running again |

So a service you meant to retire keeps running forever: never updated, still
holding its published ports, and invisible to anything that only inspects
what the current compose config starts.

Fix: name every profile on `down` — `docker compose --profile '*' down` — or
at least the profile you are turning off, then `up` with only the profiles you
want. A container that `down` removes (rather than leaves stopped) also keeps
"compose-managed and not running" monitors quiet.

To check the behaviour on a host's own Compose version, use a throwaway project
(`COMPOSE_PROJECT_NAME=proftest`, `entrypoint: ["sleep", "600"]` on an image
already present) and `docker ps -a --filter label=com.docker.compose.project=proftest`.

## Logging drivers block by default

Docker's default log delivery mode is **blocking**: a container's write to
stdout/stderr waits until the logging driver accepts it. With a remote driver
(`awslogs`, `gcplogs`, `splunk`, `fluentd`) a stalled endpoint — a dead NAT, a
regional outage — therefore stalls the application's next log line, and with
it the request being served.

`mode: non-blocking` puts a ring buffer in front of the driver; lines past
`max-buffer-size` (default `1m`) are **dropped** instead:

```yaml
    logging:
      driver: awslogs
      options:
        awslogs-group: my-service
        mode: non-blocking
        max-buffer-size: "4m"
```

What it does and does not protect:

- **A running container** keeps serving through the stall and loses log lines,
  not requests.
- **Stop and restart** are not protected. Closing the logger drains the buffer
  synchronously into the driver, so `docker stop`, `compose down` or a restart
  during the stall can wait on the endpoint. Do not deploy into the outage.
- **Startup no longer depends on the endpoint.** In non-blocking mode `awslogs`
  creates its group and stream in the background, so a container starts while
  CloudWatch is unreachable. The flip side: a broken log setup (missing IAM,
  wrong region or group) no longer fails the deploy — verify after a deploy that
  the new container's lines actually arrive.
- Size the buffer from the measured log rate, not a guess: a service writing
  6 KB/min fills 4 MB in hours, one logging every request in minutes.

`docker create --log-driver awslogs --log-opt mode=non-blocking --log-opt max-buffer-size=4m ...`
validates the options against the engine without starting anything (a bad size
fails with `invalid size`).
