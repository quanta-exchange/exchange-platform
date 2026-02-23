# Runbook: WS Drop/Slow-Client Spike

## Trigger
- `ws_dropped_msgs` 급증
- `ws_slow_closes` 급증
- 클라이언트 지연/재연결 민원 증가

## Automated Drill
```bash
./runbooks/ws_drop_spike.sh
```

## What It Does
1. 실행 전 `system_status.sh`로 core/edge/ledger/kafka/ws 상태 스냅샷(`status-before.json`)을 저장
2. slow-client WS smoke를 실행해 backpressure 정책(drop/close)을 검증
3. safety budget 체크로 WS 예산 준수 여부를 기록
4. 실행 후 `system_status.sh` 스냅샷(`status-after.json`)을 저장
5. 결과 리포트를 `build/runbooks/ws-drop-spike-<timestamp>/`에 저장
