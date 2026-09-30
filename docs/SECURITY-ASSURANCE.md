<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Security assurance case — docker-development-skill

This document states what a user can expect from this repository in terms of security, and argues why that expectation holds. Every claim names the file that implements it. Reporting a vulnerability: see the [security policy](https://github.com/netresearch/.github/blob/main/SECURITY.md). Components: [ARCHITECTURE.md](ARCHITECTURE.md).

## What the repository ships

| Part | Files | Runs where |
| --- | --- | --- |
| Skill instructions for an AI agent | `skills/docker-development/SKILL.md`, `skills/docker-via-wsl/SKILL.md`, `skills/*/references/*.md` | Read by the agent as instructions; not executed. The agent may run the commands they describe in the user's project. |
| Checkpoints | `skills/docker-development/checkpoints.yaml` | Only when an assessment tool runs its `command` and `script` patterns in a user's project. |
| Repository checks | `Build/Scripts/check-plugin-version.sh`, `Build/hooks/pre-push`, `scripts/verify-harness.sh`, `tests/*.sh` | In this repository's CI and on contributors' machines. Composer, git and release-archive installs contain them too; nothing in this repository runs them on install. |

The skills ship no executable scripts, no container images and no server component. They store nothing and handle no user accounts.

## Security requirements

1. The skill content recommends container practices that do not expose secrets or widen privileges, and marks the corresponding anti-patterns.
2. The checkpoints only read the assessed project; they change no file and start no container.
3. Nothing committed to this repository contains a secret.
4. A release carries the version that `.claude-plugin/plugin.json` states, and its archives can be verified against the build that produced them.

## Actors and trust boundaries

- **Agent and skill user.** The agent reads `SKILL.md` and the references as instructions and applies them to the user's Dockerfiles, compose files and CI configuration, using the user's own Docker installation and privileges. What the agent then runs is decided by the agent and the user, not by this repository.
- **Assessment tool.** A tool that executes `checkpoints.yaml` runs its shell patterns with the privileges of whoever starts it, in the working directory of the assessed project.
- **Contributors.** Changes reach `main` through pull requests, checked by the workflows in `.github/workflows/`.
- **CI.** Workflows run on GitHub-hosted runners with `permissions: {}` at the top level and grant each job only the scopes its called reusable workflow needs (`.github/workflows/*.yml`). The two `pull_request_target` workflows (`auto-merge-deps.yml`, `labeler.yml`) only call reusables that merge or label and do not check out pull request code.

## Threats and countermeasures

| Threat | Countermeasure | Evidence |
| --- | --- | --- |
| A credential ends up in an image layer or build metadata (CWE-798, CWE-532) | The skill marks a secret in `ENV` as an anti-pattern, shows BuildKit `--mount=type=secret` instead, and explains that `ARG` values also appear in `docker history` and SLSA provenance, with a check that can fail and the steps after a leak | `skills/docker-development/SKILL.md` ("BuildKit Secrets", "Security Anti-Patterns"), `references/build-secret-leaks.md` |
| A container runs with more privilege than it needs (CWE-250) | The skill's examples create and switch to a non-root user or use a `nonroot` distroless base; the anti-pattern table names `privileged: true`, `chmod 777` and a host root mount | `SKILL.md` ("Quick Reference", "Security Anti-Patterns") |
| A service is reachable from the network unintentionally | The anti-pattern table replaces a `0.0.0.0` port binding with `127.0.0.1`; the compose section recommends `networks.internal: true` for databases, which checkpoint DC-27 checks | `SKILL.md` ("Security Anti-Patterns", "Compose Essentials"), `checkpoints.yaml` (DC-27) |
| An unverified or drifting base image or download is built into an image (CWE-494) | The skill recommends pinned versions over `:latest`; the references explain verifying release tarballs with `gpgv` and how digest pins behave | `SKILL.md`, `references/gpg-verification.md`, `references/registry-catalogue-and-pin-rot.md`, `checkpoints.yaml` (DC-17) |
| Secret files are sent in the build context | The skill lists `.env*`, `*.pem` and `*.key` for `.dockerignore`; checkpoints DC-14, DC-18 and DC-19 check it | `SKILL.md` (".dockerignore"), `checkpoints.yaml` |
| A checkpoint modifies the assessed project | Every `command` and `script` pattern uses only `find`, `grep`, `awk` and `test` on files in the project and writes nothing | `checkpoints.yaml` (preconditions, DC-19, DC-24 to DC-27) |
| A release is tagged with a version that disagrees with `plugin.json` | The pre-push hook (enabled by `.envrc` through `core.hooksPath`) runs `check-plugin-version.sh`, which fails when a semver tag at `HEAD` differs from `.claude-plugin/plugin.json` | `Build/hooks/pre-push`, `Build/Scripts/check-plugin-version.sh`; `tests/check-plugin-version.sh` |
| A released archive is tampered with | The release workflow publishes a Cosign-signed `SHA256SUMS.txt` and SLSA build-provenance attestations for the archives | `.github/workflows/release.yml` (calls the skill-repo-skill release reusable) |
| A secret is committed | Betterleaks scans every push to `main` and every pull request to `main` | `.github/workflows/security.yml` |
| A vulnerable or malicious dependency is added | Dependency review fails on vulnerabilities of severity high or above in a pull request; Composer Audit checks the Composer dependencies against known advisories; Renovate proposes updates, including pre-commit hook revisions | `.github/workflows/security.yml`, `renovate.json` |
| Insecure code or workflow patterns | Opengrep (`--config auto --error --severity WARNING`) fails on findings of WARNING-level rules only (ERROR-level rules are not reported, netresearch/typo3-ci-workflows#268); zizmor analyses the workflows; ShellCheck runs on every `*.sh` file in Skill Validation | `.github/workflows/security.yml`, `.github/workflows/lint.yml` |
| A failing step continues with partial state | `check-plugin-version.sh` and `verify-harness.sh` run with `set -euo pipefail` | the scripts named |

Which of these checks must pass before a pull request can merge is set in the branch protection of `main`, not in this repository.

## Secure design principles applied

- **Least privilege:** the recommended images run as a non-root user; workflows start from `permissions: {}`.
- **Fail-safe defaults:** the checkpoint preconditions skip the skill in projects without a Dockerfile, compose or bake file, so no findings are reported against unrelated repositories (`checkpoints.yaml`, `preconditions`).
- **Economy of mechanism:** the skills are Markdown; the only scripts are repository checks that need nothing beyond bash, standard Unix tools, git and python3.

## What a user cannot expect

- The skill gives guidance; it does not enforce it. Commands an agent derives from the references run with the user's Docker privileges, and access to the Docker daemon is equivalent to root on the host. Review what an agent proposes to run.
- The code blocks in `SKILL.md` and the references are examples to adapt. Image tags in them are pinned to a version line, not to a digest, and age like any pin.
- The checkpoints run shell commands in the assessed project when an assessment tool executes them; run them only in projects you trust.
- The LLM review checkpoints (DC-20 to DC-23) are judgements by a model and can miss issues.
- Security fixes follow the supported-versions rules of the organisation's security policy; older releases may not receive them.
