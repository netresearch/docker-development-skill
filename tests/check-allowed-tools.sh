#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# tests/check-allowed-tools.sh — the tools each skill pre-approves.
#
# `allowed-tools` in a SKILL.md lets the agent use the listed tools without
# asking the user while the skill is active. Every entry must be one of the
# read-only tools below; any other command follows the user's permission
# settings. Requires bash and python3.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

fail=0
count=0

for skill_md in "$ROOT"/skills/*/SKILL.md; do
    count=$((count + 1))
    rel="${skill_md#"$ROOT"/}"
    if out="$(python3 - "$skill_md" <<'PY'
import re
import sys

READ_ONLY = {
    "Read", "Glob", "Grep",
    "Bash(grep:*)", "Bash(uname:*)",
    "Bash(docker version:*)", "Bash(docker info:*)", "Bash(docker ps:*)",
    "Bash(docker images:*)", "Bash(docker inspect:*)", "Bash(docker history:*)",
    "Bash(docker logs:*)", "Bash(docker compose ps:*)",
}

text = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"---\n(.*?)\n---\n", text, re.S)
if not m:
    print("no front matter")
    sys.exit(1)
# allowed-tools may be a YAML list (indented or not) or a string of tools
# separated by spaces or commas; a tool name may carry a parenthesised
# argument pattern that itself contains spaces.
TOOL = re.compile(r"[A-Za-z_][\w-]*(?:\([^)]*\))?")
entries = []
mode = None  # "list" after a bare key, "block" after a | or > scalar
for line in m.group(1).splitlines():
    key = re.match(r"allowed-tools:(.*)$", line)
    if key:
        inline = key.group(1).strip()
        if re.fullmatch(r"[|>][-+]?[0-9]?", inline):
            mode = "block"
        elif inline:
            found = TOOL.findall(inline)
            if not found:
                print(f"allowed-tools value not understood: {inline}")
                sys.exit(1)
            entries += found
        else:
            mode = "list"
        continue
    if mode == "list":
        item = re.match(r"\s*-\s+(.*?)\s*$", line)
        if item:
            entries.append(item.group(1).strip("\"'"))
            continue
        mode = None
    elif mode == "block":
        if line.startswith((" ", "\t")) or not line.strip():
            entries += TOOL.findall(line)
            continue
        mode = None
other = [e for e in entries if e not in READ_ONLY]
if other:
    print("not read-only: " + ", ".join(other))
    sys.exit(1)
print(f"{len(entries)} entries, all read-only")
PY
)"; then
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
