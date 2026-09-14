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

Wait for the transition instead — the entrypoint prints it, and it only happens
once:

```bash
ready() {
  docker logs "$1" 2>&1 | grep -q 'Temporary server stopped' &&
  docker logs "$1" 2>&1 | grep -q 'ready for connections'
}
for _ in $(seq 1 60); do ready "$c" && break; sleep 5; done
```

Which server prints it depends on what the container was started against:

| Start | Temporary server? | Guard to use |
|---|---|---|
| empty volume (seeding) | yes, runs `initdb.d` | `Temporary server stopped` **and** `ready for connections` |
| existing data directory, `MARIADB_AUTO_UPGRADE=1` | yes, runs `mariadb-upgrade` | same guard |
| plain restart | no | last `ready for connections` |

The auto-upgrade case is the one that surprises: an existing data directory does
get a temporary server, because that is where `mariadb-upgrade` runs. A plain
restart has none, so the two-condition guard never becomes true there and taking
the *last* log line rather than any line is what distinguishes it:

```bash
docker logs "$c" 2>&1 | tail -5 | grep -q 'ready for connections'
```

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
