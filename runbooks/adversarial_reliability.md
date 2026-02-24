# Runbook: Adversarial Reliability Drill

## Trigger
- `adversarial_tests`가 실패했을 때
- 릴리즈 전 적대적 입력(중복/순서 뒤집힘/WS 느린 소비자/스냅샷 복구) 통합 방어를 재검증할 때

## Automated Drill
```bash
./runbooks/adversarial_reliability.sh
```

옵션:
```bash
RUNBOOK_ALLOW_ADVERSARIAL_FAIL=true ./runbooks/adversarial_reliability.sh
RUNBOOK_ALLOW_BUDGET_FAIL=true ./runbooks/adversarial_reliability.sh
```

## What It Does
1. 실행 전 `system_status.sh` 스냅샷(`status-before.json`) 저장
2. `adversarial_tests.sh` 실행
3. `safety_budget_check.sh` 실행
4. `adversarial-reliability-summary.json` 생성
   - `adversarial_ok`
   - `failed_step_count`
   - `exactly_once_status`
   - `recommended_action`
5. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장

Outputs:
- `runbook_adversarial_reliability_ok=true|false`
- `adversarial_tests_ok=true|false`
- `adversarial_failed_step_count=<n>`
- `adversarial_recommended_action=...`
- `runbook_budget_ok=true|false`
- `adversarial_reliability_summary_file=build/runbooks/adversarial-reliability-<timestamp>/adversarial-reliability-summary.json`
- `adversarial_reliability_summary_latest=build/runbooks/adversarial-reliability-latest.json`
- `runbook_output_dir=build/runbooks/adversarial-reliability-<timestamp>`
