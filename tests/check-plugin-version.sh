#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# tests/check-plugin-version.sh — behavioural tests for
# Build/Scripts/check-plugin-version.sh and the Build/hooks/pre-push hook
# that runs it.
#
# Each case builds a throwaway git repository with a .claude-plugin/plugin.json
# and an optional tag, runs the check inside it, and compares the exit code.
# Requires bash, git and python3 (the script parses plugin.json with python3).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/Build/Scripts/check-plugin-version.sh"
HOOK="$ROOT/Build/hooks/pre-push"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
count=0

# repo <name> <plugin.json content|-> [tag] — creates a repository with one
# commit. "-" creates no plugin.json at all.
repo() {
    local dir="$WORK/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    if [ "$2" != "-" ]; then
        mkdir -p "$dir/.claude-plugin"
        printf '%s\n' "$2" > "$dir/.claude-plugin/plugin.json"
        git -C "$dir" add .claude-plugin/plugin.json
    fi
    git -C "$dir" -c user.name=test -c user.email=test@example.invalid \
        -c commit.gpgsign=false commit -q --allow-empty -m init
    if [ -n "${3:-}" ]; then
        git -C "$dir" -c tag.gpgsign=false tag "$3"
    fi
}

version() { printf '{"name":"t","version":"%s"}' "$1"; }

expect() { # expect <description> <expected-exit> <repo-name> [command]
    local out rc cmd="${4:-$SCRIPT}"
    count=$((count + 1))
    out=$(cd "$WORK/$3" && bash "$cmd" 2>&1)
    rc=$?
    if [ "$rc" -eq "$2" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1 (expected exit $2, got $rc)"
        printf '%s\n' "$out" | sed 's/^/         /'
        fail=1
    fi
}

echo "check-plugin-version.sh"

repo untagged "$(version 1.2.3)"
expect "no tag at HEAD passes" 0 untagged

repo matching "$(version 1.2.3)" v1.2.3
expect "v-prefixed tag matching plugin.json passes" 0 matching

repo bare "$(version 1.2.3)" 1.2.3
expect "tag without v prefix matching plugin.json passes" 0 bare

repo mismatch "$(version 1.2.3)" v1.2.4
expect "tag not matching plugin.json fails" 1 mismatch

repo nonsemver "$(version 1.2.3)" release-candidate
expect "non-semver tag is ignored" 0 nonsemver

repo emptyversion "$(version '')" v1.2.3
expect "empty version in plugin.json fails" 1 emptyversion

repo noplugin - v1.2.3
expect "missing plugin.json with a semver tag fails" 1 noplugin

echo "pre-push hook"

expect "hook passes when the tag matches" 0 matching "$HOOK"
expect "hook fails when the tag does not match" 1 mismatch "$HOOK"

echo
if [ "$fail" -ne 0 ]; then
    echo "check-plugin-version.sh: FAILED ($count checks)"
    exit 1
fi
echo "check-plugin-version.sh: all $count checks passed"
