# Runbook: Kafka Network Partition Drill

## Trigger
- Kafka/Redpanda 경로가 간헐적으로 끊기거나 재연결 후 lag 복구가 불안정할 때
- 장애 대응 훈련(GameDay)에서 네트워크 단절 시나리오를 재현해야 할 때

## Automated Drill
```bash
./runbooks/network_partition.sh
```

옵션:
```bash
RUNBOOK_ALLOW_NETWORK_PARTITION_FAIL=true ./runbooks/network_partition.sh
RUNBOOK_ALLOW_BUDGET_FAIL=true ./runbooks/network_partition.sh
```

## What It Does
1. 실행 전 `system_status.sh` 스냅샷(`status-before.json`) 저장
2. `scripts/chaos/network_partition.sh` 실행
   - broker endpoint baseline reachability 확인
   - 네트워크 분리(또는 pause fallback) 주입
   - 분리 구간 동안 broker endpoint 비가용성 확인
   - 복구 후 produce/consume 재검증
3. `safety_budget_check.sh` 실행
4. `network-partition-summary.json` 생성
   - `network_partition_ok`
   - `during_partition_broker_reachable`
   - `applied_isolation_method`
   - `recommended_action`
5. 실행 후 `system_status.sh` 스냅샷(`status-after.json`) 저장

Outputs:
- `runbook_network_partition_ok=true|false`
- `chaos_network_partition_ok=true|false`
- `network_partition_recommended_action=...`
- `runbook_budget_ok=true|false`
- `runbook_output_dir=build/runbooks/network-partition-<timestamp>`
