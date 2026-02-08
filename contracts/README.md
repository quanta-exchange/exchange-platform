# Contracts

Protobuf contracts are the single source of truth.

## Layout
- `proto/exchange/v1/*.proto`: authoritative schemas
- `gen/go`: generated Go stubs
- `gen/rust`: generated Rust stubs
- `gen/kotlin`: generated Kotlin/Java stubs

## Generation
```bash
buf lint
buf generate
```

## Breaking policy
- Every event envelope includes:
  - `event_id`, `event_version`, `symbol`, `seq`, `occurred_at`, `correlation_id`, `causation_id`
- Non-breaking changes stay in package `exchange.v1`
- Breaking changes require new major package `exchange.v2` and migration path

## No manual edits
- Files under `gen/` are generated artifacts and must not be edited by hand.
