# Runbook: Startup Guardrails Verification

## Trigger
- 배포 전후 프로덕션 fail-closed 설정 검증 필요
- 운영 환경 설정 변경(인증/카프카/래치 승인 정책) 이후 확인 필요

## Automated Drill
```bash
./runbooks/startup_guardrails.sh
# 로컬에서 trading-core cargo 환경 제약이 있을 때:
RUNBOOK_ALLOW_CORE_FAIL=true ./runbooks/startup_guardrails.sh
```

## What It Does
1. 실행 전 `system_status.sh`로 상태 스냅샷(`status-before.json`) 저장
2. Edge production guardrail 테스트 실행
3. Ledger production guardrail 테스트 실행
4. Trading Core runtime guardrail 테스트 실행(옵션으로 skip/allow-fail 가능)
5. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장
6. 결과를 `build/runbooks/startup-guardrails-<timestamp>/`에 저장
