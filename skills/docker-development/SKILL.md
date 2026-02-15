---
name: docker-development
description: "Use when working with Dockerfiles, docker-compose, docker-bake.hcl, or container CI pipelines. Covers image building, testing patterns, and orchestration."
globs:
  - "**/Dockerfile"
  - "**/Dockerfile.*"
  - "**/*.dockerfile"
  - "**/docker-compose.yml"
  - "**/docker-compose.*.yml"
  - "**/compose.yml"
  - "**/compose.*.yml"
  - "**/docker-bake.hcl"
  - "**/.dockerignore"
---

# Docker Development

Production-grade patterns for building, testing, and deploying Docker container images.

## When to Use

- Writing or reviewing Dockerfiles
- Configuring docker-compose.yml / compose.yml
- Setting up docker-bake.hcl for multi-platform builds
- Testing container images in CI/CD pipelines
- Optimizing .dockerignore and build context

## Core Principles

1. **Minimal images** -- Use Alpine/distroless, multi-stage builds
2. **Security first** -- Non-root users, no secrets in layers
3. **Testable** -- Images must be verifiable in CI
4. **Reproducible** -- Pin versions, use checksums

## Quick Reference

### Multi-Stage Build

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:20-alpine
RUN addgroup -g 1001 app && adduser -u 1001 -G app -D app
USER app
COPY --from=builder /app/node_modules ./node_modules
COPY --chown=app:app . .
CMD ["node", "server.js"]
```

### Layer Optimization

```dockerfile
# Good - single layer, cleanup included
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

### Docker Bake (Multi-Platform)

```hcl
target "app" {
  dockerfile = "Dockerfile"
  platforms = ["linux/amd64", "linux/arm64"]
  tags = ["myapp:latest"]
  cache-from = ["type=gha"]
  cache-to = ["type=gha,mode=max"]
}
```

## CI Testing Gotchas

These patterns prevent common failures:

1. **Bypass entrypoint for testing** -- Use `--entrypoint` to run commands directly:
   ```bash
   docker run --rm --entrypoint php myimage -v
   ```

2. **Mock DNS for upstream servers** -- nginx/haproxy configs fail without resolution:
   ```bash
   docker run --rm --add-host backend:127.0.0.1 nginx-image nginx -t
   ```

3. **Compose validation with required vars** -- Create `.env` from `.env.example` before `docker compose config`.

4. **Secret scanning exclusions** -- Exclude `.env.example`, README, and docs from secret scanners.

See `references/ci-testing.md` for comprehensive CI testing patterns.

## .dockerignore Best Practices

A well-configured `.dockerignore` reduces build context size, speeds up builds, and prevents secrets from leaking into images.

### Key Patterns to Exclude

```
# Version control
.git
.gitignore

# Dependencies (rebuilt in container)
node_modules
vendor

# Build artifacts
dist
build
*.o
*.pyc
__pycache__

# IDE and editor files
.vscode
.idea
*.swp

# CI/CD and config
.github
.gitlab-ci.yml
docker-compose*.yml
Makefile

# Documentation
*.md
LICENSE
docs

# Secrets and environment
.env
.env.*
*.pem
*.key
credentials.json
```

### Rules

1. **Always exclude `.git`** -- it can be 10x+ the source size and leaks history
2. **Exclude dependency dirs** (`node_modules`, `vendor`) -- they get rebuilt via `RUN npm ci` / `RUN composer install`
3. **Exclude secrets** (`.env`, `*.pem`, `*.key`) -- even if a later stage drops them, they persist in layer history
4. **Keep it in sync** -- when adding new top-level dirs, check if `.dockerignore` needs updating

## Compose Essentials

- Use `depends_on` with `condition: service_healthy` for startup ordering
- Set `start_period` in healthchecks for slow-starting services
- Use `internal: true` networks for database isolation
- Use `profiles` for optional services (dev tools, debug tools)

## References

- `references/ci-testing.md` -- Comprehensive CI testing patterns for Docker images
