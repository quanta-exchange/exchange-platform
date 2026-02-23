# Runbook: Audit Chain Tamper Drill

## Trigger
- 감사 로그 무결성 검증기(`verify_audit_chain.sh`)가 실제 변조를 잡는지 주기적으로 확인할 때
- 감사/규제 점검 전 tamper-evidence 데모가 필요할 때

## Automated Drill
```bash
./runbooks/audit_chain_tamper.sh
```

## What It Does
1. 실행 전 상태 스냅샷(`status-before.json`) 저장
2. `break_glass` 이벤트를 추가 생성해서 감사 로그 샘플 확보
3. 감사 로그 복사본 기준선 검증(`verify_audit_chain --require-events`) 수행
4. 복사본 1건을 의도적으로 변조한 뒤 다시 검증하여 실패(탐지) 확인
5. 요약 리포트(`audit-chain-tamper-summary.json`) 저장
6. 실행 후 상태 스냅샷(`status-after.json`) 저장
