# AGENTS.md — docker-development-skill

## Repo Structure

```
.
├── skills/docker-development/
│   ├── SKILL.md                        # Main skill definition
│   ├── checkpoints.yaml                # Evaluation checkpoints
│   └── references/
│       ├── ci-testing.md               # CI testing patterns for containers
│       └── dind-testing-patterns.md    # Docker-in-Docker testing patterns
├── Build/
│   ├── Scripts/
│   │   └── check-plugin-version.sh     # Version validation script
│   └── hooks/
│       └── pre-push                    # Git pre-push hook
├── evals/
│   └── evals.json                      # Evaluation definitions
├── .github/workflows/                  # CI workflows
├── composer.json                       # PHP package metadata
├── docs/                               # Architecture and planning docs
│   ├── ARCHITECTURE.md
│   └── exec-plans/
├── scripts/
│   └── verify-harness.sh              # Harness verification script
└── README.md
```

## Commands

- `bash scripts/verify-harness.sh --format=text --status` — check harness maturity level
- `bash Build/Scripts/check-plugin-version.sh` — validate plugin version consistency

## Rules

1. **Minimal images** — use Alpine or distroless base images with multi-stage builds.
2. **Security first** — run as non-root user, never bake secrets into layers.
3. **Testable** — all images must be verifiable in CI; bypass entrypoints for testing.
4. **Reproducible** — pin dependency versions, use checksums for downloads.
5. **Layer optimization** — combine RUN commands, clean up in the same layer.
6. **CI testing**: create `.env` from `.env.example` before `docker compose config`.
7. **Mock upstream DNS** with `--add-host` when testing nginx configs in isolation.

## References

- [SKILL.md](skills/docker-development/SKILL.md) — full skill definition
- [CI Testing](skills/docker-development/references/ci-testing.md) — CI testing patterns
- [DinD Patterns](skills/docker-development/references/dind-testing-patterns.md) — Docker-in-Docker testing
