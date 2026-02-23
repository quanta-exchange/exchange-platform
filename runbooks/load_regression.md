# Runbook: Load Regression Drill

## Trigger
- 주문 API p95/p99 악화
- WS fan-out drop/slow close 증가
- 배포 후 성능 회귀 의심

## Automated Drill
```bash
./runbooks/load_regression.sh
# gateway-only dry-run(코어 미연결 환경): RUNBOOK_ALLOW_BUDGET_FAIL=true ./runbooks/load_regression.sh
```

## What It Does
1. 실행 전 `system_status.sh`로 core/edge/ledger/kafka/ws 스냅샷(`status-before.json`) 저장
2. `load_all.sh` 실행 (`load-smoke` → `load-10k` → `load-50k`) 및 통합 리포트 생성
3. `safety_budget_check.sh`로 load/WS/DR/invariants 예산 위반 여부 확인
   - `RUNBOOK_ALLOW_BUDGET_FAIL=true`면 예산 위반을 기록(`runbook_budget_ok=false`)하고 드릴을 계속 진행
4. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장
5. 결과 리포트를 `build/runbooks/load-regression-<timestamp>/`에 저장
