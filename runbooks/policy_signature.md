# Runbook: Policy Signature Drill

## Trigger
- `policy_smoke`가 실패했을 때
- 배포 전 서명 정책 파일이 정상 생성/검증되는지 확인할 때

## Automated Drill
```bash
./runbooks/policy_signature.sh
```

옵션:
```bash
RUNBOOK_ALLOW_POLICY_FAIL=true ./runbooks/policy_signature.sh
RUNBOOK_ALLOW_BUDGET_FAIL=true ./runbooks/policy_signature.sh
```

## What It Does
1. 실행 전 `system_status.sh` 스냅샷(`status-before.json`) 저장
2. `policy_smoke.sh` 실행 (서명 생성 + 검증)
3. `safety_budget_check.sh` 실행
4. `policy-signature-summary.json` 생성
   - `policy_ok`
   - `budget_ok`
   - `recommended_action`
5. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장

Outputs:
- `runbook_policy_signature_ok=true|false`
- `policy_smoke_ok=true|false`
- `policy_recommended_action=...`
- `runbook_budget_ok=true|false`
- `runbook_output_dir=build/runbooks/policy-signature-<timestamp>`
