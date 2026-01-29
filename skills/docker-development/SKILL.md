---
name: docker-development
description: "Agent Skill: Docker image development patterns - Dockerfile best practices, CI testing, compose orchestration. By Netresearch."
---

# Docker Development Skill

Production-grade patterns for building, testing, and deploying Docker container images.

## When to Use

- Building custom Docker images (Dockerfile development)
- Setting up CI/CD for container image builds
- Testing Docker images in CI pipelines
- Creating Docker Compose stacks for applications
- Troubleshooting container build or runtime issues

## Core Principles

1. **Minimal images** - Use Alpine/distroless, multi-stage builds
2. **Security first** - Non-root users, no secrets in layers
3. **Testable** - Images must be verifiable in CI
4. **Reproducible** - Pin versions, use checksums

## Dockerfile Best Practices

### Multi-Stage Builds

```dockerfile
# Build stage - has build tools
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

# Runtime stage - minimal
FROM node:20-alpine
RUN addgroup -g 1001 app && adduser -u 1001 -G app -D app
USER app
COPY --from=builder /app/node_modules ./node_modules
COPY --chown=app:app . .
CMD ["node", "server.js"]
```

### Layer Optimization

```dockerfile
# Bad - each RUN creates a layer, leaves cache
RUN apt-get update
RUN apt-get install -y curl
RUN apt-get clean

# Good - single layer, cleanup included
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

### Build Arguments vs Environment

```dockerfile
# Build-time only (not in final image)
ARG BUILD_VERSION
RUN echo "Building version ${BUILD_VERSION}"

# Runtime configuration
ENV APP_PORT=8080
EXPOSE $APP_PORT
```

## Testing Docker Images in CI

**Critical patterns learned from production failures:**

### 1. Bypass Entrypoint for Direct Testing

When images have entrypoint scripts, they execute before your test command:

```yaml
# WRONG - entrypoint runs, interferes with test
- run: docker run --rm myimage php -v

# CORRECT - bypass entrypoint for direct command
- run: docker run --rm --entrypoint php myimage -v
- run: docker run --rm --entrypoint node myimage --version
```

### 2. Mock DNS for Upstream Servers

nginx/haproxy configs with upstream servers fail `nginx -t` in isolation:

```yaml
# WRONG - fails with "host not found in upstream"
- run: docker run --rm nginx-image nginx -t

# CORRECT - provide fake DNS resolution
- run: docker run --rm --add-host backend:127.0.0.1 nginx-image nginx -t
```

### 3. Docker Compose Validation

When `compose.yml` uses required variables (`${VAR:?error}`), create `.env` first:

```yaml
- name: Create test environment
  run: |
    cp .env.example .env
    sed -i 's/CHANGE_ME_PASSWORD/test_ci_password/g' .env

- name: Validate compose syntax
  run: docker compose config > /dev/null
```

### 4. Secret Scanning Exclusions

Documentation legitimately references placeholder passwords:

```yaml
- name: Check for leaked secrets
  run: |
    EXCLUDE=".env.example|README|QUICKSTART|docs/"
    if git ls-files | xargs grep -l "CHANGE_ME" | grep -vE "$EXCLUDE"; then
      echo "Found secrets in tracked files"
      exit 1
    fi
```

## Docker Compose Patterns

### Health Checks and Dependencies

```yaml
services:
  app:
    depends_on:
      database:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s  # Grace period for slow startups
```

### Network Isolation

```yaml
networks:
  frontend:
    name: ${PROJECT}_frontend
  backend:
    name: ${PROJECT}_backend
    internal: true  # No external access

services:
  nginx:
    networks: [frontend, backend]  # Bridge
  app:
    networks: [frontend, backend]  # Needs internet + internal
  database:
    networks: [backend]  # Internal only
```

### Optional Services with Profiles

```yaml
services:
  mailpit:
    profiles: [dev]  # Only starts with --profile dev

  debug-tools:
    profiles: [debug]
```

## CI/CD Workflow Pattern

```yaml
name: Docker Build

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/build-push-action@v6
        with:
          context: .
          load: true  # Load for testing
          tags: myimage:test
          cache-from: type=gha
          cache-to: type=gha,mode=max

      # Test the built image
      - name: Verify image
        run: |
          docker run --rm --entrypoint /bin/sh myimage:test -c "echo 'Image works'"

      - uses: docker/login-action@v3
        if: github.event_name != 'pull_request'
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          push: ${{ github.event_name != 'pull_request' }}
          tags: ghcr.io/${{ github.repository }}:latest
```

## Security Scanning

```yaml
- name: Run Trivy vulnerability scanner
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: myimage:test
    format: 'table'
    exit-code: '1'  # Fail on HIGH/CRITICAL
    severity: 'CRITICAL,HIGH'
```

## References

- `references/dockerfile-patterns.md` - Advanced Dockerfile techniques
- `references/compose-patterns.md` - Docker Compose orchestration
- `references/ci-testing.md` - Comprehensive CI testing patterns
- `references/security.md` - Container security hardening
