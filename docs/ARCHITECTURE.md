# Architecture — docker-development-skill

## Overview

An AI agent skill for Docker image development. Teaches agents Dockerfile best practices, CI testing patterns, Docker Compose orchestration, and Docker Bake multi-platform builds.

## Components

### Skill Definition (`skills/docker-development/SKILL.md`)

Main entry point loaded by agent frameworks. Contains:
- Core principles (minimal images, security, testability, reproducibility)
- Quick-reference examples for multi-stage builds, layer optimization, Docker Bake
- CI testing gotchas and solutions

### Reference Docs (`skills/docker-development/references/`)

- **ci-testing.md** — comprehensive CI testing patterns for container images
- **dind-testing-patterns.md** — Docker-in-Docker testing strategies

### Checkpoints (`skills/docker-development/checkpoints.yaml`)

Evaluation checkpoints for measuring skill effectiveness.

### Build Infrastructure (`Build/`)

- **Scripts/check-plugin-version.sh** — validates version consistency across metadata files
- **hooks/pre-push** — git pre-push hook for quality checks

### Evals (`evals/`)

Evaluation definitions for testing skill effectiveness with AI agents.

## Design Decisions

- **Documentation-focused**: no runtime Docker images; the repo teaches patterns, not ships containers.
- **Split licensing**: code under MIT, content under CC-BY-SA-4.0.
- **Composer integration**: published as a PHP package for projects using the composer-agent-skill-plugin.
- **Pre-push hooks**: version consistency is enforced via git hooks in `Build/hooks/`.
