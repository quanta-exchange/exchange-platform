# Runbook: Reconciliation Lag Spike

## Trigger
- `reconciliation_lag_max` 급증
- `reconciliation_breach_active=1`
- 주문이 `CANCEL_ONLY`로 거절되기 시작함

## Automated Drill
```bash
./runbooks/lag_spike.sh
```

## What It Does
1. 실행 전 `system_status.sh`로 core/edge/ledger/kafka/ws 상태 스냅샷(`status-before.json`)을 저장
2. reconciliation safety smoke를 실행해 lag breach 감지/안전모드 전환/복구/래치 해제를 검증
3. safety budget 체크를 실행해 현재 증거 상태를 기록
4. 실행 후 `system_status.sh` 스냅샷(`status-after.json`)을 저장
5. 결과 리포트를 `build/runbooks/lag-spike-<timestamp>/`에 저장
