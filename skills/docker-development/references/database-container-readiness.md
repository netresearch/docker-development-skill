<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Database Container Readiness

A seeded database image logs `ready for connections` **twice**, and the first
one is a lie you can query. Everything below is about not measuring the
container while it is still initialising — the failure mode is not an error, it
is a plausible number.

## `ready for connections` fires for the temporary server first

The official MySQL and MariaDB entrypoints initialise a new data directory in
three steps: start a temporary server bound to the socket only, run everything
in `/docker-entrypoint-initdb.d`, stop it, then start the real server. Both
servers announce themselves with the same line, so a wait loop written as

```bash
until docker logs "$c" 2>&1 | grep -q 'ready for connections'; do sleep 5; done
```

returns while the seed import is still running. What follows is a measurement of
a half-imported database, and it does not look like one:

| What you observe | What it actually is |
|---|---|
| `28` tables where the dump has `52` | import still running |
| `ERROR 1045 Access denied for user 'root'` | root's password is applied at the end of init |
| `ERROR 2002 Can't connect … through socket` | the moment between temporary server stop and real server start |

The third one is the trap: it reads as a broken image, and the container is fine
two seconds later.

Ordering does not rescue this. Two attempts that look right and are not: both
strings anywhere in the log is true in the gap between the servers, and
`sed -n '/Temporary server stopped/,$p` starts at the **first** match and runs
to the end, so with two temporary servers — an auto-upgrade can start several —
the intermediate announcement falls inside the range. Both were measured
failing before this text was written.

The log itself carries the distinction, on the line *after* the announcement:

```
[Note] mariadbd: ready for connections.
Version: '12.3.2-MariaDB'  socket: '/run/mysqld/mysqld.sock'  port: 0      <- temporary server
...
[Note] [Entrypoint]: Temporary server stopped
[Note] mariadbd: ready for connections.
Version: '12.3.2-MariaDB'  socket: '/run/mysqld/mysqld.sock'  port: 3306   <- the real one
```

The temporary server runs with `--skip-networking` and reports `port: 0`. That
is a property of the server, not of the order, so a guard built on it holds for
a seeding start, an auto-upgrade with any number of temporary servers, and a
plain restart alike:

```bash
ready() {
  docker logs "$1" 2>&1 | awk '
    /ready for connections/ { getline v; if (v !~ /port: 0([^0-9]|$)/) ready = 1 }
    END                     { exit ready ? 0 : 1 }
  '
}

for _ in $(seq 1 60); do
  ready "$c" && break
  sleep 5
done
ready "$c" || { echo "container $c not ready after 300s" >&2; exit 1; }
```

The trailing check is not decoration: without it the loop ends on `sleep`, exits
0 after sixty failed attempts, and hands an unready container to whatever runs
next.

Measured against a seeded image, polling once a second: the two-`grep` version
reported ready at tick 6 with the query returning nothing, the `port`-aware one
at tick 6 of its own run with all 49 tables already present.

## `initdb.d` runs only against an empty data directory

The entrypoint executes `/docker-entrypoint-initdb.d` when it initialises a data
directory, and skips it entirely when one is already there. Two consequences,
and the second one gets stated wrongly by anyone who tested only the first:

* a broken or empty seed breaks a **fresh setup** and nothing else;
* an image can look thoroughly broken while every running instance is fine.

```bash
# empty volume: the seed runs, and a 0-byte .sql.gz kills the container
docker run --rm -e MARIADB_ROOT_PASSWORD=x "$img"
# ... unexpected end of file  -> exit 1
```

For the other half the volume has to be **initialised first** — naming a volume
that does not exist yet creates an empty one, which is the fresh case again and
reproduces the same failure:

```bash
docker volume create pre >/dev/null
docker run -d --name init -v pre:/var/lib/mysql -e MARIADB_ROOT_PASSWORD=x <base-image>
# wait for readiness, write a marker, then stop it
docker exec init mariadb -uroot -px -h 127.0.0.1 -e 'create table test.marker(id int)'
docker stop init

docker run -d -v pre:/var/lib/mysql -e MARIADB_ROOT_PASSWORD=x -e MARIADB_AUTO_UPGRADE=1 "$img"
# ... ready for connections, marker still there, no initdb.d line in the log
```

