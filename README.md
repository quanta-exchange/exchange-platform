# Exchange Monorepo — Spot Exchange (Production‑grade)

This repository is a **big‑tech style polyglot monorepo** for a spot crypto exchange.

## Stack (locked)
- Trading Core: **Rust** (matching + risk hot‑path)
- Edge Gateway: **Go** (REST + WebSocket fan‑out)
- Ledger Service: **Kotlin + Spring Boot + PostgreSQL** (double‑entry, append‑only)
- Event log: **Kafka/Redpanda + Protobuf**
- Streaming: **Flink**
- Cache/History/Archive: **Redis / ClickHouse / S3**
- Infra: **Kubernetes + OpenTelemetry + GitOps + KMS/HSM**

## Repo layout
```text
exchange-monorepo/
  README.md
  Plans.md
  ARCHITECTURE.md
  API_SURFACE.md
  RUNBOOK.md
  contracts/                # protobuf + buf (planned in next sprint)
  services/
    trading-core/           # Rust
    edge-gateway/           # Go
    ledger-service/         # Kotlin + Spring
  streaming/
    flink-jobs/             # Flink
  infra/
    compose/                # local infra (planned)
    k8s/                    # helm/kustomize (planned)
    gitops/                 # ArgoCD (planned)
  tasks/backlog/            # tickets (source of truth)
```

## Quick start (local dev)
> The `infra/compose` and `contracts/` scaffolding is tracked as tickets and will be added early (Gate G0).

### Prereqs
- Docker + Compose
- JDK 21 (or 17), Gradle wrapper
- Go 1.22+
- Rust stable + cargo
- buf (protobuf)
- kubectl/helm (optional)

### Suggested workflow
1) Bring up infra (compose)
2) Generate protobuf code (buf)
3) Run services locally via IDE (IntelliJ) or CLI
4) Run e2e scenario tests (orders → trades → ledger → WS)

## Developer standards
- **No synchronous DB calls** in Trading Core hot path.
- **Append‑only** ledger; corrections via reversal/adjustment.
- **Idempotency everywhere**: commands, events, settlement.
- **Every event has seq** and correlation/causation IDs.
- **Backpressure is mandatory** for WS fan‑out.

## Docs
- `Plans.md` — milestones, gates, backlog rules
- `ARCHITECTURE.md` — system design and data flows
- `API_SURFACE.md` — REST/WS/gRPC/event contracts
- `RUNBOOK.md` — incident response and operational playbooks

## Tickets
All work items live under `tasks/backlog/`.
Each ticket includes: scope, AC, tests, observability, rollback, runbook updates.
