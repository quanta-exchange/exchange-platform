# Runbook: Redpanda Broker Bounce Drill

## Trigger
- Kafka/Redpanda broker restart 후 produce/consume 경로 안정성을 점검해야 할 때
- 장애 복구 훈련(GameDay)에서 broker down/restart 시나리오를 재현해야 할 때

## Automated Drill
```bash
./runbooks/redpanda_broker_bounce.sh
```

옵션:
```bash
RUNBOOK_ALLOW_REDPANDA_BOUNCE_FAIL=true ./runbooks/redpanda_broker_bounce.sh
RUNBOOK_ALLOW_BUDGET_FAIL=true ./runbooks/redpanda_broker_bounce.sh
```

## What It Does
1. 실행 전 `system_status.sh` 스냅샷(`status-before.json`) 저장
2. `scripts/chaos/redpanda_broker_bounce.sh` 실행
   - broker reachable baseline 확인
   - broker stop 동안 비가용성 확인
   - broker restart 후 produce/consume 재검증
3. `safety_budget_check.sh` 실행
4. `redpanda-broker-bounce-summary.json` 생성
   - `redpanda_broker_bounce_ok`
   - `during_stop_broker_reachable`
   - `after_restart_broker_reachable`
   - `post_restart_consume_ok`
   - `recommended_action`
5. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장

Outputs:
- `runbook_redpanda_broker_bounce_ok=true|false`
- `redpanda_broker_bounce_ok=true|false`
- `redpanda_broker_bounce_recommended_action=...`
- `runbook_budget_ok=true|false`
- `redpanda_broker_bounce_summary_file=build/runbooks/redpanda-broker-bounce-<timestamp>/redpanda-broker-bounce-summary.json`
- `redpanda_broker_bounce_summary_latest=build/runbooks/redpanda-broker-bounce-latest.json`
- `runbook_output_dir=build/runbooks/redpanda-broker-bounce-<timestamp>`
