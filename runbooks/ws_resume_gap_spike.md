# Runbook: WS Resume Gap Spike

## Trigger
- `WSResumeGapSpike` alert fired (`increase(ws_resume_gaps[10m])`)
- 클라이언트 재연결 후 `Missed`/`Snapshot` fallback 비율 급증
- 특정 심볼에서 trade replay 히스토리 범위 이탈 민원 증가

## Automated Drill
```bash
./runbooks/ws_resume_gap_spike.sh
```

## What It Does
1. 실행 전 `system_status.sh`로 core/edge/ledger/kafka/ws 상태 스냅샷(`status-before.json`)을 저장
2. `ws_resume_smoke.sh`를 실행해 replay 가능 구간 + gap fallback + `ws_resume_gaps` 메트릭 증가를 검증
3. `safety_budget_check.sh`로 WS resume 관련 예산(`wsResume`) 준수 여부를 검증
4. 실행 후 `system_status.sh` 스냅샷(`status-after.json`)을 저장
5. 결과 리포트를 `build/runbooks/ws-resume-gap-spike-<timestamp>/`에 저장
