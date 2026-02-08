# Production Access Control (I-0107)

## Model
- RBAC:
  - `exchange-readonly`: default oncall diagnostic role
  - `exchange-ops-admin`: break-glass operational role
- JIT only for write-capable production actions.
- No permanent individual write access.

## JIT Workflow
1. Create ticket with reason and scope.
2. Generate temporary role binding from `infra/k8s/rbac/jit-access-template.yaml`.
3. Include `expires-at` annotation.
4. Apply binding and record in audit log.
5. Auto-revoke at expiry.

## Audit Requirements
- Every admin action must include:
  - actor
  - reason
  - ticket id
  - resource + namespace
- Session recording enabled for shell access where platform allows.

## Metrics
- `prod_access_grants_total`
- `unauthorized_attempts_total`
- `jit_active_grants`

## Controls
- Mandatory MFA for all human production access.
- Daily review of active grants.
- Weekly access review drill.
