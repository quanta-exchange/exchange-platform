# Secrets Policy (I-0104)

## Scope
- Applies to all environments: `dev`, `staging`, `prod`.
- Covers API secrets, DB credentials, Kafka credentials, signing material, and cloud credentials.

## Hard Rules
- No plaintext secrets in git.
- No long-lived user credentials for production write paths.
- All production secret reads must be auditable with actor, reason, ticket.
- Rotation is mandatory:
  - API secrets: 30 days
  - DB/Kafka service credentials: 30 days
  - KMS data keys: 7 days
  - TLS certificates: 90 days

## Storage
- Runtime secrets: external secret manager (or vault-compatible store).
- Envelope encryption:
  - KMS key encrypts per-service data keys.
  - Data keys encrypt WAL archive metadata and sensitive config blobs.

## Distribution
- Kubernetes only through sealed/external secret controller.
- No `kubectl create secret --from-literal` for production changes.
- Secret change requires:
  - ticket id
  - dual approval
  - rollback plan

## Audit and Alerts
- Metrics:
  - `secret_access_audit_total`
  - `rotation_age_seconds`
- Alerts:
  - access without ticket tag
  - rotation age above policy threshold

## Incident Response
1. Revoke suspected secret immediately.
2. Rotate dependent credentials and tokens.
3. Audit all accesses in lookback window.
4. Mark system `CANCEL_ONLY`/`SOFT_HALT` if risk touches trading correctness.
