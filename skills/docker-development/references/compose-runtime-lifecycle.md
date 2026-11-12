<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Compose Runtime Lifecycle

Three behaviours that look fine in a compose file and only show up when the
stack is redeployed, when a remote log endpoint stalls, or when a second stack
shares the host. None of them raises an error.

## A disabled profile's container is invisible to `down`

`profiles:` decides what `up` starts. It also decides what `down` stops — and
that is the trap. Turning a profile **off** for a service that is already
running does not stop it: `down` acts only on the profiles enabled for that
command, and `up --remove-orphans` does not treat a service in a disabled
profile as an orphan, because the service is still defined.

Measured with Docker Compose 5.5.1 and 5.6.0, two services, `side` in profile
`s3-sidecar`:

| Sequence | `side` afterwards |
|---|---|
| `up` with the profile, then `down` without it | **still running** |
| then `up --remove-orphans` without it | **still running** |
| then `down --remove-orphans` without it | **still running** |
| `--profile s3-sidecar down` | removed |
| `COMPOSE_PROFILES='*' docker compose down` | removed |
| `--profile '*' down`, then `up` without the profile | removed |
| `down` and `up` with the profile again (rollback) | running again |

The table holds when Compose loads the project from the compose file: no `-p`,
or `-p` together with `-f`. `docker compose -p <name> down` without `-f` does
not read the file. It removes every container with that project label,
disabled profiles included.

So a service you meant to retire keeps running forever: never updated, still
holding its published ports, and invisible to anything that only inspects
what the current compose config starts.

Fix, any of:

- name every profile on `down` — `docker compose --profile '*' down` — or at
  least the profile you are turning off, then `up` with only the profiles you
  want;
- remove only that service: `docker compose down side` or
  `docker compose rm -s -f side`. Naming a service enables its profile, and the
  rest of the stack keeps running.

Removing the container, rather than only stopping it, also keeps
"compose-managed and not running" monitors quiet.

To check the behaviour on a host's own Compose version, use a throwaway project
(`COMPOSE_PROJECT_NAME=proftest`, `entrypoint: ["sleep", "600"]` on an image
already present) and `docker ps -a --filter label=com.docker.compose.project=proftest`.
Set the project name through `COMPOSE_PROJECT_NAME`, not `-p` alone, because
`-p` without `-f` removes the disabled-profile container and hides the trap.

## Logging drivers block by default

Docker's default log delivery mode is **blocking**: a container's write to
stdout/stderr waits until the logging driver accepts it. With a remote driver
(`awslogs`, `gcplogs`, `splunk`, `fluentd`) a stalled endpoint — a dead NAT, a
regional outage — therefore stalls the application's writes once the driver's
own queue is full, and with them the request being served. For `awslogs` that
queue holds 4096 events (`awslogs-max-buffered-events`).

`mode: non-blocking` puts a ring buffer in front of the driver; lines past
`max-buffer-size` (default `1m`) are **dropped** instead:

```yaml
services:
  app:
    image: registry.example.com/app:1.4.2
    logging:
      driver: awslogs
      options:
        awslogs-group: my-service
        awslogs-region: eu-central-1
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
  6 KB/min fills 4 MB in hours, one logging every request in minutes. The
  capacity before lines are dropped is the driver's queue plus
  `max-buffer-size`.

`docker create --log-driver awslogs --log-opt mode=non-blocking --log-opt max-buffer-size=4m ...`
checks the option syntax against the engine without starting anything. It
rejects, each with its own message:

- a bad size: `error parsing option max-buffer-size: invalid size: 'abc'`
  (or `invalid suffix: 'x'`);
- a missing group: `must specify a value for log opt 'awslogs-group'`;
- a mode typo: `logger: logging mode not supported: nonblocking`;
- `max-buffer-size` without the mode:
  `logger: max-buffer-size option is only supported with 'mode=non-blocking'`.

It does not contact the endpoint, so it succeeds with a
nonexistent group and without credentials — it is no substitute for checking
that log lines arrive after the deploy.

`mode` and `max-buffer-size` can also be set host-wide under `log-opts` in
`daemon.json`; check it before assuming a container runs in blocking mode.

## A socket-reading scheduler runs every stack's jobs

A scheduler that reads job labels through the Docker socket, such as Ofelia
(`ghcr.io/netresearch/ofelia`), sees every container on the host, not only the
containers of its own Compose project. On a shared host it registers the job
labels of other stacks too. A stack with its own Ofelia then runs its jobs
twice; a stack whose scheduler was deliberately switched off runs them anyway.

Restrict the scheduler to its own project with the label Compose sets on every
container:

```yaml
services:
  ofelia:
    image: ghcr.io/netresearch/ofelia:1.1.0
    command: daemon --docker-filter label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

Ofelia's own documentation recommends `--docker-filter`, or the
`OFELIA_DOCKER_FILTER` environment variable, for this.

Measured with Docker Compose 5.7.0, two throwaway projects on one host, each
with one job label:

| Ofelia `command` | Ofelia | jobs it registers |
|---|---|---|
| `daemon` without `--docker-filter` | 1.0.1 | its own and the other project's |
| `daemon --docker-filter label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}` | 1.0.1, 1.1.0 | its own only (`jobCount=1`) |

`${COMPOSE_PROJECT_NAME}` interpolates to the project's actual name, with `-p`
and without it (then the directory name): `docker compose -p foo config` renders
`label=com.docker.compose.project=foo`. Write the variable in the compose file
itself. A value that only carries it through another variable — for example
`FILTER=label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}` in `.env` —
renders as `label=com.docker.compose.project=` with an empty name. Check the
rendered filter with `docker compose config` before deploying, and compare it
with the project name `docker compose ls` shows for the running stack. Compose
5.7.0 renders the `-p` name even when `.env` sets `COMPOSE_PROJECT_NAME=bar`
(`-p foo` gave `label=com.docker.compose.project=foo`); older releases
interpolated the `.env` value instead
([docker/compose#11734](https://github.com/docker/compose/issues/11734)).

The filter separates projects by name, so two stacks that share a project name
(for example two checkouts in directories of the same name) still see each
other's jobs. Give each stack on a host its own name.

The filter only decides which jobs Ofelia schedules; it is no security
boundary. A container that mounts the Docker socket, `:ro` or not, can call the
whole Docker API, and on a rootful daemon that means control of the host. Run
only a scheduler you trust with that access, or put a restricted Docker API
proxy in front of the socket when the stacks must not reach each other.
