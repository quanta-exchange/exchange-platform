# Runbook: Safety Budget Failure Drill

## Trigger
- `safety_budget_check` or `release_gate`가 실패했을 때
- 예산 위반 원인을 빠르게 분류하고 재검증 액션을 정할 때

## Automated Drill
```bash
./runbooks/budget_failure.sh
```

## What It Does
1. 실행 전 `system_status.sh` 스냅샷(`status-before.json`) 저장
2. `safety_budget_check.sh` 실행 및 결과 캡처
3. `budget-failure-summary.json` 생성
   - `budget_ok`
   - `violation_count`
   - `violations`
   - `recommended_action`
4. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장

Outputs:
- `runbook_budget_failure_ok=true|false`
- `budget_ok=true|false`
- `budget_violation_count=<n>`
- `budget_recommended_action=...`
- `runbook_output_dir=build/runbooks/budget-failure-<timestamp>`
