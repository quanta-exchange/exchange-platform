# Runbook: Game Day Anomaly Drill

## Trigger
- 이상 징후 자동 격리 경로를 정기적으로 리허설해야 할 때
- 온콜 훈련에서 alert webhook / evidence bundle 흐름 확인이 필요할 때

## Automated Drill
```bash
./runbooks/game_day_anomaly.sh
# webhook 전달까지 점검:
WEBHOOK_URL=https://example.internal/webhook ./runbooks/game_day_anomaly.sh
```

## What It Does
1. 실행 전 `system_status.sh` 스냅샷(`status-before.json`) 저장
2. `anomaly_detector.sh --force-anomaly --allow-anomaly`로 강제 이상 이벤트 생성
3. (옵션) webhook 전달 시도 결과 기록
4. `safety_budget_check.sh` 결과 저장
5. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장
6. 결과를 `build/runbooks/game-day-anomaly-<timestamp>/`에 저장
