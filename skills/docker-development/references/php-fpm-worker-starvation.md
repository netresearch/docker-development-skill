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

A second nginx/php-fpm failure, in which a few bad requests take the upstream
away from everyone.

### The signature

In the nginx error log, in this order:

```text
FastCGI sent in stderr: "PHP message: ..."
upstream sent too big header while reading response header from upstream
upstream server temporarily disabled while reading response header from upstream
no live upstreams while connecting to upstream
```

The client whose request overflows gets a 502. Once every address of the
upstream has been disabled that way, **every** client gets 502 until
`fail_timeout` runs out, healthchecks included. A browser reaches that state on
its own: the page and its `favicon.ico` are two overflowing requests.

### Why

With `fastcgi.logging` on, PHP sends what it logs to nginx as FastCGI STDERR, in
the same records as the response headers. A stack trace of a few KB plus the
headers overflows `fastcgi_buffer_size`, whose default is one memory page (4k or
8k). nginx counts that as a failed attempt on the upstream address it picked.

The official `php:*-fpm` images set `fastcgi.logging = Off` in
`conf.d/docker-fpm.ini`. An image that builds PHP itself gets the default `On`:
check with `php-fpm -i | grep fastcgi.logging`. `catch_workers_output` plays no
part; it concerns the worker's own stderr, and with `no` the 502 stays.

The default `max_fails=1 fail_timeout=10s` then disables that address. A compose
service name resolves to every address of the container, with IPv6 on the
network one IPv4 and one IPv6 address. nginx does not retry an invalid header,
so each overflowing request disables one address. With a single address nginx
ignores `max_fails` and never disables it, so only the overflowing request
fails.

Measured with `php:8.4-fpm-alpine` (`fastcgi.logging=1`) and `nginx:alpine`, a
script logging 9000 bytes, then 10 requests to another script:

| Upstream | Overflowing requests | The 10 other requests |
|---|---|---|
| one address | 1 | all 200 |
| two addresses | 1 | all 200 |
| two addresses | 2 | all 502, `no live upstreams` |
| two addresses, `max_fails=0` | 2 | all 200 |

Seen with Nextcloud on a self-built PHP image: revoking a session whose browser
still holds remember-me cookies makes Nextcloud log `Could not find the session
token to renew` with its trace, about 3.8 KB.

### Fix

```ini
; php.ini: logged errors go to the FPM log, not into the header buffer
fastcgi.logging = Off
```

```nginx
upstream php-handler {
    server app:9000 max_fails=0;  # one container: a bad request must not disable it
}
server {
    fastcgi_buffers 64 4k;        # needed: see below
    fastcgi_buffer_size 32k;
}
```

- **`fastcgi.logging = Off`** removes the trigger. Measured: the same script
  answers 200, and the message appears in the FPM log.
- **`fastcgi_buffer_size`** alone makes `nginx -t` fail with the default
  `fastcgi_buffers`: `"fastcgi_busy_buffers_size" must be less than the size of
  all "fastcgi_buffers" minus one buffer`. Raise both. 32k fits the measured
  messages; size it for your own output, a larger response still overflows.
- **A location wins over the server block.** With 32k on the server and
  `fastcgi_buffer_size 4k` in the PHP location the request still returns 502.
  Check the effective value with `nginx -T | grep fastcgi_buffer`.
- **`max_fails=0`** removes the spread. The trade-off: an address that stays
  unreachable is never disabled either. If the IPv6 address of a dual-stack
  service times out, requests that pick it wait for the connect timeout, so check
  that every address answers before setting it.

### Reproduce

Log a message longer than the buffer, then request it once per upstream address
and send unrelated requests. In Nextcloud the logged entry contains the URL and
the user agent, so a long user agent lengthens it; a plain PHP warning does not.

```php
<?php error_log(str_repeat('x', 9000)); echo 'ok';
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/bad.php
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/bad.php
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8080/ok.php; done
```

With a service on one address only the two `bad.php` calls fail, so the spread
does not show on a stack without IPv6.
