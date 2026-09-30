<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Docker Development Skill

[![License](https://img.shields.io/badge/License-MIT%20%2B%20CC--BY--SA--4.0-blue.svg)](#license)
[![Claude Code Compatible](https://img.shields.io/badge/Claude%20Code-Compatible-blue)](https://claude.ai/claude-code)

Agent Skill for Docker image development - Dockerfile best practices, CI testing patterns, and Docker Compose orchestration.

## Features

- **Dockerfile Best Practices** - Multi-stage builds, layer optimization, security
- **CI Testing Patterns** - Test Docker images reliably in CI pipelines
- **Docker Compose** - Service orchestration, health checks, networking
- **Docker Bake** - Multi-platform builds with BuildKit
- **Security** - Vulnerability scanning, non-root users, secret management
- **Windows / WSL2** - Run docker through WSL when Docker Desktop uses the WSL2 backend (separate `docker-via-wsl` skill)

## Skills

This package bundles two skills:

- **`docker-development`** — Dockerfile, compose, bake, CI testing, and security patterns.
- **`docker-via-wsl`** — for AI agents running on a Windows host *outside* WSL: re-issue every `docker`/`docker compose` command inside WSL (via `wsl.exe`) so Docker Desktop's WSL2 backend does not corrupt bind-mount paths.

## Automatic Triggers

The `docker-development` skill activates automatically when working with:

| File Pattern | Description |
|--------------|-------------|
| `Dockerfile`, `Dockerfile.*`, `*.dockerfile` | Container image definitions |
| `docker-compose.yml`, `compose.yml` | Multi-container orchestration |
| `docker-bake.hcl` | BuildKit bake configurations |
| `.dockerignore` | Build context optimization |

The `docker-via-wsl` skill activates when an agent on a Windows shell (Git Bash/MSYS/PowerShell, *outside* WSL) is about to run any `docker` command.

## Installation

### Marketplace (Recommended)

Add the [Netresearch marketplace](https://github.com/netresearch/claude-code-marketplace) once, then browse and install skills:

```bash
# Claude Code
/plugin marketplace add netresearch/claude-code-marketplace
/plugin install docker-development@netresearch-claude-code-marketplace
```

### Without a marketplace

Since Claude Code 2.1.157 a plugin directory under your personal skills directory loads on its own:

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/netresearch/docker-development-skill.git \
  ~/.claude/skills/docker-development
```

It loads as `docker-development@skills-dir` on the next session. Update with `git -C ~/.claude/skills/docker-development pull` and start a new session; remove it by deleting the directory. This route has no `claude plugin update`.

### npx ([skills.sh](https://skills.sh))

Install with any [Agent Skills](https://agentskills.io)-compatible agent:

```bash
npx skills add https://github.com/netresearch/docker-development-skill --skill docker-development
npx skills add https://github.com/netresearch/docker-development-skill --skill docker-via-wsl
```

### Download Release

Download the [latest release](https://github.com/netresearch/docker-development-skill/releases/latest) and extract to your agent's skills directory.

### Git Clone

```bash
git clone https://github.com/netresearch/docker-development-skill.git
```

### Composer (PHP Projects)

```bash
composer require netresearch/docker-development-skill
```

Requires [netresearch/composer-agent-skill-plugin](https://github.com/netresearch/composer-agent-skill-plugin).
## Usage

The skill activates automatically when working on:
- Dockerfile development
- Docker Compose configurations
- Docker Bake multi-platform builds
- CI/CD pipelines for container images
- Container troubleshooting

### Example Prompts

- "Create a multi-stage Dockerfile for a Node.js app"
- "Set up GitHub Actions to build and push Docker images"
- "Why is my nginx config test failing in CI?"
- "Add health checks to my docker-compose.yml"
- "Create a docker-bake.hcl for multi-platform builds"

## Key Patterns

### Testing Images with Entrypoints

```bash
# Bypass entrypoint for direct testing
docker run --rm --entrypoint php myimage -v
```

### Testing nginx Configs in Isolation

```bash
# Mock upstream DNS
docker run --rm --add-host backend:127.0.0.1 nginx-image nginx -t
```

### Compose Validation in CI

```bash
# Create .env before validation
cp .env.example .env
sed -i 's/PLACEHOLDER/test_value/g' .env
docker compose config > /dev/null
```

## References

Extended documentation in the skill `references/` directories:

- `docker-development/references/ci-testing.md` - Retro-born CI testing gotchas
- `docker-via-wsl/references/diagnosis-and-fix.md` - Diagnose and fix a wrong bind mount caused by driving Docker from a Windows shell

## Contributing

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

### Tests

The behavioural tests live in `tests/` and need only bash, git and python3:

```bash
bash tests/check-plugin-version.sh  # Build/Scripts/check-plugin-version.sh and Build/hooks/pre-push
```

`tests/check-plugin-version.sh` builds throwaway git repositories and checks that a semver tag at `HEAD` (with or without a `v` prefix) must match the version in `.claude-plugin/plugin.json`, that non-semver tags and untagged commits pass, that an empty version or a missing `plugin.json` fails, and that the pre-push hook passes the result on.

Each check prints `ok` or `FAIL`; a `FAIL` line is followed by the expected and actual exit code and the script's output. The test exits 1 when any check failed. In CI, the Skill Tests workflow (`.github/workflows/tests.yml`) runs every `tests/**/*.sh` on each pull request and on pushes to `main`.

The skills themselves are instructions in Markdown and ship no executable scripts; Skill Validation and Eval Validation check their structure and the eval definitions in `evals/evals.json`. A pull request that adds or changes behaviour in a script adds or updates a check in `tests/` that fails without the change.

## Governance and policies

This repository follows the Netresearch organisation policies:

- [Governance](https://github.com/netresearch/.github/blob/main/GOVERNANCE.md): ownership, roles, how decisions are made and disputes resolved, and continuity.
- [Roadmap](https://github.com/netresearch/.github/blob/main/ROADMAP.md): planned and explicitly excluded work for the coming year.
- [Handling of dependency and code analysis findings](https://github.com/netresearch/.github/blob/main/SECURITY.md#handling-of-dependency-and-code-analysis-findings): thresholds, deadlines and the exception process for dependency (SCA) and static analysis (SAST) findings.
- [Secret management](https://github.com/netresearch/.github/blob/main/SECURITY.md#secret-management): how CI and release credentials are stored, accessed and rotated.
- [Access roster](https://github.com/netresearch/.github/blob/main/docs/access-roster.md): who holds administrative access to this repository and the organisation.

The security assurance case for this skill (threat model, trust boundaries, countermeasures and limits) is in [docs/SECURITY-ASSURANCE.md](docs/SECURITY-ASSURANCE.md).

Checks that run on pull requests in this repository:

- Every pull request: Skill Validation (`lint.yml`: skill structure, markdownlint, yamllint, actionlint, JSON syntax, ShellCheck, ruff, checkpoint schema), Eval Validation (`eval-validate.yml`) and Skill Tests (`tests.yml`).
- Pull requests to `main`: `security.yml` with Betterleaks (secret scanning), zizmor (workflow static analysis), dependency review (fails on vulnerabilities of severity high or above), Composer Audit and Opengrep SAST (`--severity WARNING`: fails on findings of WARNING-level rules only; ERROR-level rules are not reported, see netresearch/typo3-ci-workflows#268); Harness Verification (`harness-verify.yml`) and Template Drift (`check-template-drift.yml`).

## License

This project uses split licensing:

- **Code** (scripts, workflows, configs): [MIT](LICENSE-MIT)
- **Content** (skill definitions, documentation, references): [CC-BY-SA-4.0](LICENSE-CC-BY-SA-4.0)

See the individual license files for full terms.
## Author

[Netresearch DTT GmbH](https://www.netresearch.de)