Before reporting an image as broken, ask which of the two the deployment does.
A compose file that mounts a persistent directory (`./data:/var/lib/mysql`) is
the second case, and a statement about "the published image" that was measured
in the first case is about a path production never takes.

## The client binary differs per image

The examples below call `mariadb`. The official MySQL image ships `mysql`
instead. The MariaDB image has carried `mariadb` as the primary name since
10.5, but the `mysql*` names are gone from 11.0 on. Measured 2026-11:

| Image | `mysql` | `mysqladmin` | `mariadb`, `mariadb-admin` | `healthcheck.sh` |
|---|---|---|---|---|
| `mariadb:10.6` | yes | yes | yes | yes |
| `mariadb:11.8` | **no** | **no** | yes | yes |

Substitute per image rather than copying:

```bash
client=mariadb   # MySQL image: client=mysql
```

A compose healthcheck written for 10.x — `mysqladmin ping` — therefore fails on
every probe after a bump to 11.x, the service never turns healthy, and every
service with `depends_on: condition: service_healthy` on it never starts. Check
which binaries the target image has before the bump:

```bash
docker run --rm --entrypoint sh mariadb:11.8 -c \
  'for b in mysql mysqladmin mariadb mariadb-admin healthcheck.sh; do command -v $b >/dev/null && echo "$b yes" || echo "$b no"; done'
```

## Upgrading an existing data directory across a major version

Three settings and one manual stop decide whether a bump such as 10.6 → 11.8 on
a persistent data directory comes up healthy:

```yaml
database:
  image: mariadb:11.8
  stop_grace_period: 120s
  healthcheck:
    test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
  environment:
    MARIADB_AUTO_UPGRADE: "1"
```

* **`healthcheck.sh`** ships in the image and needs no password on the command
  line. It authenticates as a `healthcheck` user, using credentials in
  `.my-healthcheck.cnf` in the data directory. The entrypoint creates both on a
  fresh initialisation, or on an existing directory when `MARIADB_AUTO_UPGRADE`
  is set. A directory initialised by an image that did not create them has
  neither, and without that variable the probe fails although the server is up.
  Check with `select user, host from mysql.user` before blaming the server.
* **`MARIADB_AUTO_UPGRADE=1`** runs `mariadb-upgrade` on start (the log shows
  `MariaDB upgrade information missing, assuming required`). Its backup covers
  only the `mysql` schema: dump the application data yourself first. An
  upgraded directory cannot be started by the old version again, so a copy of
  the stopped directory is the only exact rollback.
* **The manual stop**: the redo log format changed in 10.8, and newer servers
  refuse a pre-10.8 directory that was not shut down cleanly. Docker's default
  of 10 s before `SIGKILL` is not enough on a busy server, and adding
  `stop_grace_period` to the compose file does not help the container already
  running. Measured with Compose 5.7.0: recreating a container that was started
  without the value took 11 s with 25 s in the new file, the next recreate 26 s.
  So stop the old container with `docker stop -t 120` and confirm
  `Shutdown complete` in its log before starting the new image.
* **`stop_grace_period`** covers every stop after that, reboots included.

After the start, check `select version()`, the table count of the application
schema and `select user, host from mysql.user` — the `healthcheck` rows must be
there.

## Prefer TCP over the socket for one-shot checks

`docker exec … mariadb -uroot -p…` connects over the unix socket by default and
inherits whatever state the socket is in mid-restart. `-h 127.0.0.1` goes
through the listener, which only exists once the real server is up, so a
connection either works or fails honestly instead of racing:

```bash
docker exec "$c" mariadb -uroot -p"$pw" -h 127.0.0.1 -e 'select @@version'
```

## Count the artefact, not the log

A green `docker build` and a started container prove neither that the seed was
imported nor which schema it landed in. Ask the database:

```bash
docker exec "$c" mariadb -uroot -p"$pw" -h 127.0.0.1 -e \
  "select table_schema, count(*) from information_schema.tables group by table_schema;"
```

A seed that names its own database is a common reason for "the dump imported but
my application sees nothing": `MYSQL_DATABASE` creates one schema and the dump
writes another.
