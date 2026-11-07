<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# nginx FastCGI keepalive starves php-fpm

A php-fpm child stays bound to its FastCGI connection for as long as that
connection lives. An nginx keepalive pool to php-fpm therefore does not park
idle sockets — it parks **workers**. Size the pool at or above
`pm.max_children` and it can pin every child, leaving arriving requests to wait
for one to come free.

```nginx
upstream php-fpm {
    server 127.0.0.1:9000;
    keepalive 16;          # against pm.max_children = 10
}
location ~ \.php$ {
    fastcgi_keep_conn on;  # <- makes the pool real
}
```

## The signature — all of it at once, or it is something else

- container at **0 % CPU**, memory flat — nothing is working
- php-fpm **slowlog empty** at a low threshold
  (`request_slowlog_timeout = 5s`): the scripts were never slow, they never got
  a worker
- the stalled requests answer **HTTP 200 after ~60 s**, with TTFB equal to the
  total, and the edge proxy's access log reports the same duration, so the wait
  is behind it
- the very same URLs replayed **one at a time** in the same session take
  ~100 ms

The empty slowlog is the decisive one: it separates "slow code" from "never
scheduled", and it is the measurement most likely to be skipped.

## Why it hides from local testing

Only a client that can issue everything at once builds the queue. Over HTTP/2
through a reverse proxy the page's requests share one connection and arrive
together; a direct HTTP/1.1 client opens at most six connections per origin and
never triggers it. Reproduce **with the proxy in the path** — a stack tested by
addressing the application container directly measures a load shape that
production never sees.

## Measured

TYPO3 backend behind Caddy, `pm.max_children = 10`, opening the backend shell:

| nginx | slowest request | over 5 s |
|---|---|---|
| `keepalive 16` + `fastcgi_keep_conn on` | 61005 ms | 5–8 of 24 |
| `keepalive 8` + `fastcgi_keep_conn on` | 19614 ms | 1 of 24 |
| no pool, `fastcgi_keep_conn off` | **107 ms** | none |

The intermediate value still costs 19.6 s, so this is not a tuning question:
remove the pool. `fastcgi_keep_conn off` is the nginx default, and connection
setup to `127.0.0.1` is not worth holding a worker for.

Raising `pm.max_children` instead trades memory for the same failure one load
step further out — and where the container has a memory cap, the headroom for
`keepalive`-many concurrently pinned children is not there to give.

## A long PHP error turns into 502 for every client

A second nginx/php-fpm failure that a single bad request spreads to everyone.

### The signature

In the nginx error log, in this order:

```text
FastCGI sent in stderr: "PHP message: ..."
upstream sent too big header while reading response header from upstream
upstream server temporarily disabled while reading response header from upstream
no live upstreams while connecting to upstream
```

The first client gets a 502. Afterwards **every** client gets 502 for about
10 s, healthchecks included, and each new request from the first client starts
the cycle again.

### Why

With `catch_workers_output = yes` (the usual container setting) PHP writes its
error log to stderr, and FastCGI delivers that stderr in the same records as
the response headers. A stack trace of a few KB plus the headers overflows
`fastcgi_buffer_size`, whose default is one memory page (4k or 8k). nginx then
counts the request as a failure of the upstream server.

The default `max_fails=1 fail_timeout=10s` disables that server. A compose
service name resolves to every address of the container — with IPv6 enabled on
the network that is one IPv4 and one IPv6 address — and both get disabled in
turn. With no address left, nginx answers `no live upstreams` without trying
php-fpm at all.

Seen with Nextcloud: revoking a session whose browser still holds remember-me
cookies makes Nextcloud log `Could not find the session token to renew` with
its trace, about 3.8 KB.

### Fix

```nginx
upstream php-handler {
    # One backend container: never take it out of rotation for a bad request.
    server app:9000 max_fails=0;
}
server {
    fastcgi_buffer_size 32k;   # stderr and headers share this buffer
}
```

`fastcgi_buffer_size` removes the trigger; `max_fails=0` removes the spread.
With a single backend there is nothing to fail over to, so disabling it only
turns one failed request into an outage.

### Reproduce

Make the logged message long — the request URL and the user agent are part of
the log entry — and trigger an error that PHP logs. Then send unrelated
requests from a second client:

```bash
ua="Mozilla/5.0 $(printf 'p%.0s' $(seq 1 1000))"
curl -sk -A "$ua" -o /dev/null -w '%{http_code}\n' https://app.example/failing-path
for i in $(seq 1 10); do curl -sk -o /dev/null -w '%{http_code} ' https://app.example/status.php; done
```

Before the fix the first call returns 502 and the error log shows
`too big header`. The spread to other clients needs the service to resolve to
more than one address; a single-address dev stack shows only the first 502.
