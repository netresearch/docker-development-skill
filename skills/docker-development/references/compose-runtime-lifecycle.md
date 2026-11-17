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

## Swapping the image can keep the anonymous volume

Recreating a container keeps its anonymous volumes: Compose reattaches the
previous container's anonymous volume at a path to its replacement, also when
only the `image:` changed. It does so only for a path where the new container
declares a volume, either through `VOLUME` in the new image or through an
anonymous entry such as `volumes: [/data]` in the compose file.

Whether an image declares `VOLUME` differs between tags. `mariadb` declares
`/var/lib/mysql`. `redis:7` and `redis:8.0` declare `/data`; `redis:8` and
`valkey/valkey:9` declare nothing. Check before the swap:
`docker image inspect <image> --format '{{json .Config.Volumes}}'`.

Measured with Compose 5.7.1, `redis:8.0` with a saved key, then the same
service switched to `valkey/valkey:9`:

| compose file for the new image | `/data` in the Valkey container |
|---|---|
| no `volumes:` | no mount; Valkey starts empty |
| `volumes: [/data]` | the old volume; Valkey exits with `Can't handle RDB format version 12` |

So the swap breaks when the new container declares a volume at the old path:
it gets data in a format it cannot read, it does not start, and everything
that waits for it with `depends_on: condition: service_healthy` stays down.
The same applies to any engine swap that changes the on-disk format.

First decide what the old volume holds. All of the following discard it, which
is fine for a cache; PHP sessions stored there go with it, so every user logs in
again. A store with durable records or queue data needs a verified backup and an
engine-specific migration first.

Give the new engine a fresh volume, any of:

- rename the service (`redis` → `valkey`): a new service gets new anonymous
  volumes. Update everything that uses the old name, `depends_on` entries and
  clients such as `REDIS_HOST: valkey`, or give the service a `redis` network
  alias. Remove the old container with `--remove-orphans`, or with
  `docker rm -fv <old-container>` to delete its anonymous volume as well;
- keep the name and run `docker compose up -d -V --no-deps <service>` for that
  deploy. Name the service: a bare `-V` renews the anonymous volumes of every
  service it recreates, and a database without a mounted data directory would
  start empty;
- mount a named volume or bind mount and empty it deliberately.

## Healthcheck probes inside minimal images

A healthcheck runs inside the container, with that image's tools. Two traps
after moving a service to Alpine:

- **No `curl`.** Bare `alpine` and many images built on it carry only busybox
  `wget`, whereas `nginx:alpine` and `php:8.4-fpm-alpine` do ship `curl`.
  Check the image with `docker run --rm --entrypoint sh <image> -c 'command -v curl'`.
  Where it is missing, a probe `["CMD", "curl", ...]` fails with
  `executable file not found`, the container stays `unhealthy`, and a reverse
  proxy that skips unhealthy containers (the Traefik Docker provider does)
  removes its route.
- **`localhost` is IPv6 first.** busybox `wget http://localhost/` tries `::1`
  first and reports `Connection refused` when the server listens on IPv4 only
  (`listen 80;` in nginx). Probe the address the server listens on, `127.0.0.1`
  for an IPv4 listener.

```yaml
healthcheck:
  # Nextcloud's status.php runs through the FastCGI location, so the probe covers nginx and php-fpm.
  test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/status.php"]
```

Use an endpoint your application provides and that nginx passes to PHP. A path
that does not exist answers 404 and marks a working container unhealthy; a file
nginx serves statically stays healthy with php-fpm down. With several nginx
server blocks the probe reaches the default one, so select the application's
with `--header "Host: app.example"`.

Read the probe's own output before changing the service:
`docker inspect -f '{{range .State.Health.Log}}{{.ExitCode}} {{.Output}}{{end}}' <container>`.
