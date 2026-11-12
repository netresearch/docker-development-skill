<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Fetching Source at a Pinned Commit

A Dockerfile that builds from a git checkout pinned to a commit hash looks
reproducible and looks bound to the repository in its URL. The first is true;
the second is not, on GitHub.

## A commit hash does not prove which repository it belongs to

GitHub keeps the objects of a repository and all of its forks in one network
and serves any of them under the parent's URL. A commit that exists only in
somebody's fork can therefore be fetched by its hash from
`https://github.com/<owner>/<repo>.git`, and the web UI shows it under the
parent with the note that it "does not belong to any branch on this
repository". A pin that fetches `origin <sha>` checks that the bytes are the
ones you named; it does not check that the upstream project ever published
them.

Fetch the named branch of the upstream repository instead, require the pinned
commit to be reachable from it, then check it out and verify the hash:

```dockerfile
ARG REPO=https://github.com/php/php-src.git
ARG BRANCH=PHP-7.4-CVE-2026-109618-109619
ARG COMMIT=<40-character sha>

RUN git init -q . && git remote add origin "$REPO" && \
    git fetch -q --depth 50 origin "refs/heads/${BRANCH}" && \
    git merge-base --is-ancestor "${COMMIT}" FETCH_HEAD && \
    git checkout -q "${COMMIT}" && test "$(git rev-parse HEAD)" = "${COMMIT}" && \
    rm -rf .git
```

Each step carries one guarantee:

- `fetch … refs/heads/${BRANCH}` downloads only what that branch reaches, so a
  commit from a fork never enters the local object store.
- `merge-base --is-ancestor` fails unless the pin is on that branch. For a
  foreign commit the object is not there at all, and git stops with
  `fatal: Not a valid commit name <sha>` and exit 128.
- `test "$(git rev-parse HEAD)" = "${COMMIT}"` catches a pin that is not a
  full hash — an abbreviation or a ref name that `checkout` would still
  resolve.
- `rm -rf .git` keeps the history out of the layer.

Source: an internal PHP 7.4 image build that compiles php-src from the branch
named above. The foreign-commit failure was
reproduced on a local repository with git 2.56.0 (2026-11-12): the pinned
branch commit exits 0, a commit that exists only on another branch exits 128
with the message above.

## Limit: the depth bounds how far the branch may move

`--depth 50` fetches the newest 50 commits of the branch. If the branch later
moves more than 50 commits past the pin, the pin is outside the shallow
history and `merge-base` reports it as not a valid commit — the same message
as a foreign commit. The build fails closed, which is the safe direction.
Raise the depth or move the pin; do not drop the ancestry check to make the
build pass.
