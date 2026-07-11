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
```

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

## License

This project uses split licensing:

- **Code** (scripts, workflows, configs): [MIT](LICENSE-MIT)
- **Content** (skill definitions, documentation, references): [CC-BY-SA-4.0](LICENSE-CC-BY-SA-4.0)

See the individual license files for full terms.
## Author

[Netresearch DTT GmbH](https://www.netresearch.de)
