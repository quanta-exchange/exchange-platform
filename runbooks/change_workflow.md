# Runbook: Change Workflow Drill

## Trigger
- 변경관리 파이프라인(proposal -> approvals -> apply -> audit-chain verify)을 정기적으로 점검해야 할 때
- 릴리즈 전 4-eyes 승인 및 변경 이력 무결성 증거를 빠르게 재확인해야 할 때

## Automated Drill
```bash
./runbooks/change_workflow.sh
```

Optional inputs:
- `APPLY_COMMAND="echo dry-run"`: 적용 명령 교체
- `REQUESTED_BY/APPROVER_A/APPROVER_B/APPLIED_BY`: 주체명 커스터마이징
- `OUT_DIR=...`: 산출물 경로 고정
- `RUNBOOK_SKIP_VERIFICATION=false`: `apply_change` 단계에서 full verification 실행

## What It Does
1. 실행 전 `system_status.sh` 스냅샷(`status-before.json`) 저장
2. runbook 전용 경로에서 `change_proposal.sh`로 HIGH risk 변경 생성
3. 서로 다른 2명의 승인자(`APPROVER_A/B`)로 승인 기록
4. `apply_change.sh --skip-verification` 적용 실행
5. `verify_change_audit_chain.sh --require-change-id --require-applied`로 체인 검증
6. 요약 파일(`change-workflow-summary.json`) + 실행 후 스냅샷(`status-after.json`) 저장

Outputs:
- `runbook_change_workflow_ok=true|false`
- `runbook_output_dir=build/runbooks/change-workflow-<timestamp>`
