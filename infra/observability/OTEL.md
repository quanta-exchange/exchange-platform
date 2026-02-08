# OpenTelemetry E2E Tracing Baseline (I-0102)

## Objective
Provide trace continuity for request lifecycle with shared correlation fields:
- edge request span
- core command metadata (`trace_id`, `correlation_id`)
- ledger settlement span

## Local Collector
- Compose collector receives OTLP gRPC/HTTP on `14317` / `14318`.
- Collector exports:
  - debug logs
  - prometheus metrics (`18889`)
  - self metrics (`18888`)

## Edge Gateway
- Env:
  - `EDGE_OTEL_ENDPOINT` (example: `localhost:14317`)
  - `EDGE_OTEL_INSECURE=true`
  - `EDGE_OTEL_SERVICE_NAME=edge-gateway`
  - `EDGE_OTEL_SAMPLE_RATIO=1.0`
- Behavior:
  - extracts/propagates `traceparent`
  - emits server spans per route
  - sets `X-Trace-Id` response header

## Ledger Service
- Env:
  - `LEDGER_OTEL_ENDPOINT=http://localhost:14318/v1/traces`
  - `LEDGER_OTEL_SAMPLE_PROB=1.0`
- Behavior:
  - Spring/Micrometer OTel bridge emits traces and metrics.
  - logs keep correlation identifiers from event envelope.

## Sampling
- Default: 100% in local/staging.
- Production recommendation:
  - baseline 10%
  - force sample on errors, latency outliers, and safety actions.

## Smoke Procedure
1. Start compose infra.
2. Start edge + ledger with OTel env enabled.
3. Run `./scripts/smoke_g3.sh`.
4. Check collector debug logs for trace spans.
