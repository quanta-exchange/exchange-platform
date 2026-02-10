# OpenTelemetry E2E Tracing Baseline (I-0102)

## Objective
Provide trace continuity for request lifecycle with shared correlation fields:
- edge request span
- core command metadata (`trace_id`, `correlation_id`)
- ledger settlement span

## Local Collector
- Compose collector receives OTLP gRPC/HTTP on `24317` / `24318`.
- Collector exports:
  - debug logs
  - prometheus metrics (`28889`)
  - self metrics (`28888`)

## Edge Gateway
- Env:
  - `EDGE_OTEL_ENDPOINT` (example: `localhost:24317`)
  - `EDGE_OTEL_INSECURE=true`
  - `EDGE_OTEL_SERVICE_NAME=edge-gateway`
  - `EDGE_OTEL_SAMPLE_RATIO=1.0`
- Behavior:
  - extracts/propagates `traceparent`
  - emits server spans per route
  - sets `X-Trace-Id` response header

## Ledger Service
- Env:
  - `LEDGER_OTEL_ENDPOINT=http://localhost:24318/v1/traces`
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
