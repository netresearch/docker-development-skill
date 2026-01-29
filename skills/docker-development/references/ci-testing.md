# CI Testing Patterns for Docker Images

Comprehensive patterns for testing Docker images in CI/CD pipelines.

## The Challenge

Docker images often have:
- **Entrypoint scripts** that run before any command
- **Service dependencies** (databases, caches) that don't exist in CI
- **Network configurations** referencing other containers
- **Required environment variables** that fail validation

These cause CI failures that don't occur in local development.

## Pattern 1: Entrypoint Bypass

### Problem

```dockerfile
# Dockerfile
ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
```

```yaml
# CI - FAILS
- run: docker run --rm myimage php -v
# Output: entrypoint.sh runs, starts services, php -v never executes properly
```

### Solution

```yaml
# Override entrypoint for direct command execution
- run: docker run --rm --entrypoint php myimage -v
- run: docker run --rm --entrypoint php myimage -m  # List modules
- run: docker run --rm --entrypoint node myimage --version
- run: docker run --rm --entrypoint /bin/sh myimage -c "cat /etc/os-release"
```

### When to Use

- Verifying installed software versions
- Checking available extensions/modules
- Testing configuration files
- Running diagnostic commands

## Pattern 2: DNS Mocking for Upstream Services

### Problem

```nginx
# nginx.conf
upstream backend {
    server app:9000;
}
```

```yaml
# CI - FAILS
- run: docker run --rm nginx-image nginx -t
# Error: host not found in upstream "app:9000"
```

### Solution

```yaml
# Provide fake DNS resolution for upstream hosts
- run: |
    docker run --rm \
      --add-host app:127.0.0.1 \
      --add-host database:127.0.0.1 \
      --add-host cache:127.0.0.1 \
      nginx-image nginx -t
```

### Multiple Upstreams

```yaml
- name: Test nginx config
  run: |
    docker run --rm \
      --add-host php-fpm:127.0.0.1 \
      --add-host mailpit:127.0.0.1 \
      --add-host redis:127.0.0.1 \
      myapp-nginx nginx -t
```

## Pattern 3: Docker Compose Validation

### Problem

```yaml
# compose.yml
services:
  app:
    environment:
      - DB_PASSWORD=${DB_PASSWORD:?Required}
```

```yaml
# CI - FAILS
- run: docker compose config
# Error: required variable DB_PASSWORD is missing
```

### Solution

```yaml
- name: Create test environment
  run: |
    cp .env.example .env
    # Replace all CHANGE_ME placeholders
    sed -i 's/CHANGE_ME_[A-Z_]*/test_password/g' .env

- name: Validate compose syntax
  run: docker compose config > /dev/null
```

### Alternative: Inline Variables

```yaml
- name: Validate compose
  env:
    DB_PASSWORD: test
    REDIS_PASSWORD: test
  run: docker compose config > /dev/null
```

## Pattern 4: Health Check Verification

### Test Health Check Command

```yaml
- name: Build image
  run: docker build -t myapp:test .

- name: Test health check
  run: |
    # Start container
    docker run -d --name test-container myapp:test

    # Wait for health
    timeout 60 bash -c 'until docker inspect test-container --format="{{.State.Health.Status}}" | grep -q healthy; do sleep 2; done'

    # Verify
    docker inspect test-container --format="{{.State.Health.Status}}"

- name: Cleanup
  if: always()
  run: docker rm -f test-container
```

## Pattern 5: Secret Scanning with Exclusions

### Problem

Documentation references placeholder passwords:

```markdown
<!-- README.md -->
Set `DB_PASSWORD=CHANGE_ME` in your .env file
```

```yaml
# CI - FALSE POSITIVE
- run: git ls-files | xargs grep -l "CHANGE_ME" && exit 1
# Fails on README.md, QUICKSTART.md, etc.
```

### Solution

```yaml
- name: Check for leaked secrets
  run: |
    # Files that legitimately reference placeholders
    EXCLUDE_PATTERN=".env.example|README|QUICKSTART|docs/|Makefile|\.github/"

    # Find files with secrets, excluding legitimate references
    FOUND=$(git ls-files | xargs grep -l "CHANGE_ME" | grep -vE "$EXCLUDE_PATTERN" || true)

    if [ -n "$FOUND" ]; then
      echo "Found secrets in:"
      echo "$FOUND"
      exit 1
    fi
    echo "No leaked secrets detected"
```

## Pattern 6: Multi-Platform Build Testing

```yaml
- name: Set up QEMU
  uses: docker/setup-qemu-action@v3

- name: Set up Buildx
  uses: docker/setup-buildx-action@v3

- name: Build multi-platform
  uses: docker/build-push-action@v6
  with:
    platforms: linux/amd64,linux/arm64
    load: false  # Can't load multi-platform
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

## Pattern 7: Integration Testing with Service Containers

```yaml
jobs:
  test:
    services:
      database:
        image: mariadb:11
        env:
          MYSQL_ROOT_PASSWORD: test
          MYSQL_DATABASE: testdb
        options: >-
          --health-cmd="healthcheck.sh --connect --innodb_initialized"
          --health-interval=10s
          --health-timeout=5s
          --health-retries=5

    steps:
      - name: Build app image
        run: docker build -t myapp:test .

      - name: Run integration tests
        run: |
          docker run --rm \
            --network ${{ job.container.network }} \
            -e DB_HOST=database \
            -e DB_PASSWORD=test \
            myapp:test npm test
```

## Complete CI Workflow Example

```yaml
name: Docker CI

on: [push, pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup test environment
        run: |
          cp .env.example .env
          sed -i 's/CHANGE_ME_[A-Z_]*/ci_test_value/g' .env

      - name: Validate compose
        run: docker compose config > /dev/null

  build-and-test:
    runs-on: ubuntu-latest
    needs: validate
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - name: Build images
        run: docker compose build

      - name: Test PHP version
        run: docker run --rm --entrypoint php myapp:latest -v | grep "8.4"

      - name: Test nginx config
        run: docker run --rm --add-host app:127.0.0.1 myapp-nginx nginx -t

      - name: Start stack
        run: |
          cp .env.example .env
          sed -i 's/CHANGE_ME_[A-Z_]*/ci_test/g' .env
          docker compose up -d

      - name: Wait for healthy
        run: |
          timeout 120 bash -c 'until docker compose ps | grep -q healthy; do sleep 5; done'

      - name: Test endpoint
        run: curl -f http://localhost/ || exit 1

      - name: Cleanup
        if: always()
        run: docker compose down -v
```
