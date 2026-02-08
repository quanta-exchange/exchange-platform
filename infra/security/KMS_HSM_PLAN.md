# KMS / HSM Integration Plan (I-0104)

## Phase 1 (Launch-1)
- KMS-backed envelope encryption for:
  - WAL archive metadata
  - backup metadata
  - service secret payloads
- Key hierarchy:
  - Root CMK per environment
  - service data keys (rotated every 7 days)

## Phase 2
- Split keys by data domain:
  - `trading-core`
  - `ledger`
  - `market-data`
- Enable key usage anomaly alerting and stricter IAM conditions.

## Phase 3 (Custody/Signing)
- HSM-backed signing keys.
- No exportable private key material.
- JIT + MFA guarded signing operations.

## Operational Controls
- All key access tagged with:
  - `actor`
  - `service`
  - `ticket_id`
  - `reason`
- Break-glass access:
  - max 1 hour grant
  - mandatory post-incident review

## Rotation
- CMK rotation: yearly
- data key rotation: weekly
- forced rotation on compromise suspicion: immediate

## Validation
- quarterly rotation drill
- decryption replay test against archived snapshots
- key access audit completeness check
