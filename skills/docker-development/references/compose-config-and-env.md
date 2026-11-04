<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Compose Files and Environment Values

Two ways a Compose project looks one way on disk and runs another. Neither
raises an error.

## `COMPOSE_FILE` switches off `compose.override.yml`

Without a file list, Compose loads `compose.yml` and merges
`compose.override.yml` beside it automatically. Once `COMPOSE_FILE` is set —
in the shell or as a line in the project's `.env` — Compose loads **exactly**
that list and no longer looks for the override. The override file still sits
next to `compose.yml` and looks active, but nothing in it is applied.

The symptom is whatever the override was supposed to add: a missing Traefik
label or network gives a `404` from the proxy while every container is
`Up (healthy)`; a missing port, volume or environment entry looks like a
broken image.

Measured with Docker Compose 5.6.0, an override that adds one environment
variable:

| `.env` | override applied |
|---|---|
| no `COMPOSE_FILE` | yes |
| `COMPOSE_FILE=compose.yml` | **no** |
| `COMPOSE_FILE=compose.yml:compose.override.yml` | yes |

The list separator is `:` on Linux and macOS and `;` on Windows;
`COMPOSE_PATH_SEPARATOR` overrides it.

When an override "is not taking effect", check the pin first, then list the
override explicitly:

```bash
grep -n '^COMPOSE_FILE' .env; echo "${COMPOSE_FILE-<unset in shell>}"
# COMPOSE_FILE=compose.yml:examples/compose.extra.yml:compose.override.yml
docker compose config | grep -n -A3 '<what the override adds>'
```

## `docker compose config` re-escapes `$` — it is not what the container receives

`docker compose config` prints a document that must round-trip as Compose
input, so a literal `$` in a resolved value is written back as `$$`. Reading
that output as the value the container gets makes a correct value look
corrupted.

Measured with Docker Compose 5.6.0 (and earlier with 5.3.1), `.env` value
passed through `environment: MY_VAR: ${MY_VAR:-}`:

| `.env` line | `compose config` shows | container receives |
|---|---|---|
| `MY_VAR=abc$HOME-def` | `abc/home/you-def` | `abc/home/you-def` |
| `MY_VAR=abc$$HOME-def` | `abc$$HOME-def` | `abc$HOME-def` |
| `MY_VAR=sk-a$$b-c$$d` | `sk-a$$b-c$$d` | `sk-a$b-c$d` |

So Compose does interpolate `.env` values, and `$$` is the escape for a
literal `$` there, as it is in `compose.yml`. A single-quoted value
(`MY_VAR='sk-a$b'`) is taken literally and needs no escape. A guard built on the
`compose config` reading — "`.env` cannot carry a `$`" — would reject valid
secrets.

Measure the value where it is consumed, inside a container:

```yaml
services:
  probe:
    image: busybox
    command: ["sh", "-c", "printenv MY_VAR | cat -A"]
    environment:
      MY_VAR: ${MY_VAR:-}
```

`docker compose run --rm probe` prints the value; `cat -A` makes trailing
whitespace and line ends visible (`$` marks the end of the line). The value
lands in the terminal and in any CI log or session transcript; for a real
credential, compare `printenv MY_VAR | sha256sum` against the hash of the
expected value instead.
