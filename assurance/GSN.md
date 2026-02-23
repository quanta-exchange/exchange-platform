# Safety Case (GSN Skeleton)

## Goal
G0: 장애/중복/재시도/재기동 상황에서도 자산 정합성과 거래 상태 일관성이 유지된다.

## Strategy
S1: 핵심 주장(G1~G4)을 자동 생성된 증거 번들(리포트/로그/해시)로 입증한다.

## Context
- C1: Trading Core는 WAL durable 이후에만 executed 상태를 외부로 전파한다.
- C2: Ledger는 append-only double-entry와 trade/settlement idempotency를 강제한다.
- C3: Kafka/consumer는 at-least-once 전달을 전제로 중복 처리 방어를 구현한다.

## Sub-goals
- G1: Invariants 유지
  - available + hold == total
  - posting signed sum == 0
  - seq monotonicity
- G2: Exactly-once effect
  - 동일 trade 중복 주입 시 잔고 변화는 1회만 반영
- G3: Reconciliation safety
  - lag/mismatch 감지 시 CANCEL_ONLY/HALT 전환
  - latch는 승인 없는 자동 해제 불가
- G4: Crash recovery determinism
  - core kill -9 후 state hash 보존
  - ledger 재기동 후 double-apply 0

## Evidence Mapping (example)
- E1: `build/invariants/ledger-invariants.json`
- E2: `build/exactly-once/exactly-once-stress.json`
- E3: `build/reconciliation/smoke-reconciliation-safety.json`
- E4: `build/chaos/chaos-replay.json`
- E5: `build/safety-case/.../manifest.json`

## Notes
- `scripts/assurance_pack.sh`는 최신 증거 파일을 스캔해 `build/assurance/<timestamp>/assurance-pack.*`를 생성한다.
- 릴리즈 게이트는 `assurance_pack_ok=true` 조건으로 고정한다.
