# AGENTS.md — docker-development-skill

## Repo Structure

```
.
├── skills/docker-development/
│   ├── SKILL.md                        # Main skill definition
│   ├── checkpoints.yaml                # Evaluation checkpoints
│   └── references/
│       ├── ci-testing.md               # CI testing patterns for containers
│       ├── dind-testing-patterns.md    # Docker-in-Docker testing patterns
│       └── bind-mount-ownership.md     # root-owned bind-mount artifacts
├── skills/docker-via-wsl/              # Windows: run docker through WSL2
│   ├── SKILL.md                        # Skill definition
│   └── references/
│       └── diagnosis-and-fix.md        # wrong-bind-mount diagnosis + fix
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
2. **Security first** — run as non-root USER, never bake secrets into layers, pin versions.
3. **No security anti-patterns** — no `chmod 777`, no `privileged: true`, no host root mounts, no `0.0.0.0` binding, no secrets in ENV/ARG.
4. **Cache-efficient** — copy dependency files (package.json, go.mod) before source code; combine RUN commands; clean apt cache in same layer.
5. **Testable** — all images must be verifiable in CI; bypass entrypoints with `--entrypoint`.
6. **CI testing**: create `.env` from `.env.example` before `docker compose config`.
7. **Mock upstream DNS** with `--add-host` when testing nginx configs in isolation.
8. **BuildKit secrets** — use `--mount=type=secret` for private repos, never `ENV`/`COPY` secrets.

## References

- [docker-development SKILL.md](skills/docker-development/SKILL.md) — full skill definition
- [docker-via-wsl SKILL.md](skills/docker-via-wsl/SKILL.md) — run docker through WSL2 on Windows hosts
- [CI Testing](skills/docker-development/references/ci-testing.md) — CI testing patterns
- [DinD Patterns](skills/docker-development/references/dind-testing-patterns.md) — Docker-in-Docker testing
- [Bind-Mount Ownership](skills/docker-development/references/bind-mount-ownership.md) — root-owned bind-mount artifacts
- [WSL Diagnosis & Fix](skills/docker-via-wsl/references/diagnosis-and-fix.md) — wrong-bind-mount diagnosis from a Windows shell
