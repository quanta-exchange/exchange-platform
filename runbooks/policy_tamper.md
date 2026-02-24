# Runbook: Policy Tamper Drill

## Trigger
- 정책 서명 검증기가 변조된 정책을 실제로 차단하는지 주기 점검할 때
- 배포 게이트 전 정책 무결성 데모가 필요할 때

## Automated Drill
```bash
./runbooks/policy_tamper.sh
```

옵션:
```bash
RUNBOOK_ALLOW_POLICY_TAMPER_FAIL=true ./runbooks/policy_tamper.sh
RUNBOOK_ALLOW_BUDGET_FAIL=true ./runbooks/policy_tamper.sh
```

## What It Does
1. 실행 전 `system_status.sh` 스냅샷(`status-before.json`) 저장
2. `prove_policy_tamper.sh` 실행
   - 정상 정책 서명 검증 성공 확인
   - 변조 정책 검증 실패(탐지) 확인
3. `safety_budget_check.sh` 실행
4. `policy-tamper-summary.json` 생성
   - `policy_tamper_ok`
   - `tamper_detected`
   - `recommended_action`
5. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장

Outputs:
- `runbook_policy_tamper_ok=true|false`
- `prove_policy_tamper_ok=true|false`
- `policy_tamper_recommended_action=...`
- `runbook_budget_ok=true|false`
- `policy_tamper_summary_file=build/runbooks/policy-tamper-<timestamp>/policy-tamper-summary.json`
- `policy_tamper_summary_latest=build/runbooks/policy-tamper-latest.json`
- `runbook_output_dir=build/runbooks/policy-tamper-<timestamp>`
