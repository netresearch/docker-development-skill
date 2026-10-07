#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# tests/check-allowed-tools.sh — the tools each skill pre-approves.
#
# `allowed-tools` in a SKILL.md lets the agent use the listed tools without
# asking the user while the skill is active. Every entry must be one of the
# read-only tools below; any other command follows the user's permission
# settings. The front matter is read with yq (a YAML parser, preinstalled on
# GitHub-hosted Ubuntu runners), so every YAML form of the value is covered.
# Requires bash, yq (mikefarah, v4) and python3.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v yq >/dev/null 2>&1; then
    echo "FAIL yq is required to read the SKILL.md front matter"
    exit 1
fi

fail=0
count=0

for skill_md in "$ROOT"/skills/*/SKILL.md; do
    count=$((count + 1))
    rel="${skill_md#"$ROOT"/}"
    if ! value="$(yq --front-matter=extract -o=json '.["allowed-tools"]' "$skill_md" 2>&1)"; then
        echo "FAIL $rel: front matter not readable: $value"
        fail=1
        continue
    fi
    if out="$(python3 -c '
import json
import re
import sys

READ_ONLY = {
    "Read", "Glob", "Grep",
    "Bash(grep:*)", "Bash(uname:*)",
    "Bash(docker version:*)", "Bash(docker info:*)", "Bash(docker ps:*)",
    "Bash(docker images:*)", "Bash(docker inspect:*)", "Bash(docker history:*)",
    "Bash(docker logs:*)",
}
# A string value lists tools separated by spaces or commas; a tool may carry a
# parenthesised argument pattern that itself contains spaces.
TOOL = re.compile(r"[A-Za-z_][\w-]*(?:\([^)]*\))?")

value = json.loads(sys.argv[1])
if value is None:
    entries = []
elif isinstance(value, str):
    entries = TOOL.findall(value)
    if value.strip() and not entries:
        print(f"allowed-tools value not understood: {value!r}")
        sys.exit(1)
elif isinstance(value, list) and all(isinstance(e, str) for e in value):
    entries = value
else:
    print(f"allowed-tools has an unexpected shape: {value!r}")
    sys.exit(1)
other = [e for e in entries if e not in READ_ONLY]
if other:
    print("not read-only: " + ", ".join(other))
    sys.exit(1)
print(f"{len(entries)} entries, all read-only")
' "$value")"; then
        echo "ok   $rel ($out)"
    else
        echo "FAIL $rel: $out"
        fail=1
    fi
done

if [[ "$count" -eq 0 ]]; then
    echo "FAIL no skills/*/SKILL.md found"
    fail=1
fi

exit "$fail"
