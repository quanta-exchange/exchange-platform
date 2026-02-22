# G4+ 운영 고도화 티켓 백로그 (현재 구현 반영)

기준일: 2026-02-22

## 1) 현재 구현 상태 스냅샷

| 영역 | 현재 상태 | 근거 |
|---|---|---|
| Reconciliation 잡 + 자동 안전모드 전환 | 구현됨 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/ReconciliationScheduler.kt`, `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` |
| Reconciliation status/history API | 구현됨 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/LedgerController.kt` |
| Reconciliation 메트릭 + 알람 예시 | 구현됨 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerMetrics.kt`, `infra/observability/reconciliation-alert-rules.example.yml` |
| Reconciliation smoke (consumer pause 후 lag 증가/안전모드) | 구현됨 | `scripts/smoke_reconciliation_safety.sh` |
| Chaos replay (core kill -9, ledger kill -9, 중복적용 없음 확인) | 구현됨 | `scripts/chaos_replay.sh`, `RUNBOOK.md` |
| WS 백프레셔 + conflation + slow close | 구현됨 | `services/edge-gateway/internal/gateway/server.go`, `scripts/ws_smoke.sh` |
| WS 운영 메트릭 (active/p99 queue/drop/slow close) | 구현됨 | `services/edge-gateway/internal/gateway/server.go` |
| Load smoke + DR rehearsal + safety-case baseline | 구현됨 | `scripts/load_smoke.sh`, `scripts/dr_rehearsal.sh`, `scripts/safety_case.sh`, `.github/workflows/ci.yml` |
| Corrections 2인 승인(기본) | 부분구현 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` |
| Invariants 자동검증 (전체 INV-001~005) | 부분구현 | 현재는 ledger posting 합/음수 위주 `invariantCheck()` |
| Reconciliation safety latch(자동해제 금지 + 수동 승인) | 미구현 | latch 옵션/승인 플로우 없음 |
| WS resume/gap 복구(채널별 운영형) | 부분구현 | in-memory history 기반, range replay/내구성 보강 필요 |
| Redpanda 장애 drill 표준화 | 미구현 | core/ledger crash는 있음, broker down drill 미흡 |
| Snapshot 업로드/검증/retention 정책 | 미구현 | 정책/verify 커맨드/오브젝트 저장 검증 없음 |
| Admin immutable audit / 4-eyes + timelock 전면화 | 부분구현 | correction만 부분, 공통 고위험 액션 프레임워크 부재 |
| 운영용 IAM/MFA/권한분리(SoD) | 부분구현 | k8s RBAC/JIT 문서는 있으나 앱 레벨 강제 부족 |
| 보안 경계(WAF/DDoS/Bot 방어) | 미구현 | edge 앞단 perimeter controls 정의/검증 부재 |
| 규제 필수(KYC/KYT/AML, 계정동결) | 미구현 | 온보딩/출금 제한 연동 부재 |
| 실입출금 통제(2인승인/timelock/한도) | 미구현 | 거래 체결/원장 중심, custody 운영통제 미완 |
| 24x7 온콜 자동화(Pager, 에스컬레이션) | 부분구현 | runbook는 존재, 알림 라우팅/훈련 자동화 부족 |
| 프로덕션 HA/장애조치 검증 | 부분구현 | 로컬/스모크 중심, 다중 AZ/페일오버 검증 미흡 |

### 1.1 정밀 점검에서 추가로 확인된 치명 리스크(코드 근거)

| 리스크 | 영향 | 코드 근거 | 보강 방향 |
|---|---|---|---|
| 인증 fail-open (`APISecrets` 비어있으면 요청 허용) | 설정 실수 시 무인증 주문 가능 | `services/edge-gateway/internal/gateway/server.go` (`authMiddleware`) | 프로덕션 fail-closed 부팅가드 + 헬스체크 차단 |
| WS Origin 전체 허용 | 브라우저 기반 악성 교차접속 위험 | `services/edge-gateway/internal/gateway/server.go` (`CheckOrigin: true`) | Origin allowlist + 토큰 바인딩 |
| 금액을 `float64`로 관리 | 라운딩 오차로 자산 불일치 가능 | `services/edge-gateway/internal/gateway/server.go` (`web_wallet_balances` DOUBLE, wallet math) | 최소단위 정수(BIGINT)로 전환 |
| Edge 자체 지갑/주문 상태를 메모리·로컬DB로 유지 | Ledger SoT 위반, 재시작/다중레플리카 불일치 | `services/edge-gateway/internal/gateway/server.go` (`state.wallets`, `state.orders`) | Ledger projection 기반 조회로 이관 |
| 신규 유저 기본 자산 시드 | 실서비스 자산통제 붕괴 | `services/edge-gateway/internal/gateway/server.go` (`defaultWalletBalances`) | 운영 환경에서 금지/제거 |
| `smoke` 거래 주입 API가 보호 라우트에 존재 | 내부 오용 시 허위 시세/체결 주입 | `services/edge-gateway/internal/gateway/server.go` (`POST /v1/smoke/trades`) | 프로덕션 빌드/런타임에서 완전 비활성 |
| 분산 fencing 부재(프로세스 로컬 atomic) | split-brain 방지 불충분 | `services/trading-core/src/leader.rs` | 외부 lease(Etcd/K8s Lease) 기반 fencing |
| Core 데모 자동잔고/Stub 체결 경로 존재 | 운영 설정 실수 시 비정상 체결 | `services/trading-core/src/engine.rs` (`bootstrap_user_balances`, `stub_trades`) | prod profile에서 compile/runtime 차단 |
| Ledger/Admin API 무인증 | 내부망 침해 시 고위험 조작 가능 | `services/ledger-service/src/main/kotlin/.../LedgerController.kt` | mTLS + admin RBAC + 승인 체계 |
| CI 보안 스캔 비차단(`exit-code: 0`) | 고위험 취약점이 릴리즈 통과 | `.github/workflows/ci.yml` | High/Critical 시 fail-closed |
| DR/Rotation 드릴이 시뮬레이션 중심 | 실제 복구/키회전 증거 부족 | `scripts/dr_rehearsal.sh`, `scripts/secret_rotation_drill.sh` | 실데이터/실시크릿 연동 드릴로 상향 |
| Kafka 이벤트가 Protobuf가 아닌 ad-hoc JSON | 스키마 일관성/호환성/감사 재현성 저하 | `services/trading-core/src/kafka.rs` | 이벤트 포맷 표준화 + 스키마 검증 게이트 |
| Edge Kafka consumer group 기본값이 단일 fan-out 일관성에 부적합 | 다중 edge에서 심볼별 이벤트 누락/편향 가능 | `services/edge-gateway/internal/gateway/server.go` (`GroupID` 소비) | 샤딩전략과 소비모델(전량/샤드) 재설계 |
| Settlement 실패를 DLQ로만 흡수하고 소비 진행 | 일시 장애에서도 ledger 미반영 이벤트 누락 가능 | `services/ledger-service/src/main/kotlin/.../LedgerService.kt` | 재시도 정책/오프셋 커밋 정책 분리 및 재처리 자동화 |
| Core 서비스 메트릭/헬스 엔드포인트 부재 | 운영 관측/자동복구 트리거 불충분 | `services/trading-core/src/bin/trading-core.rs` | Prometheus/health/readiness 엔드포인트 추가 |
| K8s 런타임 워크로드 매니페스트 부재 | GitOps 선언만 있고 실제 운영 배포 단위 미완 | `infra/k8s/base/*`, `infra/k8s/overlays/*` | Deployment/StatefulSet/Service/HPA/PDB 표준화 |
| Outbox/WAL 파일 성장 관리 정책 부재 | 디스크 고갈 및 복구 시간 악화 리스크 | `services/trading-core/src/outbox.rs`, `services/trading-core/src/wal.rs` | 보존/압축/오브젝트 아카이브 정책 추가 |

### 1.2 2차 정밀 점검에서 추가 확인된 블로커(코드 근거)

| 리스크 | 영향 | 코드 근거 | 보강 방향 |
|---|---|---|---|
| `GET /v1/balances`가 비관리자 경로에 존재하고 무인증 | 계정 전체 잔고 노출(데이터 유출) | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/LedgerController.kt` (`@GetMapping("/balances")`) | 관리자 전용 경로로 이동 + 강제 인증/인가 + 테넌시 스코프 |
| settlement consumer pause 시 메시지 skip 후 return | pause 구간 레코드 유실/offset 커밋 가능성 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/KafkaTradeConsumer.kt` (`settlementGate.isPaused()`) | pause 동안 ack 금지/재처리 보장, resume catch-up 테스트 고정 |
| Edge Kafka consumer가 `StartOffset=LastOffset` | 재기동 중 발생 체결의 UI/캐시 누락 가능 | `services/edge-gateway/internal/gateway/server.go` (`startTradeConsumer`) | committed offset 기반 재개 + 부팅 snapshot 동기화 + gap 알림 |
| 주문 취소 권한/존재 확인이 Edge 메모리 주문맵에 의존 | Edge 재기동/다중 레플리카 환경에서 정상 주문도 `UNKNOWN_ORDER`로 오탐될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`handleCancelOrder`, `s.state.orders`) | cancel auth/source-of-truth를 core/ledger 영속 조회로 전환 |
| Edge HTTP 서버 기본 `ListenAndServe` 사용 | read/write timeout 부재로 slowloris/리소스 고갈 위험 | `services/edge-gateway/internal/gateway/server.go` (`ListenAndServe`) | 커스텀 `http.Server` timeout/max header/body limit 적용 |
| 내부 통신이 평문 gRPC/OTLP | 내부망 침해 시 명령 위변조/도청 위험 | `services/edge-gateway/internal/gateway/server.go`, `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/SymbolModeSwitcher.kt` | gRPC mTLS + OTLP TLS 기본값 강제 |
| 이벤트 수치 파싱 오류를 0으로 묵살 | 잘못된 payload가 조용히 0 금액으로 처리될 수 있음 | `services/trading-core/src/kafka.rs` (`parse_i64`), `services/edge-gateway/internal/gateway/server.go` (`parseInt64Any`) | strict parse + schema validation + 실패 시 격리/재시도 |
| 웹 세션 토큰을 평문 저장/반환 | 세션 탈취 시 lateral movement 대응 취약 | `services/edge-gateway/internal/gateway/server.go` (`createSession`, `getSession`) | 세션 토큰 해시 저장 + refresh rotation + 로그인 잠금 정책 |
| 운영 기본값이 insecure DSN/OTLP insecure | 설정 실수로 평문/기본계정 운영 위험 | `services/edge-gateway/cmd/edge-gateway/main.go`, `services/ledger-service/src/main/resources/application.yml` | 프로덕션 profile에서 기본값 금지 + 부팅 fail-closed |
| Core idempotency 키가 `(symbol, idempotency_key)`만 사용 | 다른 사용자 요청 간 idempotency 충돌/응답 오염 가능 | `services/trading-core/src/engine.rs` (`self.idempotency.get((symbol, idempotency_key))`) | user_id+command_type+route 범위 포함 및 영속 저장 |
| Core cancel 시 주문 소유자 검증 없음 | 내부 경로로 타인 주문 취소 가능 | `services/trading-core/src/engine.rs` (`cancel_order`에서 `order.user_id` 검증 부재) | core에서 owner/authz 강제 + 감사로그 |
| Edge orderId가 `ord_<Idempotency-Key>` | 예측 가능/충돌 가능(order hijack, cross-user 충돌) | `services/edge-gateway/internal/gateway/server.go` (`orderID := fmt.Sprintf("ord_%s", idemKey)`) | 난수 UUID 기반 order_id 생성 + idempotency와 분리 |
| Edge 정산 반영 로직이 음수 잔고를 0으로 clamp | 자산 차감 실패 시 표시 잔고가 과대(사실상 mint)될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`settleBuyerLocked`, `settleSellerLocked`) | Ledger SoT projection으로 교체, clamp 제거 |
| Edge 메모리 맵(replay/rate/cache/history)이 키 cardinality 무제한 | 고카디널리티 입력 시 메모리 고갈/latency 악화 | `services/edge-gateway/internal/gateway/server.go` (`replayCache`, `rateWindow`, `cacheMemory`, `historyBySymbol`) | symbol allowlist + map 상한 + eviction/quotas |
| Safety-case 스크립트가 invariants/reconciliation/chaos 증거를 포함하지 않음 | 릴리즈 게이트가 “돈 안 깨짐”을 충분히 증명 못함 | `scripts/safety_case.sh` (load/dr 위주) | safety-case에 invariants/recon/chaos/offset/state-hash 필수화 |
| 운영 RBAC에 secrets create/update/delete 권한이 광범위 | 운영자 계정 탈취 시 비밀정보 확산 위험 | `infra/k8s/base/rbac.yaml` (`exchange-ops-admin`) | least-privilege RBAC + break-glass 분리권한 적용 |
| Core가 중복 `order_id`를 거부하지 않음 | 주문장 큐/맵 불일치, 타 주문 덮어쓰기, 체결 무결성 손상 위험 | `services/trading-core/src/engine.rs` (`place_order`), `services/trading-core/src/orderbook.rs` (`orders.insert`) | core에서 `order_id` 전역 유일성 강제 및 중복 거부 |
| correction 요청이 원본 entry 존재 여부를 사전검증하지 않음 | 승인/적용 파이프라인에 유령 요청 적재, 운영 혼선/오용 위험 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`createCorrectionRequest`, `reverseEntry`) | 생성 시 원본 존재/상태 검증 + 표준 오류코드 |
| `settlement_idempotency` 테이블이 선언만 되고 실사용되지 않음 | 장애 시 exactly-once 효과 증빙/운영가시성 저하 | `services/ledger-service/src/main/resources/db/migration/V1__ledger_schema.sql` (`settlement_idempotency`) | processed-events 전략 단일화 및 실제 write/read 경로 연결 |
| core가 주문은 내구화했지만 publish 실패 시 gRPC 에러 반환 | edge가 reserve를 되돌려 자산/주문 상태 불일치 가능 | `services/trading-core/src/bin/trading-core.rs` (`place_order` + `publish_pending`), `services/edge-gateway/internal/gateway/server.go` (`PlaceOrder` 에러 시 `releaseReserve`) | indeterminate 결과 처리(조회/보류) + reserve 보전 정책 |
| outbox publish가 `place_order` 경로에서만 수행 | cancel/set-mode/cancel-all 이벤트 전파 지연/누락 가능 | `services/trading-core/src/bin/trading-core.rs` (`cancel_order`, `set_symbol_mode`, `cancel_all`) | 공통 publish dispatcher(주기적 flush) + 모든 mutating RPC 후 publish |
| idempotency가 요청 payload fingerprint를 검증하지 않음 | 같은 key로 다른 요청을 보내도 기존 응답 재사용(감사/안전성 저하) | `services/edge-gateway/internal/gateway/server.go` (`idempotencyGet/Set`), `services/trading-core/src/engine.rs` | idem key + payload hash 결합, mismatch 시 `409 IDEMPOTENCY_CONFLICT` |
| Bearer session 경로가 HMAC 경로 대비 rate/replay 보호가 약함 | 세션 탈취 시 주문 남용/폭주 방어 약화 | `services/edge-gateway/internal/gateway/server.go` (`authMiddleware` session 우선 분기) | session 경로에도 동일 수준 rate/replay/device guard 적용 |
| correction 승인 플로우가 read-modify-write 경합에 취약 | 동시 승인 시 상태 꼬임(승인 누락/재승인 요구) 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`approveCorrection`) | row lock/optimistic version으로 원자적 승인 전이 보장 |
| correction apply가 envelope를 요청 본문에서 수용 | 감사 메타데이터 위조/오염 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/Dto.kt` (`ApplyCorrectionDto`) | 서버가 correlation/causation/timestamp를 서명·발급 |
| reconciliation이 latest seq 차이만 보고 중간 hole을 탐지하지 않음 | 일부 구간 누락이 lag=0으로 가려져 무정지 오류 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`updateEngineSeq/updateSettledSeq`) | 연속성 검사(최종 seq + hole scan) 및 mismatch 사유 세분화 |
| ledger write-path에서 고객계정 음수를 사전 차단하지 않음 | invariant는 사후 탐지라 사고 시점 차단 실패 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`applyBalanceDelta`) | 계정종류별 음수 허용정책 + 트랜잭션 선차단 |
| WS 연결 수용제어(글로벌/IP별 상한)가 없음 | 느린 소비자 외에도 연결 폭주로 프로세스 메모리/FD 고갈 가능 | `services/edge-gateway/internal/gateway/server.go` (`handleWS`) | connection admission control + per-IP quota + close code 표준화 |
| Kafka producer 내구 설정 부족(`acks=all`, `enable.idempotence`) | 브로커 장애/재시도 상황에서 이벤트 유실·중복 위험 증가 | `services/trading-core/src/kafka.rs` (`ClientConfig`) | production durability profile(acks=all/idempotence/in-flight 제한) 적용 |
| core `set_symbol_mode`/`cancel_all`이 meta 파싱 실패 시 기본값으로 진행 | 잘못된/누락 메타 요청이 fail-open으로 처리되어 감사 추적 무력화 | `services/trading-core/src/engine.rs` (`set_symbol_mode`, `cancel_all`, `from_proto_meta(...).unwrap_or(...)`) | admin 명령도 meta 검증 실패 시 즉시 reject(fail-closed) |
| `set_symbol_mode`가 잘못된 mode 값을 `NORMAL`로 강등 | 잘못된 요청이 의도치 않게 정상모드 전환을 유발할 수 있음 | `services/trading-core/src/engine.rs` (`to_symbol_mode(req.mode).unwrap_or(SymbolMode::Normal)`) | invalid mode는 reject + 에러코드 표준화 |
| `cancel_order`/`set_symbol_mode`/`cancel_all`에 리더 fencing 검증이 없음 | stale 인스턴스가 상태 변경을 수용해 split-brain 시나리오 위험 증가 | `services/trading-core/src/engine.rs` (`is_leader_valid`는 `place_order`에서만 사용) | 모든 mutating 명령에 fencing 검증 강제 |
| `cancel_order`/`set_symbol_mode`/`cancel_all`에 symbol 스코프 검증이 없음 | 교차 symbol 메타 오염/감사 불일치 가능 | `services/trading-core/src/engine.rs` (non-place 명령) | `meta.symbol == cfg.symbol` 강제, 불일치 reject + audit |
| WS ping/pong/read deadline 부재 | zombie connection 누적으로 connection/FD가 장시간 회수되지 않을 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`wsWriter`, `wsReader`) | heartbeat + idle timeout + pong 처리 표준화 |
| WS 구독 수(cardinality) 상한이 없음 | 악의적 SUB 폭주 시 per-conn subscriber map 메모리 고갈 위험 | `services/edge-gateway/internal/gateway/server.go` (`upsertSubscription`, `parseWSSubscription`) | per-conn subscription limit + 심볼 allowlist + 초과 시 close/reject |
| core admin 명령(`set_symbol_mode`, `cancel_all`) idempotency 처리 부재 | retry/timeout 시 중복 상태 변경 기록이 누적되어 운영 판단 오염 | `services/trading-core/src/engine.rs` (`set_symbol_mode`, `cancel_all`) | admin 명령 idempotency 저장/재응답 정책 도입 |
| Kafka consumer가 parse 예외를 그대로 재던지고 DLT 격리가 없음 | poison 메시지 1건으로 settlement/reconciliation 소비가 정지될 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/KafkaTradeConsumer.kt`, `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/KafkaReconciliationObserver.kt` | listener error handler + DLT quarantine + 재처리 runbook 고정 |
| core WAL/Outbox 기본 경로가 `/tmp`로 fail-open | 설정 누락 시 노드 재기동/교체에서 거래내역·publish cursor 내구성 상실 위험 | `services/trading-core/src/bin/trading-core.rs` (`CORE_WAL_DIR`, `CORE_OUTBOX_DIR` 기본값) | prod 부팅가드(영속 볼륨 경로 필수) + writable/fsync self-check |
| edge trade consumer가 처리 실패 메시지를 로그만 남기고 넘어감 | 체결 반영 누락/시장데이터 갭이 자동 복구되지 않고 영구 누락될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`startTradeConsumer`, `consumeTradeMessage`) | retry/DLQ/gap-marker 도입 + 누락 탐지 알람 |
| edge `appliedTrades` 중복방지가 메모리 맵 기반 | 재시작/스케일아웃 시 동일 trade 재적용으로 잔고/테이프 중복 반영 가능 | `services/edge-gateway/internal/gateway/server.go` (`markTradeApplied`, `state.appliedTrades`) | durable dedupe store(ledger seq/trade_id)로 이관 |
| reconciliation 안전모드 전환 실패 시 자동 재시도 경로가 없음 | 첫 전환 실패 후 breachActive만 남아 장시간 무조치 상태가 될 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`runReconciliationEvaluation`) | breach 지속 + last_action_failed 조건에서 재시도 backoff 추가 |
| reconciliation이 데이터 신선도(staleness) 임계치를 평가하지 않음 | observer/consumer 정지 시 lag가 정체되어도 안전모드 전환이 누락될 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`reconciliationAll`, `runReconciliationEvaluation`) | `updated_at` 기반 freshness breach 규칙 추가 |
| core idempotency TTL이 client 제공 `ts_server_ms`를 신뢰 | 미래/과거 timestamp 주입으로 replay 보호 창이 왜곡될 수 있음 | `services/trading-core/src/model.rs` (`from_proto_meta`), `services/trading-core/src/engine.rs` (`store_idempotent_*`, `prune_idempotency`) | server-receive timestamp로 TTL 계산 + skew 초과 reject |
| edge 지갑 조회/예약에서 wallet 미존재 시 기본자산을 자동 주입 | 미등록 사용자/키에서도 잔고가 생성되어 자산통제가 붕괴될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`snapshotWallet`, `applyReserve`, `defaultWalletBalances`) | 미존재 계정은 fail-closed + 계정 생성 경로만 자산 초기화 허용 |
| core gRPC가 무인증/평문 + `0.0.0.0` 바인딩 기본 | 내부망 노출 시 임의 주문/모드변경 호출 위험 | `services/trading-core/src/bin/trading-core.rs` (`Server::builder`, `CORE_GRPC_ADDR`) | mTLS + service identity + private bind guard(프로덕션) |
| edge에서 `trade_id` 중복마킹이 실제 반영보다 먼저 수행 | 중간 실패 시 이벤트가 영구적으로 스킵되어 잔고/체결테이프 불일치가 고착될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`consumeTradeMessage`, `markTradeApplied`) | 반영 완료 후 dedupe commit(2-phase) + 실패 시 재처리 가능 구조 |
| edge 지갑 DB 영속화 오류가 호출부에서 무시됨 | 메모리 상태와 DB 상태가 조용히 분기되어 재시작 후 잔고 불일치 가능 | `services/edge-gateway/internal/gateway/server.go` (`applyReserve`, `releaseReserve`, `applyTradeSettlement`, `persistWalletBalance`) | persist 실패를 즉시 실패처리/재시도 큐로 승격, 분기 감지 알람 |
| core Kafka sink가 TradeExecuted 외 이벤트를 버림 | cancel/mode/checkpoint 계열 이벤트의 외부 재현·감사·동기화가 불완전 | `services/trading-core/src/kafka.rs` (`EventSink::publish`) | 이벤트 타입별 canonical topic 분리 발행 + schema compatibility gate |
| outbox cursor 파싱 실패 시 `0`으로 복구(fail-open) | cursor 손상 시 과거 이벤트 대량 재발행(replay storm) 위험 | `services/trading-core/src/outbox.rs` (`last_published_seq`) | cursor checksum/format 검증 + 손상 시 fail-closed 및 복구 runbook |
| trade payload에 seq가 없으면 현재시간으로 대체 | event ordering/연속성 검증이 무력화되어 gap 탐지가 왜곡될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`consumeTradeMessage`) | seq 필수화(없으면 reject/DLQ) + 보정 금지 |
| chaos/smoke 스크립트가 `CORE_STUB_TRADES=true`, `EDGE_API_SECRETS=\"\"`로 실행 | 안전게이트 통과가 production-like 보안/설정 조건을 충분히 증명하지 못함 | `scripts/chaos_replay.sh`, `scripts/smoke_reconciliation_safety.sh` | hardened profile(실인증/비-stub) 드릴을 병행하고 둘 다 합격조건에 포함 |
| core가 신규 사용자에 데모 잔고를 자동 부여 | 미등록 주체에도 주문 가능 상태가 생겨 자산 통제 모델이 붕괴할 수 있음 | `services/trading-core/src/engine.rs` (`bootstrap_user_balances`) | prod에서 auto-credit 코드 제거, 계정/잔고는 외부 SoT에서만 주입 |
| edge `readyz`가 core/consumer 상태를 반영하지 않음 | core 장애·consumer 정지 상황에서도 트래픽 유입되어 오류율 급증 가능 | `services/edge-gateway/internal/gateway/server.go` (`handleReady`) | readiness에 core RPC health + trade consumer lag/stall 조건 포함 |
| ledger `readyz`가 DB만 확인하고 Kafka consumer 상태를 보지 않음 | settlement 정지 상태에서도 ready로 판정되어 장애 탐지/롤링복구가 지연될 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/LedgerController.kt` (`ready`) | readiness에 settlement/reconciliation consumer running/lag 조건 포함 |
| edge trade consumer가 `ReadMessage` 기반 auto-commit 소비 | 처리 실패에도 offset이 진행되어 이벤트 손실(재처리 불가) 가능 | `services/edge-gateway/internal/gateway/server.go` (`startTradeConsumer`) | fetch-then-commit 수동 커밋 모델로 전환 + 처리성공 후 commit |
| ledger 중복판정이 에러 메시지 문자열 매칭에 의존 | DB/드라이버 변경 시 duplicate 분류 오탐으로 소비정지/오동작 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`isUniqueViolation`) | SQLSTATE/에러코드 기반 판정으로 교체 |
| CI safety-case/load-smoke/dr-rehearsal가 rust-only 변경에선 실행되지 않음 | core 로직 변경이 핵심 안전게이트를 우회해 병합될 수 있음 | `.github/workflows/ci.yml` (`if` 조건에 rust 누락) | rust(core) 변경도 safety-case/chaos/load 게이트 필수 실행 |
| WS reader에 frame size/read limit가 없음 | 대형 프레임 입력으로 메모리/CPU 고갈 DoS 가능 | `services/edge-gateway/internal/gateway/server.go` (`wsReader`) | `SetReadLimit` + oversized frame close code 적용 |
| `/metrics`가 인증 없이 공개 라우트로 노출 | 내부 운영 지표/용량 정보가 외부에 노출될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`r.Get(\"/metrics\", ...)`) | metrics 접근을 scraper 전용 네트워크/인증으로 제한 |
| invariant negative-balance 검사가 계정종류를 구분하지 않음 | system/treasury 음수를 장애로 오탐해 불필요한 안전모드 전환 위험 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`invariantCheck`) | customer 계정과 system 계정의 허용 규칙 분리 |
| outbox 레코드 한 줄 손상이 전체 publish를 중단시킴 | 부분 손상 1건으로 후속 정상 이벤트 전파까지 정지될 수 있음 | `services/trading-core/src/outbox.rs` (`pending_records`, `publish_pending`) | 손상 레코드 격리/스킵 + 알람 + 복구도구 제공 |
| outbox cursor 업데이트가 원자적/내구적으로 기록되지 않음 | 크래시 타이밍에 cursor rollback되어 재발행 폭증 가능 | `services/trading-core/src/outbox.rs` (`set_last_published_seq`) | temp+fsync+rename 원자 갱신 및 checksum 검증 |
| settlement 적용과 `last_settled_seq` 갱신이 하나의 원자 트랜잭션이 아님 | ledger 반영은 됐지만 watermark 미갱신인 유령 lag가 남아 안전모드 오탐/지속 breach를 유발할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`consumeTrade`) | settlement append + settled seq update 원자화(동일 트랜잭션) |
| reconciliation 스케줄러가 멀티 레플리카에서 동시 실행됨 | history 중복 적재/중복 안전모드 호출/알람 폭증으로 운영 혼선 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/ReconciliationScheduler.kt` (`@Scheduled`) | 분산 lease 기반 single-runner 또는 leader election 강제 |
| `settlement_dlq`가 적재 전용이며 재처리/보존한도 제어가 없음 | 장애 장기화 시 DLQ 무한증가 + 미복구 누락 이벤트가 장기 방치될 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`appendDlq`) | DLQ replay 워커 + 보존기간/상한/알람 정책 도입 |
| WAL replay가 tail 중간 EOF를 복구 가능한 손상으로 취급하지 않음 | crash 직후 마지막 프레임 일부 손상 시 전체 재기동 실패 가능 | `services/trading-core/src/wal.rs` (`replay_all`) | truncated tail 자동 절단/격리 후 정상 프레임까지 복구 |
| WAL frame length 상한 검증이 없음 | 손상된 length header로 대용량 메모리 할당(OOM) 유발 가능 | `services/trading-core/src/wal.rs` (`let len = ...; vec![0_u8; len]`) | 최대 frame 크기 검증 + 초과 시 fail-closed/격리 |
| outbox pending scan이 전체 파일를 메모리로 적재 | backlog가 커질수록 publish 단계 메모리 급증/지연 악화 가능 | `services/trading-core/src/outbox.rs` (`pending_records`) | streaming iterator 기반 순차 발행(메모리 상한 고정) |
| edge가 부팅 시 운영 DB 스키마를 직접 생성 | 앱 버전별 스키마 드리프트/롤백 불가 상태가 생겨 변경통제 위반 가능 | `services/edge-gateway/internal/gateway/server.go` (`initSchema`) | 운영환경 DDL 금지 + 마이그레이션 파이프라인으로 일원화 |
| load harness가 무인증 주문/`/v1/smoke/trades` 주입에 의존 | 성능게이트가 fail-open/dev 전용 경로를 통과해도 production 적합성을 보장하지 못함 | `scripts/load-harness/main.go`, `scripts/load_smoke.sh` | 서명/세션 기반 실인증 부하경로 + 실체결 이벤트 소스로 전환 |
| 시세/호가 API가 `demo-derived-from-last-trade` fallback을 노출 | 실제 엔진 상태와 분리된 가짜 market data가 외부 노출될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`handleGetOrderbook`) | core canonical snapshot/delta 기반 데이터만 제공, demo fallback 제거 |
| core(u64)↔Kafka/ledger(i64) 수치 도메인 경계가 불명확 | overflow/범위초과 값이 parse fallback으로 왜곡되어 정산 오류 또는 DLQ 폭증 유발 가능 | `services/trading-core/src/model.rs`, `services/trading-core/src/kafka.rs`, `services/ledger-service/.../TradeExecutedDto` | 공통 정수 범위 계약(i64-safe) 강제 + 경계초과 요청 즉시 거부 |
| 결정성 state hash가 주문장 중심으로만 계산되어 리스크 상태를 누락 | 잔고/예약 상태가 달라도 동일 hash가 나와 crash-replay 증명이 위양성일 수 있음 | `services/trading-core/src/determinism.rs` (`state_hash`) | hash 입력에 risk snapshot/모드/핵심 파생상태 포함 |
| state hash 직렬화 실패 시 빈 바이트 해시로 fallback | 직렬화 오류가 동일 해시로 은닉되어 검증 신뢰성이 무너질 수 있음 | `services/trading-core/src/determinism.rs` (`serde_json::to_vec(...).unwrap_or_default()`) | 직렬화 실패 fail-closed + 오류 전파 |
| snapshot load가 무결성 검증 없이 JSON 파싱만 수행 | 손상/부분저장 스냅샷도 로드되어 잘못된 상태로 복구될 수 있음 | `services/trading-core/src/snapshot.rs` (`Snapshot::load`) | checksum/state-hash 검증 실패 시 복구 거부 |
| snapshot save가 fsync 없이 rename만 수행 | 크래시 시 파일/디렉터리 메타데이터 미flush로 스냅샷 유실 가능 | `services/trading-core/src/snapshot.rs` (`Snapshot::save`) | 파일+디렉터리 fsync 포함 원자 저장 프로토콜 |
| FOK 주문이 부분체결 후 취소되는 경로를 허용 | FOK의 all-or-none 규칙 위반으로 주문 의미/고객 기대가 깨질 수 있음 | `services/trading-core/src/engine.rs` (`place_order` tif 처리) | FOK는 사전 충족성 검사 후 전량 가능할 때만 체결 |
| core 재기동 시 outbox pending이 자동 발행되지 않음 | 재기동 직전 이벤트가 후속 주문 없으면 영구 미전파될 수 있음 | `services/trading-core/src/bin/trading-core.rs` (`main`) | startup 시 outbox backlog flush 워커 실행/완료 보장 |
| ledger double-entry 검증이 `Long` 합산 overflow를 고려하지 않음 | 초대형 수치 입력 시 합산 overflow로 불균형 entry가 통과할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`isDoubleEntry`) | `Math.addExact` 기반 overflow-safe 합산 및 실패 차단 |
| reconciliation 핵심 gap metric이 음수를 0으로 clamp | mismatch(ledger seq ahead) 상황이 메트릭에서 은닉되어 경보/대시보드 해석이 왜곡될 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerMetrics.kt` (`setReconciliation`) | signed gap/mismatch 전용 gauge 분리 |
| user/account 식별자가 `account_id` 문자열에 직접 결합됨 | 구분자(`:`) 포함 ID로 계정종류 파싱 오염 및 계정격리 위반 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`userAccount`, `ensureAccount`) | principal ID 문자셋/정규화 강제 + 안전한 키 인코딩 |
| invariant scheduler가 위반 시 로그만 남기고 자동격리를 하지 않음 | 명백한 정합성 위반에서도 거래/출금 제한이 지연되어 손실 확산 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/InvariantScheduler.kt` | 위반 시 safety latch 전환 + 증거 번들 자동 생성 |
| settlement DLQ payload가 축약 문자열(`trade_id,symbol,seq`)만 저장됨 | 장애 사후 재처리/감사 재현 시 원본 이벤트 복구가 불가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`tradePayload`) | DLQ에 원본 payload+headers+error class를 구조화 저장 |
| ledger DTO가 `ignoreUnknown=true`로 스키마 드리프트를 묵살 | 잘못된/오염된 이벤트가 경고 없이 수용되어 계약 위반 탐지가 늦어짐 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/Dto.kt` | strict decode(unknown field reject) + 스키마 버전 불일치 격리 |
| safety mode 문자열 파싱이 invalid 입력을 `CANCEL_ONLY`로 강등 | 설정 오타/오염이 감춰져 의도와 다른 안전정책으로 동작할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/Models.kt` (`SafetyMode.parse`) | 부팅 시 안전모드 설정값 강제 검증(fail-closed) |
| outbox record 내 다중 이벤트 발행 중간 실패 시 선발행 이벤트가 재발행될 수 있음 | per-record cursor 모델로 동일 이벤트 중복 발행이 반복되어 downstream 부하/오탐 증가 | `services/trading-core/src/outbox.rs` (`publish_pending`) | per-event publish checkpoint 또는 transactional publish 도입 |
| management/actuator 노출이 광범위(health/info/prometheus/metrics + 별도 `/metrics`) | 운영 내부 정보가 비인가 경로로 노출될 가능성 | `services/ledger-service/src/main/resources/application.yml`, `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/LedgerController.kt` | actuator/metrics 경로를 내부 인증 프록시 뒤로 제한 |
| 서비스어카운트 토큰 자동마운트 기본값 사용 | 워크로드 탈취 시 토큰 획득을 통한 권한 확장이 쉬워질 수 있음 | `infra/k8s/base/serviceaccounts.yaml` | `automountServiceAccountToken: false` 기본 + 필요한 Pod만 예외 허용 |
| observability ingress 네트워크정책이 다수 포트를 일괄 허용 | 메트릭 수집 경로를 통해 비의도 포트 접근면이 넓어질 수 있음 | `infra/k8s/base/networkpolicies.yaml` (`allow-ingress-observability`) | 서비스별 메트릭 포트만 최소허용하는 정책으로 세분화 |
| reconciliation/invariant 감시 대상이 `reconciliation_state` 존재 심볼에 한정 | 신규/휴면 심볼이 감시 대상에서 누락되어 블라인드 스팟이 발생할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`reconciliationAll`) | 상장 심볼 레지스트리 기반으로 감시 커버리지 강제 |
| core WAL replay가 수치 파싱 실패를 `0`으로 대체 | 손상 이벤트가 조용히 누락 반영되어 복구 결정성/정확성 증명이 위양성일 수 있음 | `services/trading-core/src/engine.rs` (`apply_replay_event`) | replay decode strict 모드 도입, 파싱 실패 시 fail-closed + 격리 |
| core/edge 체결 금액 계산이 overflow를 명시적으로 차단하지 않음 | 대형 입력에서 overflow/포화 연산으로 잘못된 잔고·체결 집계가 누적될 수 있음 | `services/trading-core/src/engine.rs` (`quote_amount`), `services/trading-core/src/risk.rs` (`saturating_mul`), `services/edge-gateway/internal/gateway/server.go` (`price*qty`, `quoteVolume`) | multiply/add exact 검사 + overflow 시 요청 거부/DLQ |
| WS candles 구독 interval이 자유문자열 허용 | 악의적 interval 다양화로 구독키/컨플레이션 키 카디널리티 폭증 가능 | `services/edge-gateway/internal/gateway/server.go` (`parseWSSubscription`) | interval allowlist + 정규화 + 초과 입력 거부 |
| ledger Kafka listener가 명시적 수동 ack/에러 핸들러 없이 기본동작 의존 | 프레임워크/버전 변경 시 commit 시점이 바뀌어 pause/retry 의미가 흔들릴 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/KafkaTradeConsumer.kt`, `services/ledger-service/src/main/resources/application.yml` | manual ack mode + DLT/error handler를 코드/설정으로 고정 |
| `chaos_replay.sh`가 재기동 후 “라이브 상태 해시”를 검증하지 않음 | WAL 마지막 레코드 해시만 같아도 실제 복구 상태 불일치를 놓칠 수 있음 | `scripts/chaos_replay.sh` (`wal_last_meta`) | core state-hash 조회 엔드포인트/CLI 추가 후 pre/post live hash 비교 |
| `safety_case.sh`에 MinIO 접근키가 하드코딩됨 | 스크립트 유출/오용 시 아카이브 저장소 접근권한 노출 위험 | `scripts/safety_case.sh` (`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`) | 시크릿은 환경변수/시크릿매니저 주입으로만 허용 |
| core가 주문 로그에 `user_id`를 평문 출력 | 운영 로그 수집 경로에서 PII/식별자 노출 가능 | `services/trading-core/src/bin/trading-core.rs` (`eprintln!`) | 로그 최소화/마스킹/구조화 필드 정책 적용 |
| WAL 복구 시 record symbol이 core symbol과 일치하는지 검증하지 않음 | 잘못된 WAL 경로/교차 심볼 데이터 혼입 시 오염 상태로 부팅될 수 있음 | `services/trading-core/src/engine.rs` (`recover_from_wal`) | record.symbol 바인딩 검증, 불일치 시 fail-closed |
| WAL 복구가 record.state_hash를 신뢰하고 재계산 검증을 하지 않음 | 변조된 WAL이 정상 복구처럼 보이는 무결성 위양성 가능 | `services/trading-core/src/engine.rs` (`recover_from_wal`) | replay 중 상태 해시 재계산/대조, 불일치 시 복구 중단 |
| WAL 복구가 `fencing_token` 연속성을 검증하지 않음 | split-brain stale writer 레코드가 섞여도 탐지 없이 반영될 수 있음 | `services/trading-core/src/engine.rs`, `services/trading-core/src/wal.rs` | fencing token monotonic/lease epoch 검증 추가 |
| WAL replay가 전체 레코드를 메모리에 적재 | 장기간 운영 후 재기동에서 메모리 급증/OOM으로 복구 실패 가능 | `services/trading-core/src/wal.rs` (`replay_all`) | streaming replay iterator로 변경 + 메모리 상한 검증 |
| snapshot 포맷에 symbol/schema version 바인딩이 없음 | 다른 심볼/구버전 스냅샷 오적용을 사전에 차단할 수 없음 | `services/trading-core/src/snapshot.rs` (`Snapshot`) | snapshot metadata에 symbol/version/checksum 포함 및 로드시 검증 |
| auth 서명 검증이 본문 전체를 무제한으로 읽고 복제 | 대형 요청으로 메모리 증폭 DoS 가능 | `services/edge-gateway/internal/gateway/server.go` (`readBodyAndRestore`, `authMiddleware`) | MaxBytesReader + 본문 크기 상한 + 스트리밍 canonicalization |
| `Idempotency-Key`에 길이/문자셋 제한이 없음 | 비정상 키 폭주로 메모리/스토리지 키카디널리티 공격 가능 | `services/edge-gateway/internal/gateway/server.go` (`handleCreateOrder`, `handleCancelOrder`) | 키 길이/문자셋 정책 강제 + 초과 요청 거부 |
| 체결 이벤트의 `quoteAmount`를 edge/ledger 모두 신뢰함 | `price*qty`와 불일치한 payload가 들어오면 정산 금액 왜곡/자산 불일치가 누적될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`consumeTradeMessage`), `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`tradeToEntry`) | quoteAmount 일치 검증(또는 authoritative 재계산) 강제, 불일치 시 격리/DLQ |
| 숫자 파서가 부동소수 입력을 정수로 절삭(truncate) 수용 | `1.9 -> 1` 같은 묵시 변환으로 체결 수량/가격 왜곡이 조용히 발생할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`parseInt64Any`) | 정수 전용 파서/스키마로 강제, decimal 입력은 즉시 거부 |
| 지갑 로드 실패 시 DB 오류를 빈 지갑으로 처리 후 기본자산 시드로 강등 | 저장소 장애 순간에 사용자 잔고가 시드값으로 대체되어 자산 통제가 붕괴할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`loadWalletFromDB`, `snapshotWallet`) | DB read/scan 실패는 fail-closed, 기본시드는 테스트/명시적 생성 경로로만 허용 |
| reconciliation upsert/update가 unique 충돌 시 재귀 호출로 재시도 | 경합이 지속되면 스택 증가/지연 폭증으로 guard path 자체가 불안정해질 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`updateEngineSeq`, `updateSettledSeq`, `upsertReconciliationSafetyState`) | bounded loop 재시도 + backoff/jitter + 실패 메트릭/알람 |
| WAL/Outbox 경로에 프로세스 간 단일 writer 파일락이 없음 | 동일 볼륨에 2개 core가 뜨면 local split-brain으로 로그/커서가 오염될 수 있음 | `services/trading-core/src/wal.rs` (`Wal::open`), `services/trading-core/src/outbox.rs` (`Outbox::open`) | startup 시 WAL/outbox lock 획득 강제, 충돌 시 부팅 실패 |
| settlement 예외 처리 중 DLQ 적재 실패를 별도 격리하지 않음 | 원인 이벤트/오류 증거를 잃은 채 consumer 재시도 루프가 불안정해질 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`consumeTrade`) | DLQ write 실패 전용 카운터/알람 + quarantine 경로 + 커밋 정책 명시화 |
| 안전 핵심 플래그 기본값이 fail-open (`ledger.kafka.enabled=false`, auto-switch off 시 noop) | 운영 설정 실수로 settlement/자동 안전모드가 비활성인 상태로 서비스가 ready 판정될 수 있음 | `services/ledger-service/src/main/resources/application.yml`, `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/SymbolModeSwitcher.kt` | 프로덕션 프로파일에서 safety-critical 플래그 부팅가드 + readiness 연동 |
| core WAL/snapshot tail replay가 risk/reservation 상태를 재구성하지 않음 | 재기동 후 주문장은 복구돼도 리스크 상태가 초기화되어 주문 허용량/hold가 왜곡될 수 있음 | `services/trading-core/src/engine.rs` (`recover_from_wal`, `recover_from_snapshot`, `apply_replay_event`) | replay 이벤트로 risk 상태까지 결정론적으로 재구성하거나 risk snapshot+tail apply를 완전복구 |
| core 부팅 경로가 snapshot을 사용하지 않고 항상 full WAL replay 수행 | WAL 장기화 시 복구시간 SLO를 만족하기 어렵고 snapshot 운영정책이 실효성이 없음 | `services/trading-core/src/engine.rs` (`TradingCore::new`) | snapshot-first 부팅(최신 snapshot + WAL tail) 경로를 기본화하고 fallback/검증 규칙 명시 |
| reconciliation 조회 경로가 요약 메트릭을 덮어써 breach 수치를 0으로 재설정할 수 있음 | 관측 대시보드가 실제 breach 상태와 불일치해 운영자가 오판할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`reconciliationAll`) | 평가잡 전용 메트릭 갱신으로 분리, read path에서 summary 메트릭 mutate 금지 |
| core place_order가 요청 경로에서 동기 publish flush를 수행 | Kafka 지연/브로커 이슈 시 주문 RPC latency 급등으로 cancel-only/halt 명령 반응이 늦어질 수 있음 | `services/trading-core/src/bin/trading-core.rs` (`place_order` + `publish_pending`) | outbox publisher를 비동기 워커로 분리, 요청 경로 lock hold/flush budget 강제 |
| infra/gitops 검증 스크립트가 `kubectl` 부재·클러스터 미접속 시 `skipped`로 성공 종료 | CI 환경 차이에서 인프라 검증이 fail-open 되어 깨진 매니페스트가 릴리즈될 수 있음 | `scripts/validate_infra.sh`, `scripts/k8s_policy_smoke.sh`, `scripts/gitops_dry_run.sh` | CI 보호 경로에서는 도구/클러스터 부재를 실패로 처리하고 명시적 로컬모드에서만 skip 허용 |
| K8s/GitOps dry-run 검증이 `--validate=false`를 사용 | 스키마/필드 오류·정책 위반을 조기에 탐지하지 못하고 배포 단계로 전파될 수 있음 | `scripts/k8s_policy_smoke.sh`, `scripts/gitops_dry_run.sh` | server-side dry-run + schema 검증(kubeconform) + 정책 검증(conftest/kube-linter)로 강화 |
| JIT 접근 부여가 “YAML 생성”에 머물고 만료 자동회수 구현이 없음 | 만료된 고권한 ClusterRoleBinding이 잔존해 운영자 권한이 장기 확장될 수 있음 | `scripts/jit_access_grant.sh`, `infra/security/ACCESS_CONTROL.md` | JIT grant apply/revoke 자동화(컨트롤러/크론) + 만료 grant 0건 SLO + 감사메트릭 |
| Argo AppProject가 리소스/네임스페이스 wildcard 허용 | GitOps 오작동/권한오남용 시 클러스터 전역 blast radius가 과도함 | `infra/gitops/argocd/project-exchange.yaml` (`clusterResourceWhitelist: *`, `namespaceResourceWhitelist: *`) | AppProject whitelist를 최소권한 그룹/리소스로 축소하고 금지규칙 테스트 추가 |
| load harness가 주문 성공을 HTTP 2xx만으로 집계하고 WS read 실패를 누락 집계 | 성능/안정성 게이트가 실제 도메인 실패를 놓쳐 위양성(pass)을 만들 수 있음 | `scripts/load-harness/main.go` (`resp.StatusCode` 기반 성공판정, `ReadMessage` 에러 경로) | 주문 도메인 상태 기준 판정 + WS 실패 카운팅 정합성 보강 |
| edge trade consume 실패 로그가 원본 payload를 그대로 출력 | 민감 식별자/비정상 대형 payload가 로그 저장소로 유출되어 보안·운영 비용 위험 증가 | `services/edge-gateway/internal/gateway/server.go` (`trade_apply_failed ... payload=%s`) | payload 원문 로그 금지, trade_id/hash 등 최소 식별자만 구조화 로깅 |
| CI workflow 액션이 버전 태그(`@v4`, `@v5`) 기준으로 고정됨 | 서드파티 액션 공급망 변조 시 동일 태그 재해석 위험을 방어하기 어려움 | `.github/workflows/ci.yml` | GitHub Actions를 commit SHA로 pin하고 정적 정책게이트로 미핀 액션 차단 |
| signup/login 엔드포인트가 인증 미들웨어 바깥에 있고 별도 시도 제한이 없음 | 자격증명 스터핑/브루트포스에 노출되어 계정 탈취 위험이 높아짐 | `services/edge-gateway/internal/gateway/server.go` (`/v1/auth/signup`, `/v1/auth/login`, `handleLogin`) | IP+계정 기반 rate limit + lockout/backoff + 보안 알림 도입 |
| session 검증이 Redis 실패 시 프로세스 메모리 fallback을 허용 | 멀티레플리카에서 logout/revoke 전파가 깨져 세션 무효화 일관성이 무너질 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`getSession`, `sessionsMemory`) | 프로덕션에서 central session store 필수화 + fallback 금지 + revoke 전파 검증 |
| web-user가 session token을 `localStorage`에 저장 | XSS 발생 시 장기 세션 토큰 탈취 위험이 큼 | `web-user/src/App.tsx` (`localStorage.setItem`), `web-user/src/lib/api.ts` | HttpOnly/SameSite cookie 기반 세션으로 전환, 브라우저 저장소 토큰 제거 |
| K8s NetworkPolicy가 edge 서비스 트래픽 매트릭스를 완성하지 못함 | `default-deny` 환경에서 edge↔core/ledger/infra 통신이 차단되거나 임시 예외로 과개방될 위험 | `infra/k8s/base/networkpolicies.yaml` (`edge`는 `allow-dns` 외 egress 규칙 부재) | ingress/egress 허용경로를 서비스별 최소정책으로 명시하고 E2E 연결 테스트 고정 |
| `streaming/flink-jobs` 모듈에 Flink 런타임 의존/잡 토폴로지가 없음 | 캔들/티커를 운영 스트림에서 재현·복구할 실행체가 부재함 | `streaming/flink-jobs/build.gradle.kts`, `streaming/flink-jobs/src/main/java/com/quanta/exchange/streaming/CandleJob.java` | Kafka source/sink + checkpoint/watermark 포함 실제 Flink job 구현 및 배포 검증 |
| invariant scheduler가 전체 postings/balances를 주기 full scan | 거래량 증가 시 DB 부하 급증으로 감시 잡이 자체 장애를 유발할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/InvariantScheduler.kt`, `.../repo/LedgerRepository.kt` (`invariantCheck`) | 증분 스캔/샘플링/타임박스 + 장기 full-scan 분리, SLO 기반 실행 제어 |
| edge API가 내부 오류 문자열을 그대로 응답에 노출 | DB/Redis/내부 예외 메시지 노출로 공격자 정찰 비용이 낮아짐 | `services/edge-gateway/internal/gateway/server.go` (`writeJSON(... err.Error())`) | 외부 응답은 표준 오류코드만 반환, 상세는 구조화 내부로그로만 보관 |
| ledger reserve/release가 `side` 유효성 검증 없이 기본 분기를 사용 | 잘못된 side 입력이 다른 자산을 hold/release 하여 자산 정합성을 깨뜨릴 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`reserve`, `release`) | `BUY/SELL` enum 강제 + invalid side 즉시 거부 |
| ledger trade 입력이 핵심 식별자/주체 공백값을 사전 차단하지 않음 | 빈 `tradeId`/`buyerUserId`/`sellerUserId`가 계정키 오염·중복처리 왜곡을 유발할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/Dto.kt`, `.../core/LedgerService.kt` | internal DTO/서비스 경계에서 필수 필드 non-empty 검증 + 표준 오류코드 |
| `dr_rehearsal.sh`가 toy 데이터 seed 중심으로 동작 | 실제 장애 데이터(WAL/Kafka offset/snapshot) 복구 능력을 과대평가할 위험 | `scripts/dr_rehearsal.sh` (seed SQL 후 dump/restore) | 실제 snapshot/WAL/Kafka 범위를 복원하는 리허설로 전환 |
| `load_smoke.sh`가 edge 단독 부팅/환경 의존으로 비결정적 | 로컬 잔존 프로세스 유무에 따라 결과가 달라져 게이트 신뢰성이 저하됨 | `scripts/load_smoke.sh` | 격리된 full-stack(core+edge+ledger+kafka)에서만 실행되고 외부 의존이 0건 |
| compose/운영 스크립트 이미지가 digest가 아닌 mutable tag 의존 | 공급망 변조/재현성 저하로 동일 커밋 재현이 어려움 | `infra/compose/docker-compose.yml`, `scripts/safety_case.sh` (docker image tags) | 핵심 런타임/툴 이미지 digest pin + 미고정 이미지 게이트 차단 |
| ledger 안전핵심 플래그 간 결합관계 검증 부재 | `reconciliation` 활성 + observer 비활성 같은 조합이 거짓 breach/누락을 유발할 수 있음 | `services/ledger-service/src/main/resources/application.yml`, `.../ReconciliationScheduler.kt`, `.../KafkaReconciliationObserver.kt` | 부팅 시 플래그 조합 검증(fail-closed) + 유지보수 override 감사로그 필수 |
| edge 주요 POST API가 body 크기 상한/strict JSON decoder를 강제하지 않음 | 대형 body/unknown field 입력으로 메모리 DoS 및 계약 드리프트 유입 가능 | `services/edge-gateway/internal/gateway/server.go` (`json.NewDecoder` 경로 전반) | 전 엔드포인트 `MaxBytesReader + DisallowUnknownFields` 적용 |
| ledger `parseSymbol`이 대소문자 정규화를 수행하지 않음 | `btc-krw`/`BTC-KRW`가 별도 계정 축으로 분리되어 자산 대사 오차를 유발할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/Symbols.kt` | symbol/currency 대문자 정규화 + 비정규 입력 거부 |
| ledger account_id 구성에 사용자 식별자 raw 문자열을 직접 포함 | `:` 등 구분자 포함 식별자 주입 시 account_kind 파싱 오염/격리 위반 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`userAccount`) | principal ID 문자셋 정책 + 안전 인코딩/별도 컬럼 모델로 전환 |
| 회원가입/지갑조회 경로가 기본 자산 시드를 운영로직으로 사용 | 신규/비정상 계정에 무상 크레딧이 부여되어 자산통제가 붕괴할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`createUser`, `loadWalletFromDB`, `defaultWalletBalances`) | 운영환경 시드 완전 금지 + 계정생성/입금 기반 초기화만 허용 |
| `dr_rehearsal.sh`가 최신 migration 체인 대신 V1 스키마를 직접 적용 | 실제 운영 스키마 변화(V2+)를 복구 드릴이 검증하지 못해 위양성 리허설이 됨 | `scripts/dr_rehearsal.sh` (`V1__ledger_schema.sql` 직접 실행) | DR drill에서 app migration 전체 적용 + schema drift 검증 필수화 |
| `safety_case.sh`가 기존 리포트 파일 존재만 확인하고 freshness를 보장하지 않음 | 오래된 산출물 재사용으로 릴리즈 게이트가 허위 통과할 수 있음 | `scripts/safety_case.sh` (`LOAD_REPORT`/`DR_REPORT` 존재 체크만 수행) | 증거 타임스탬프/커밋 일치 검증 및 stale artifact 차단 |
| 주문 입력 수치 파싱이 `float64` + `ParseFloat` 기반이며 finite 검증이 없음 | `NaN/Inf` 입력이 reserve 계산을 통과해 지갑 상태를 비수치로 오염시킬 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`tryReserveForOrder`, `applyReserve`) | finite-only 검증(`math.IsNaN/IsInf`) + 정수 도메인 전환 전 임시 차단 |
| core risk의 `recent_commands/open_orders` 상태맵이 키 cardinality를 축소하지 않음 | 사용자/심볼 폭주 시 map 키가 영구 누적되어 메모리 사용량이 비가역 증가할 수 있음 | `services/trading-core/src/risk.rs` (`enforce_rate_limit`, `bump_open_order`) | empty/zero 키 제거 + 상한/GC 정책 + 메트릭/알람 |
| edge 런타임 상태맵(users/sessions/idempotency/wallets)이 전역 상한 없이 누적 | 대량 가입/세션/요청으로 프로세스 메모리 압박 및 GC 지연이 발생할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`state.*` map 전반) | map별 quota/LRU/TTL + over-cap 시 fail-closed 정책 |
| ledger `rebuildBalances()`가 live 테이블 `TRUNCATE` 후 재적재 | 재빌드 중 조회 공백/동시 write 경합으로 일시적 불일치 노출 가능 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`rebuildBalances`) | shadow table 재계산 + atomic swap + maintenance gate |
| `updateEngineSeq/updateSettledSeq` upsert 경합 처리에 재귀 재시도 사용 | 충돌 지속 시 스택 증가/무한 재시도로 consumer 안정성이 저하될 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`updateEngineSeq`, `updateSettledSeq`) | bounded loop retry + max-attempt 초과 시 격리/알람 |
| core `user_id`가 세션 userId와 API key id를 혼용 수용 | 식별자 도메인 충돌 시 권한/감사 주체가 혼재될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`authMiddleware`), `services/trading-core/src/model.rs` (`CommandMeta.user_id`) | principal namespace 분리(`user:*`, `apikey:*`) + 키→주체 매핑 강제 |
| web-user가 샘플 체결 API를 기본 UI 액션으로 노출 | 운영 빌드에서 debug 동작 노출 시 내부/외부 오용 표면이 유지될 수 있음 | `web-user/src/App.tsx` (`handleSeedTrade`), `web-user/src/lib/api.ts` (`postSmokeTrade`) | prod profile에서 UI/호출 경로 제거, dev-only feature flag 분리 |
| core gRPC 서버가 keepalive/메시지 크기/커넥션 제한을 설정하지 않음 | 비정상 연결/대형 메시지 입력으로 리소스 고갈 및 제어 명령 지연이 발생할 수 있음 | `services/trading-core/src/bin/trading-core.rs` (`Server::builder()`) | tonic 서버 limit/keepalive/timeouts 적용 + DoS 회귀테스트 고정 |
| 주문 체결 반영 시 `FilledQty/ReserveConsumed` 상한 검증이 없음 | 중복·비정상 fill 이벤트 유입 시 주문량 초과 반영/잔여 reserve 음수 왜곡이 가능 | `services/edge-gateway/internal/gateway/server.go` (`applyOrderFill`) | per-order fill bound 검증 + 초과 이벤트 격리/DLQ |
| 세션을 쿠키로 전환할 경우 CSRF 보호계층 정의가 없음 | 브라우저 기반 세션 모델에서 교차사이트 요청 위조 취약점이 발생할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (session 기반 인증 경로) | CSRF token/origin check + same-site 정책 + 회귀 테스트 |
| correction apply가 `reverseEntry`와 상태전환(`markCorrectionApplied`)을 분리 수행 | 중간 장애 시 `APPROVED` 상태가 남아 재시도/중복 적용 판단이 비결정적으로 흔들릴 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerService.kt` (`applyCorrection`) | reversal + status update 원자 트랜잭션 + 정확한 적용 시각/주체 기록 |
| Ledger 스키마가 CHECK/ENUM/FK 제약을 거의 강제하지 않음 | 잘못된 값(mode/status/amount<0/seq<0)이 DB에 유입되어 앱 검증 우회 시 손상 전파 가능 | `services/ledger-service/src/main/resources/db/migration/V1__ledger_schema.sql` | DB 제약 강화(CHECK/FK/enum domain) + 마이그레이션 검증 게이트 |
| GitOps 앱이 prod/staging/dev 모두 `targetRevision: main` 추적 | 승인 전 커밋이 운영 환경에 자동/반자동으로 전파될 위험이 있음 | `infra/gitops/apps/prod.yaml`, `infra/gitops/apps/staging.yaml`, `infra/gitops/argocd/root-app.yaml` | prod/staging immutable revision(tag/SHA) 고정 + 승인 승격 파이프라인 |
| 회원가입이 이메일 중복을 명시적으로 응답 | 계정 존재 여부 열거(enumeration)로 공격자 정찰 비용이 낮아짐 | `services/edge-gateway/internal/gateway/server.go` (`handleSignUp`) | signup/login 오류 응답 비식별화 + 탐지 알람/감사 |
| command/order/trade 식별자 문자열 길이/문자셋 상한이 전면 강제되지 않음 | 대형/비정상 식별자 입력으로 로그 오염·메모리 사용량 급증·저장소 비정상 확장이 가능 | `services/trading-core/src/model.rs`, `services/edge-gateway/internal/gateway/server.go`, `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/Dto.kt` | ID 필드 길이/charset 정책 통일 + 경계검증/DB 제약 동시 적용 |
| EventEnvelope `eventVersion`이 소비 경계에서 호환성 검증 없이 수용됨 | 미지원 버전 payload가 조용히 처리되어 정합성 오염 또는 재현 불가 상태를 만들 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/Dto.kt`, `services/edge-gateway/internal/gateway/server.go` | 허용 버전 allowlist + 버전 불일치 격리/DLQ + 메트릭 |
| 인증/세션 수명주기(signup/login/logout/session create) 감사 이벤트가 불충분 | 계정 탈취/내부자 오용 조사 시 행위 재구성이 어려워 규제 대응이 약해짐 | `services/edge-gateway/internal/gateway/server.go` (auth/session 경로 전반) | auth lifecycle audit 이벤트 표준화 + immutable 저장 + 조회 API |
| legacy smoke 스크립트가 무인증/stub 경로를 기본 사용 | 보안 회귀가 있어도 스모크가 통과하는 위양성 위험이 지속됨 | `scripts/smoke_e2e.sh`, `scripts/smoke_g0.sh`, `scripts/smoke_g3.sh` | hardened security profile 전용 스모크 추가 및 기존 스크립트 gate 분리 |
| `accounts.currency`와 `ledger_postings.currency` 일치가 DB 제약으로 강제되지 않음 | account ID 재사용/오염 입력 시 통화축이 섞여 잔고 정합성이 장기적으로 붕괴할 수 있음 | `services/ledger-service/src/main/resources/db/migration/V1__ledger_schema.sql`, `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`ensureAccount`) | `(account_id,currency)` 참조 무결성 제약 + 불일치 posting 차단 |
| WAL/Outbox replay가 시퀀스 연속성(증가/중복/역행)을 강제 검증하지 않음 | 손상·주입 데이터가 있어도 일부 케이스에서 재생이 진행되어 상태오염을 늦게 발견할 수 있음 | `services/trading-core/src/wal.rs`, `services/trading-core/src/outbox.rs` | replay 시 seq continuity 검증 + 위반 즉시 fail-closed/격리 |
| core가 validation reject를 WAL/audit 이벤트로 남기지 않는 경로가 존재 | 악성 주문 시도/우회 탐지 증거가 누락되어 사후 포렌식·규제 보고가 약화됨 | `services/trading-core/src/engine.rs` (`place_order`, `cancel_order` early reject 분기) | reject-path audit 이벤트를 append-only로 기록 |
| 사용자 보안통제(MFA/이메일 검증) 강제가 부재 | 계정 탈취 후 즉시 거래 가능해 ATO(계정탈취) 피해 확률이 높음 | `services/edge-gateway/internal/gateway/server.go` (`handleSignUp`, `handleLogin`) | 거래/출금 전 MFA+verified-email 정책 강제 |
| 로그인/회원가입 응답시간이 계정 상태에 따라 달라질 수 있음 | 메시지 비식별화 후에도 타이밍 채널로 계정 존재 추론 위험이 남음 | `services/edge-gateway/internal/gateway/server.go` (`handleSignUp`, `handleLogin`) | 인증 실패 경로 시간 균등화 + 지연 랜덤화 정책 |
| settlement DLQ payload가 TEXT 무제한 저장이고 크기 경계가 없음 | 비정상 대형 payload/에러폭주 시 DB 저장소 급팽창으로 2차 장애를 유발할 수 있음 | `services/ledger-service/src/main/resources/db/migration/V1__ledger_schema.sql` (`settlement_dlq.payload`), `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`appendDlq`) | payload size cap/hash+blob offload + 폭주 차단 정책 |
| Argo root app는 자동 동기화(`prune/selfHeal`)지만 prod 수동승인이 정책으로 강제되지 않음 | 운영자가 의도하지 않은 자동 동기화로 prod 변경이 반영될 위험이 존재 | `infra/gitops/argocd/root-app.yaml`, `infra/gitops/apps/prod.yaml` | prod sync window/manual approval 정책을 코드로 강제 |
| Kafka consumer commit/isolation 핵심옵션이 설정 파일에 명시 고정되지 않음 | 프레임워크 기본값/버전변경에 따라 commit 시점·가시성이 달라져 재처리 의미가 흔들릴 수 있음 | `services/ledger-service/src/main/resources/application.yml` | `enable-auto-commit=false`, ack mode, isolation level을 명시·검증 게이트 고정 |
| edge/ledger tracing 샘플링 기본값이 1.0이고 edge는 비정상 값에서도 1.0으로 강등 | 운영 트래픽 증가 시 tracing 오버헤드로 latency/cost 급등 위험이 fail-open으로 남음 | `services/edge-gateway/cmd/edge-gateway/main.go` (`EDGE_OTEL_SAMPLE_RATIO` 기본 1.0), `services/edge-gateway/internal/gateway/server.go` (`cfg.OTelSampleRatio <= 0 -> 1.0`), `services/ledger-service/src/main/resources/application.yml` (`LEDGER_OTEL_SAMPLE_PROB:1.0`) | 환경별 샘플링 상한/하한 정책 + fail-closed config 검증 + budget alert |
| core gRPC 서버가 종료 시그널 드레인 없이 `serve()` 단일 루프로 동작 | 배포/스케일인 중 in-flight 요청 및 outbox publish 경계에서 종료 일관성이 흔들릴 수 있음 | `services/trading-core/src/bin/trading-core.rs` (`Server::builder().serve(addr)`) | SIGTERM drain + graceful shutdown 훅 + 종료 직전 outbox flush 검증 |
| edge replay/rate/idempotency 상태가 프로세스 메모리 맵에만 존재 | 다중 레플리카에서 재시도/재전송 우회와 rate-limit 불일치가 발생해 보안 통제가 약화될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`idempotencyResults`, `rateWindow`, `replayCache`) | Redis(또는 동등 저장소) 원자연산 기반 공유 저장소로 일원화 |
| edge DB 연결이 풀 제한/수명/쿼리 timeout 정책 없이 열림 | DB 지연/잠금 상황에서 커넥션 고갈·요청 정체가 연쇄장애로 이어질 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`sql.Open` 후 pool 설정 부재, `context.Background()` DB 호출) | pool/budget 설정 + statement timeout + saturation 메트릭/알람 강제 |
| Redis 세션 저장소 연결에 TLS/ACL 강제가 없음 | 내부망 침해 시 세션/재생방지 키 탈취·변조 위험이 남음 | `services/edge-gateway/internal/gateway/server.go` (`redis.NewClient` 기본 옵션) | Redis TLS + ACL + timeout 필수화, insecure config 부팅 차단 |
| API key 미존재(`unknown_key`) 요청이 서명검증/rate-limit 전에 반환됨 | 키 열거·브루트포스 탐색 시도가 저비용으로 가능해 perimeter 방어를 우회할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`authMiddleware`의 `unknown_key` 분기) | unknown/missing key 경로도 동일한 rate-limit·지연·일관 응답 정책 적용 |
| WS `RESUME`가 symbol 유효성/allowlist 검증 없이 처리됨 | 임의 symbol resume로 고카디널리티 상태 접근 및 우회 구독 시도가 가능함 | `services/edge-gateway/internal/gateway/server.go` (`handleResume`) | RESUME도 SUB와 동일한 symbol/channel 검증 및 allowlist 강제 |
| market-data cache가 Redis 오류 시 메모리 fallback으로 계속 동작 | 다중 edge 인스턴스에서 스냅샷/티커 관측값이 분기되어 클라이언트 화면 일관성이 깨질 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`cacheSet`, `cacheGet`) | prod에서 cache fallback 금지(fail-closed) + degraded mode/알람 |
| 사용자 생성 duplicate 판정이 오류 문자열 매칭에 의존 | DB/드라이버 메시지 변경 시 중복판정 오탐으로 회원가입 흐름이 불안정해질 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`createUser`) | SQLSTATE/driver code 기반 duplicate 판정으로 표준화 |
| ledger `ensureAccount`가 exists-check 후 insert를 원자적으로 보장하지 않음 | 동시 처리에서 계정 생성 경합으로 unique 예외/부분실패가 발생할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`ensureAccount`) | `INSERT ... ON CONFLICT DO NOTHING` 기반 upsert로 경합 내성 확보 |
| reconciliation ingest 입력(`symbol`, `seq`) 경계검증이 약함 | 음수/비정상 seq 또는 비정규 symbol이 들어오면 상태 테이블 오염 및 오탐 경보를 유발할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/api/LedgerController.kt` (`recordEngineSeq`), `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`updateEngineSeq`) | engine-seq API 입력 검증(seq>=0, symbol format/allowlist) 강제 |
| K8s audit policy가 `secrets/configmaps`를 `RequestResponse` 레벨로 기록 | 감사 로그 저장소에 민감정보 본문이 남아 2차 유출면을 확대할 수 있음 | `infra/k8s/rbac/audit-policy.yaml` | secret류는 Metadata 수준으로 축소 + redaction 정책/검증 추가 |
| namespace PodSecurity `enforce-version: latest` 사용 | 클러스터 업그레이드 시 정책 해석이 변동되어 예기치 않은 배포 차단/완화가 발생할 수 있음 | `infra/k8s/base/namespaces.yaml` | 명시 버전 pin(예: `v1.30`) + 업그레이드 시 검증 절차 강제 |
| core gRPC 서비스가 async 핸들러에서 `std::sync::Mutex`로 공유상태를 직렬화 | 고동시성 시 tokio 워커 블로킹으로 tail latency 급등/timeout 연쇄 가능성이 있음 | `services/trading-core/src/bin/trading-core.rs` (`Arc<Mutex<TradingCore>>`, `Arc<Mutex<KafkaTradePublisher>>`) | 단일 writer actor 또는 비동기 친화 실행모델로 전환 + 경합부하 테스트 통과 |
| WS 메트릭 수집이 스크랩마다 전체 connection 큐 길이를 잠금하에 순회 | 수만 연결 환경에서 `/metrics` 스크랩이 응답지연/락경합을 유발할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`handleMetrics`, `for c := range s.state.clients`) | O(1) 집계 지표(histogram/rolling stats)로 전환 + scrape 부하 테스트 통과 |
| reconciliation 메트릭이 단일 전역 gauge(마지막 조회값) 중심으로 유지 | 심볼별 상태가 마지막 호출에 덮여 가시성이 왜곡되고 경보 정확도가 저하될 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/core/LedgerMetrics.kt` (`reconciliationGap`), `LedgerService.reconciliation` | 심볼 라벨 기반 메트릭으로 전환 + 조회 API 호출과 분리된 평가 지표 유지 |
| auth 실패 메트릭이 reason별로 노출되지 않고 합계만 제공 | `unknown_key` 급증과 `bad_signature/replay` 급증을 분리 탐지하지 못해 공격 유형 분류가 지연됨 | `services/edge-gateway/internal/gateway/server.go` (`authFailReason` 집계 후 `edge_auth_fail_total`만 노출) | reason label metric 추가 + 탐지 규칙(reason별 threshold) 고정 |
| 세션 저장 payload에 이메일 등 불필요 PII를 포함 | 세션 저장소 유출 시 노출면이 확대되고 최소수집 원칙을 위반할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`sessionRecord.Email`, `createSession`) | 세션 claims 최소화(user_id/exp 등) + PII 분리 조회 |
| 로그인 사용자 조회에서 DB 오류를 `invalid credentials`로 흡수 | 인증 저장소 장애가 크리덴셜 오류로 은닉되어 장애 탐지/대응이 늦어질 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`getUserByEmail`/`getUserByID` 에러 시 false) | DB 오류와 자격증명 오류를 구분(5xx/알람)하고 탐지 메트릭 추가 |
| edge tracer 리소스 태그가 `deployment.environment=local`로 고정 | prod/staging 관측 데이터가 잘못 분류되어 SLO/비용/알람 분리가 어려워질 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`initTracer`) | 환경별 배포태그 주입 강제 + 태그 누락 시 fail-closed 검증 |
| K8s audit policy의 광범위 wildcard 규칙이 고볼륨 이벤트를 상시 수집 | 감사 로그 폭증으로 비용/성능 저하 및 노이즈 증가로 실사건 탐지가 어려워질 수 있음 | `infra/k8s/rbac/audit-policy.yaml` (`group:* resources:*`) | 고위험 리소스 중심 최소 규칙 + volume budget/retention 정책 고정 |
| WS 명령 평면(`SUB/UNSUB/RESUME`)에 per-connection rate limit이 없음 | 명령 flood 시 스냅샷 재전송/파싱 CPU가 급증해 정상 구독 지연과 연결 품질 저하가 발생할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`wsReader`, `sendSnapshot`) | WS command token-bucket + close reason/메트릭 + flood smoke 고정 |
| edge 상태(`orders/clients/wallets/rate`)가 단일 전역 mutex(`state.mu`)로 보호됨 | WS fan-out/주문/정산 갱신이 락경합으로 묶여 고동시성에서 tail latency가 급등할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`state.mu` 전역 사용) | 상태 락 분리(도메인별/샤드별) + contention 메트릭 + 부하 회귀 테스트 |
| CI 보안 스캔이 artifact 업로드 중심이고 code-scanning merge gate와 미연동 | 취약점 스캔 결과가 존재해도 PR 단계에서 차단되지 않아 운영 반영 위험이 남음 | `.github/workflows/ci.yml` (`security-baseline` 단계) | SARIF 업로드 + high/critical 미해결 시 fail-closed merge gate |
| core Kafka producer partition key가 `trade_id`로 고정되어 있음 | topic partition>1 환경에서 심볼별 seq ordering이 깨져 ledger applied seq 단조성과 gap 탐지가 왜곡될 수 있음 | `services/trading-core/src/kafka.rs` (`BaseRecord.key(&payload.trade_id)`) | 심볼/샤드 기준 key 전략 확정 + multi-partition ordering chaos 게이트 |
| core gRPC가 도메인 reject/권한 오류를 모두 `Status::internal`로 반환 | edge/client가 비재시도 오류를 재시도해 중복/지연/오탐 경보를 유발할 수 있음 | `services/trading-core/src/bin/trading-core.rs` (`map_err(|e| Status::internal(...))`) | 도메인 오류코드 매핑(`INVALID_ARGUMENT/PERMISSION_DENIED/FAILED_PRECONDITION`) + 계약 테스트 |
| 세션 발급이 사용자당 활성 세션 수/전역 revoke 인덱스 없이 누적 | 계정 탈취·키유출 시 기존 토큰 일괄 무효화가 어려워 장기 세션 남용 위험이 큼 | `services/edge-gateway/internal/gateway/server.go` (`createSession`, `deleteSession`, `sessionsMemory`) | per-user session cap + revoke-all watermark + 다중 인스턴스 일관성 검증 |
| `EDGE_API_SECRETS` 파싱이 key/secret 존재 여부만 검사 | 짧은/예측 가능한 secret, 만료 없는 key가 운영에 투입되어 서명 경계가 약화될 수 있음 | `services/edge-gateway/cmd/edge-gateway/main.go` (`parseSecrets`) | secret 길이/entropy/만료 메타 강제 + 약한 secret 부팅 차단 |
| `/v1/admin/reconciliation/status`는 limit clamp가 있어도 전역 최신순 조회를 반복 수행 | `reconciliation_history`가 커지면 고빈도 폴링에서 정렬/스캔 비용이 누적되어 admin API 지연과 DB 부하를 유발할 수 있음 | `services/ledger-service/src/main/kotlin/com/quanta/exchange/ledger/repo/LedgerRepository.kt` (`reconciliationHistory`), `services/ledger-service/src/main/resources/db/migration/V2__reconciliation_history.sql` | 전역 최신조회 인덱스 + cursor pagination + 폴링 budget/rate-limit 적용 |
| core `recent_events`가 무제한 `Vec`로 누적 | 장시간 운용 시 메모리 비가역 증가로 GC/메모리 압박과 장애 복구 시간 악화 가능 | `services/trading-core/src/engine.rs` (`recent_events: Vec<CoreEvent>`, `extend(events)`) | bounded ring buffer + retention budget + 메모리 회귀 테스트 |
| WS command 오류 응답이 `err.Error()`를 그대로 외부 노출 | 내부 구현 변경 시 오류 표면이 흔들리고 불필요한 내부 문맥이 노출될 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`wsReader`의 Error frame) | WS 오류코드 표준화 + 내부 상세는 서버 로그 전용으로 분리 |
| Kafka numeric 직렬화가 `parse_i64(...).unwrap_or(0)`로 fail-open | 비정상 수치가 `0`으로 발행되어 ledger 정합성 오염이 조용히 전파될 수 있음 | `services/trading-core/src/kafka.rs` (`parse_i64`) | 직렬화 단계 strict parse + 실패 이벤트 격리/발행중단(fail-closed) |
| ledger datasource에 pool/statement timeout 기본정책이 없음 | 장기 쿼리/락 경합 시 consumer와 admin API가 함께 정체되어 복구시간이 증가할 수 있음 | `services/ledger-service/src/main/resources/application.yml` (Hikari/statement timeout 미설정) | pool/timeout/budget 설정 + slow query 메트릭/알람 |
| CI `security-baseline`는 SARIF 생성만 하고 code scanning 업로드 권한/스텝이 없음 | 보안 이슈가 PR 보안 게이트로 연결되지 않아 탐지 결과가 머지 차단으로 이어지지 않음 | `.github/workflows/ci.yml` (`permissions`, `security-baseline`) | `security-events: write` + `upload-sarif` + 업로드 실패 fail-closed |
| chaos 스위트가 process crash 중심이고 service 간 network partition 시나리오가 없음 | 네트워크 단절/부분 복구에서의 exactly-once 효과·안전모드 전환을 검증하지 못함 | `scripts/chaos_replay.sh` (kill/restart 중심) | core↔ledger, edge↔core partition drill + 복구 후 invariants/recon 통과 |
| CI 워크플로우에 job timeout/concurrency 가드가 없음 | hang/stale run이 최신 커밋보다 먼저 성공 표시되어 게이트 신뢰도를 떨어뜨릴 수 있음 | `.github/workflows/ci.yml` (`timeout-minutes`, `concurrency` 미설정) | timeout budget + branch concurrency cancel-in-progress 강제 |
| 운영 k8s 매니페스트에 edge ingress/TLS/cert rotation 증적 경로가 없음 | 외부 트래픽 암호화/인증서 만료 대응이 IaC로 보장되지 않아 운영 리스크가 남음 | `infra/k8s/base/*` (ingress/tls manifest 부재), `services/edge-gateway/cmd/edge-gateway/main.go` (plain 기본) | TLS termination IaC + cert 만료 알람/회전 드릴 증거 고정 |
| WS resume 히스토리가 in-memory `maxHistory=1024` 고정 | 고체결 구간에서 재연결 시 replay 범위가 빠르게 유실되어 trades 채널의 “유실 최소화” 목표를 달성하기 어려움 | `services/edge-gateway/internal/gateway/server.go` (`appendHistory`, `historyBySymbol`) | durable replay buffer(Kafka/Redis/DB) + 채널별 보존 창/SLO + gap 신호 표준화 |
| market data 공개 REST 엔드포인트가 인증 없이 고빈도 호출 가능 | 스크래핑/폴링 폭주가 WS fan-out/주문 경로와 리소스를 경쟁해 지연·비용 급증을 유발할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`/v1/markets/*` 공개 라우트) | IP/API-key tier 기반 read rate-limit + 캐시/429 정책 + abuse 알람 |
| security-baseline vuln scan이 `ignore-unfixed: true` 기본 | 실제 운영 영향이 큰 High/Critical unfixed 취약점이 게이트에서 누락될 수 있음 | `.github/workflows/ci.yml` (`trivy` vuln scan) | unfixed 허용정책(예외목록·만료일) 명시 + 기본 fail-closed |
| edge 주문/WS/market-data 경로의 symbol canonicalization 규칙이 분산 | 대소문자/포맷 편차로 캐시키·히스토리키 분리와 모니터링 라벨 드리프트가 발생할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`handleCreateOrder`, `parseWSSubscription`, market routes) | ingress 전역 symbol 정규화/검증 미들웨어 + allowlist 단일화 |
| WS `RESUME` 재전송이 현재 구독 필터를 통과하지 않고 심볼 히스토리 전체를 push | trades-only 구독 클라이언트에도 book/candle/ticker가 섞여 전달되어 대역폭/큐 사용량이 불필요하게 증가할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`handleResume`) | RESUME replay도 subscription-aware 필터를 적용하고 채널별 재동기화 규약을 분리 |
| Kafka topic/group-id 기본값이 환경 네임스페이스 없이 고정 문자열 | 단일 Kafka 클러스터 공유 시 dev/staging/prod consumer 간 offset 간섭/데이터 오염 위험이 존재 | `services/trading-core/src/bin/trading-core.rs` (`core.trade-events.v1`), `services/edge-gateway/cmd/edge-gateway/main.go` (`edge-trades-v1`), `services/ledger-service/src/main/resources/application.yml` (`ledger-settlement-v1`) | 환경/리전 접두사 네이밍 규칙 + 배포 전 충돌검사 + cross-env 격리 스모크 |
| Redis key 네이밍이 환경/테넌트 prefix 없이 평문 prefix만 사용 | 공유 Redis 구성에서 세션/캐시/리플레이 키 충돌로 cross-env 오염 및 revoke 혼선이 발생할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`sessionKey`, `cacheKey`, replay/idempotency key 구성) | 환경/서비스 namespace prefix 강제 + keyspace 충돌 테스트 |
| edge `state.orders`는 완료 주문 정리 정책 없이 누적 | 장기 운용 시 주문맵 메모리 증가로 GC 지연과 지연시간 악화가 발생할 수 있음 | `services/edge-gateway/internal/gateway/server.go` (`state.orders`, `handleCreateOrder`, `applyOrderFill`) | 완료 주문 TTL/아카이브 정책 + 메모리 상한 알람 + 회귀테스트 |
| `invariant_alerts` 테이블에 보존/중복 억제 정책이 없음 | 반복 위반 상황에서 알림 레코드가 무한 증가해 DB 부하와 조사 노이즈가 커질 수 있음 | `services/ledger-service/src/main/resources/db/migration/V1__ledger_schema.sql` (`invariant_alerts`), `LedgerRepository.invariantCheck()` | alert retention/dedup/index 정책 + housekeeping 잡 + 용량 budget 게이트 |

## 2) Live-Go 판단

- 현재 상태 기준으로는 실제 거래소 서비스 운영 불가.
- 이유: 규제/보안/HA/운영통제 영역의 블로커가 아직 열려 있음.
- 아래 Live-Go 블로커를 먼저 통과해야 외부 사용자 대상 제한적 운영 가능.

## 3) Live-Go 블로커 티켓 (기존 P0 선행)

| ID | Type | Gate | Priority | 티켓 | Done 기준 |
|---|---|---|---|---|---|
| I-9001 | I | G4.5/G27 | P0-BLOCKER | Edge Perimeter Security (WAF/DDoS/Bot) | L7 WAF + DDoS + bot rule 배치, 우회 시도 부하테스트 통과 |
| I-9002 | I | G4.2/G23 | P0-BLOCKER | Production HA/Fault Topology 확정 | Core/Edge/Ledger/Kafka/Postgres 다중 AZ 구성 + failover drill 통과 |
| I-9003 | I | G4.2/G14 | P0-BLOCKER | Backup Immutability + Daily Restore Drill | 백업 암호화/보존정책 + 일일 복구리허설 자동 성공 |
| A-9001 | A | G4.5/G32 | P0-BLOCKER | Admin IAM(MFA/SSO/JIT) 강제 | 고위험 액션은 MFA + JIT + 세션감사 없이는 실행 불가 |
| A-9002 | A | G4.5/G32 | P0-BLOCKER | SoD(직무분리) 실행강제 | 요청자=승인자 금지, 권한오남용 테스트 전수 통과 |
| B-9001 | B | G12/G24 | P0-BLOCKER | KYC/KYT/AML + 계정 동결 파이프라인 | 의심 계정 주문/출금 즉시 차단 및 감사로그 생성 |
| B-9002 | B | G22/G24 | P0-BLOCKER | Withdrawal Control Baseline | 출금 2인 승인 + timelock + velocity limit + idempotency 적용 |
| I-9004 | I | G13 | P0-BLOCKER | 24x7 Oncall + Paging + Escalation | SEV1/SEV2 알림이 Pager로 라우팅되고 응답 SLA 측정 |
| I-9005 | I | G27 | P0-BLOCKER | External PenTest + Remediation Gate | 외부 모의침투 Critical/High 0건 아니면 배포 차단 |
| I-9006 | I | G12/G25 | P0-BLOCKER | Data Governance/PII 정책 강제 | PII 암호화/마스킹/보존/삭제요청 처리 및 접근감사 통과 |
| I-9007 | I | G13/G26 | P0-BLOCKER | Incident Communication 체계 | 상태페이지/고객공지 템플릿/법적보고 타임라인 자동화 |
| I-9008 | I | G10/G33 | P0-BLOCKER | Change Freeze/Canary/Rollback 가드레일 | 고위험 배포는 카나리+자동롤백 조건 미충족 시 차단 |
| A-9003 | A | G4.5/G32 | P0-BLOCKER | Internal/Admin API 인증/인가 강제 | Ledger/Core admin 엔드포인트는 mTLS + RBAC + 승인 없는 호출 거부 |
| I-9009 | I | G27 | P0-BLOCKER | Service-to-Service mTLS + Identity | Edge↔Core, Edge↔Ledger, service mesh/mtls 정책 적용 및 평문 차단 |
| I-9010 | I | G10 | P0-BLOCKER | Prod Config Guardrails (Fail-Closed) | `EDGE_API_SECRETS` 비어있음, `SeedMarketData`, `CORE_STUB_TRADES` 등 위험설정이면 부팅 실패 |
| B-9003 | B | G24 | P0-BLOCKER | Monetary Precision Migration | Edge/Ledger/Market data 금액 필드를 최소단위 정수로 통일, `float` 제거 |
| B-9004 | B | G24 | P0-BLOCKER | Ledger SoT 강제 (Edge 잔고/주문 상태 이관) | Edge 메모리 상태 제거, Ledger projection/read model만 사용 |
| B-9005 | B | G27 | P0-BLOCKER | Production Build Hardening | `smoke`/seed/stub 코드 경로 prod artifact에서 비활성 또는 컴파일 제외 |
| B-9006 | B | G4.1 | P0-BLOCKER | Durable Idempotency/Order State | idempotency/order state를 다중 인스턴스 안전 저장소로 이전 |
| B-9007 | B | G4.2 | P0-BLOCKER | Distributed Fencing/Lease | 단일 writer 보장을 외부 lease로 강제하고 split-brain chaos 통과 |
| B-9008 | B | G5.0 | P0-BLOCKER | Fee-Accurate Settlement Projection | Edge 표시잔고/포트폴리오가 수수료/정산 반영된 Ledger 기준과 일치 |
| I-9011 | I | G27/G33 | P0-BLOCKER | Security Gate Fail-Closed | CI 보안스캔/secret scan High/Critical 발견 시 실패 |
| I-9012 | I | G4.5 | P0-BLOCKER | Production K8s Runtime Baseline | Deployment/StatefulSet/HPA/PDB/resource/anti-affinity/readiness 강제 |
| I-9013 | I | G10 | P0-BLOCKER | GitOps Promotion Discipline | dev/staging/prod 브랜치·이미지태그 분리, prod는 immutable digest만 허용 |
| I-9014 | I | G27 | P0-BLOCKER | Edge Security Hardening Pack | 로그인 시도 제한/계정잠금/IP reputation/HTTP timeout/body limit 적용 |
| B-9009 | B | G4.2 | P0-BLOCKER | Kafka Replay Semantics 명확화 | consumer 시작 offset/재구동 정책 명시, 데이터 유실/중복 시나리오 테스트 통과 |
| B-9010 | B | G4.1/G4.2 | P0-BLOCKER | Settlement Failure Semantics 재설계 | transient 실패는 재시도/보류, 확정 실패만 DLQ; 누락 없이 재처리 가능 |
| B-9011 | B | G4.1 | P0-BLOCKER | Processed Events Table 실제 적용 | settlement/receipt/replay 전 경로에서 processed-events 키 전략 통일 |
| B-9012 | B | G4.1/G5.1 | P0-BLOCKER | Canonical Event Encoding 표준화 | Kafka payload를 schema-governed 포맷으로 통일하고 호환성 CI 적용 |
| B-9013 | B | G4.3/G5.1 | P0-BLOCKER | WS Multi-Replica Consistency 모델 | edge 다중 인스턴스에서도 심볼 이벤트 누락 없이 전달 보장 |
| B-9014 | B | G4.5 | P0-BLOCKER | Smoke/Seed Endpoint Kill-Switch | prod에서 `/v1/smoke/*`, 샘플시드 경로 완전 차단(컴파일/런타임 모두) |
| B-9015 | B | G4.1/G11 | P0-BLOCKER | Durable Order/Trade Query Store | 주문상태/체결 이력을 메모리 아닌 영속 저장소에서 감사 가능하게 제공 |
| I-9015 | I | G4.4 | P0-BLOCKER | Core Observability Endpoint | core `/metrics` + health/readiness + 핵심 SLO 메트릭 제공 |
| I-9016 | I | G4.5 | P0-BLOCKER | Runtime Workload Manifests | 실제 운영용 Deployment/Service/HPA/PDB/PodSecurityContext 정의 완료 |
| I-9017 | I | G4.2 | P0-BLOCKER | Kafka Production Policy | partition/replication/retention/ACL/TLS 정책 및 토픽 표준화 |
| I-9018 | I | G4.2 | P0-BLOCKER | WAL/Outbox Lifecycle 정책 | 세그먼트 롤오버/압축/오브젝트 업로드/복구 테스트 자동화 |
| I-9019 | I | G4.6/G33 | P0-BLOCKER | Nightly Full E2E Gate | `smoke_match + reconciliation + chaos + invariants` nightly 고정 |
| A-9004 | A | G5.3/G32 | P0-BLOCKER | Admin Identity Binding 강제 | `requestedBy/approver`를 request body가 아닌 인증 주체에서만 주입 |
| B-9016 | B | G4.2 | P0-BLOCKER | Settlement Pause/Resume No-Loss Semantics | pause 중 소비 레코드 유실/commit 0건, resume 후 backlog catch-up 자동 검증 |
| B-9017 | B | G12/G24 | P0-BLOCKER | Ledger Balance API Scope Containment | `/v1/balances` 제거 또는 admin 보호 + 사용자 스코프 조회만 허용 |
| B-9018 | B | G5.1 | P0-BLOCKER | Edge Consumer Restart Gap Recovery | consumer 재기동 후 누락 구간 탐지/복구, `LastOffset` blind start 금지 |
| B-9019 | B | G4.1/G5.1 | P0-BLOCKER | Strict Event Numeric Parsing | 파싱 실패를 0으로 대체 금지, malformed 이벤트는 격리+메트릭+재처리 |
| B-9020 | B | G4.5/G27 | P0-BLOCKER | Session/Auth Hardening Baseline | 세션 해시저장/회전, 로그인 브루트포스 제한, 토큰 탈취 대응 정책 적용 |
| I-9020 | I | G27 | P0-BLOCKER | Internal Transport TLS Default-On | Edge↔Core, Ledger↔Core gRPC mTLS 및 OTLP TLS 기본 강제 |
| I-9021 | I | G27 | P0-BLOCKER | Edge HTTP Server Hardening | read/write/header timeout, max body/header, graceful shutdown 검증 |
| I-9022 | I | G10/G27 | P0-BLOCKER | Production Default-Credential Guard | 기본 계정/`sslmode=disable`/insecure exporter 설정이면 부팅 실패 |
| B-9021 | B | G4.1 | P0-BLOCKER | Core Idempotency Scope Isolation | idempotency key에 `user_id + command_type + symbol` 포함, 교차사용자 충돌 0건 |
| B-9022 | B | G4.5/G32 | P0-BLOCKER | Core Cancel Ownership Authorization | core가 `cancel_order` 시 owner 불일치 요청 거부 및 audit 기록 |
| B-9023 | B | G4.1/G5.0 | P0-BLOCKER | Order ID Generation Hardening | `order_id`는 난수 UUID, idempotency key와 분리, 충돌/추측 테스트 통과 |
| B-9024 | B | G4.1/G24 | P0-BLOCKER | Edge Settlement Projection Safety | 음수 clamp 제거, 표시잔고는 ledger projection과 일치(무자금 체결시 credit 0) |
| B-9025 | B | G4.3/G26 | P0-BLOCKER | Edge Memory/Cardinality Guardrails | replay/rate/cache/history 맵 상한+eviction+allowlist 적용, 메모리 폭주 테스트 통과 |
| A-9005 | A | G5.3/G32 | P0-BLOCKER | Correction SoD Enforcement | 요청자=requestedBy는 approver/apply 주체가 될 수 없고 시스템이 강제 차단 |
| I-9023 | I | G4.6/G31 | P0-BLOCKER | Safety-case Gate Completeness | safety-case 산출물에 invariants/reconciliation/chaos/state-hash/offset diff 필수 포함 |
| I-9024 | I | G5.3/G27 | P0-BLOCKER | Least-Privilege Ops RBAC | 운영 기본 롤에서 secret write/delete 제거, break-glass 전용 권한으로 분리 |
| B-9026 | B | G4.1/G5.0 | P0-BLOCKER | Core Order-ID Uniqueness Enforcement | 중복 `order_id` 요청은 deterministic reject, orderbook/map 불일치 재현 테스트 0건 |
| A-9006 | A | G5.3/G32 | P0-BLOCKER | Correction Request Integrity Gate | correction 생성 시 원본 entry 존재/상태 검증 + 주체 식별은 인증정보로만 주입 |
| B-9027 | B | G4.1 | P0-BLOCKER | Settlement Idempotency Store Activation | `settlement_idempotency`(또는 processed-events) 실사용 + replay/duplicate 실험으로 증명 |
| B-9028 | B | G4.1/G4.2 | P0-BLOCKER | Command Ack/Reserve Consistency | core publish 실패 시 주문결과 `UNKNOWN` 상태 처리, edge reserve 롤백 금지 및 사후 reconcile |
| B-9029 | B | G4.1/G4.2 | P0-BLOCKER | Outbox Publish Coverage Completeness | place/cancel/set-mode/cancel-all 전 경로에서 outbox publish 보장 + 지연 상한 모니터링 |
| B-9030 | B | G4.1/G27 | P0-BLOCKER | Idempotency Fingerprint Enforcement | idem key 재사용 시 요청 해시 불일치면 거부, 감사 로그에 충돌 사유 기록 |
| B-9031 | B | G4.5/G27 | P0-BLOCKER | Session Abuse Guardrail | bearer session 경로에 rate/replay/device risk 체크 적용 |
| A-9007 | A | G5.3/G32 | P0-BLOCKER | Correction Approval Atomicity | 동시 승인 경합에서도 승인상태 전이가 원자적으로 1회만 발생 |
| A-9008 | A | G5.3/G32 | P0-BLOCKER | Correction Metadata Authority | correction apply envelope를 서버 생성값으로 강제(클라이언트 주입 금지) |
| B-9032 | B | G4.1 | P0-BLOCKER | Reconciliation Seq Continuity Guard | latest lag뿐 아니라 seq hole(누락 구간) 탐지, hole 발생시 즉시 safety mode |
| B-9033 | B | G4.1/G24 | P0-BLOCKER | Ledger Non-Negative Enforcement | 고객계정 음수 잔고는 write-path에서 즉시 거부(사후 invariant 의존 제거) |
| I-9025 | I | G4.3/G26 | P0-BLOCKER | WS Connection Admission Control | global/per-IP conn cap + handshake rate limit + 폭주 시 표준 close |
| B-9034 | B | G4.2 | P0-BLOCKER | Kafka Producer Durability Profile | core producer `acks=all`, `enable.idempotence=true`, in-flight 제한 적용 |
| A-9009 | A | G5.3/G32 | P0-BLOCKER | Correction Apply Audit Completeness | `applied_by/applied_at` 분리 기록 + 승인자/적용자 분리 강제 |
| B-9035 | B | G4.1/G5.3 | P0-BLOCKER | Core Admin Metadata Fail-Closed | `set_symbol_mode/cancel_all`에서 meta 누락·불일치 요청 즉시 reject, fallback 메타 금지 |
| B-9036 | B | G4.2/G26 | P0-BLOCKER | Core Mutating Command Fencing Enforcement | `cancel_order/set_symbol_mode/cancel_all`도 leader token 검증 실패 시 reject + audit |
| B-9037 | B | G4.1/G5.0 | P0-BLOCKER | Core Command Symbol Scope Validation | non-place 명령에서 `meta.symbol == core.symbol` 강제, mismatch 차단 |
| I-9026 | I | G4.3/G26 | P0-BLOCKER | WS Heartbeat/Idle Timeout Enforcement | ping/pong/read deadline 적용, zombie conn 자동 정리 SLO 충족 |
| B-9038 | B | G4.3/G26 | P0-BLOCKER | WS Subscription Cardinality Guard | per-conn subscription 상한 + 심볼 allowlist + SUB flood 테스트 통과 |
| B-9039 | B | G4.1/G5.3 | P0-BLOCKER | Admin Command Idempotency Guard | `set_symbol_mode/cancel_all` 재시도 시 동일 결과 재응답, 중복 상태 변경 0건 |
| B-9040 | B | G4.2/G4.6 | P0-BLOCKER | Kafka Poison-Pill Isolation | malformed payload는 DLT 격리, settlement/recon consumer 진행률 정지 0건 |
| I-9027 | I | G4.2/G10 | P0-BLOCKER | Core Durable Path Guard | prod에서 WAL/Outbox 경로가 ephemeral(`/tmp`)면 부팅 실패 |
| B-9041 | B | G4.3/G5.1 | P0-BLOCKER | Edge Trade Consumer Failure Recovery | trade apply 실패는 retry/DLQ/gap marker로 처리, 누락 0건 증명 |
| B-9042 | B | G4.1/G5.1 | P0-BLOCKER | Edge Trade Dedupe Durability | `trade_id` dedupe를 영속 저장소로 이전, 재시작/scale-out 중복반영 0건 |
| B-9043 | B | G4.1/G5.3 | P0-BLOCKER | Reconciliation Safety Action Retry Policy | 안전모드 전환 실패 시 breach 지속 동안 재시도 + 실패 카운터/알람 |
| B-9044 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Freshness Guard | `updated_at` staleness breach 시 safety mode 및 원인코드 기록 |
| B-9045 | B | G4.1/G27 | P0-BLOCKER | Core Idempotency Time Source Hardening | idempotency TTL은 서버시간 기준, client ts skew 초과 reject |
| B-9046 | B | G4.1/G24 | P0-BLOCKER | Unknown Principal Wallet Fail-Closed | 미존재 사용자/키의 wallet auto-seed 금지, 계정명시적 생성만 허용 |
| I-9028 | I | G4.5/G27 | P0-BLOCKER | Core gRPC Exposure Guard | core gRPC mTLS + auth interceptor + non-public bind를 프로덕션 강제 |
| B-9047 | B | G4.1/G4.2 | P0-BLOCKER | Edge Trade Apply Atomicity | dedupe 마킹은 반영 완료 후 commit, 중간 실패 시 재처리로 수렴 |
| B-9048 | B | G4.1/G24 | P0-BLOCKER | Wallet Persistence Error Enforcement | wallet persist 실패 시 요청 실패/재시도/격리, 메모리-DB 분기 0건 |
| B-9049 | B | G4.1/G17 | P0-BLOCKER | Core Event Stream Completeness | Trade 외 Order/Mode/Checkpoint 이벤트를 canonical stream으로 발행 |
| B-9050 | B | G4.2 | P0-BLOCKER | Outbox Cursor Integrity Guard | cursor 무결성 검증 + 손상 시 fail-closed + 복구 절차 자동화 |
| B-9051 | B | G5.1 | P0-BLOCKER | Strict Trade Sequence Ingestion | seq 누락 payload는 reject/DLQ, timestamp fallback 제거 |
| I-9029 | I | G4.6/G30 | P0-BLOCKER | Hardened Drill Profile Gate | chaos/smoke를 hardened 설정(실인증, non-stub)으로도 매 릴리즈 검증 |
| B-9052 | B | G4.1/G24 | P0-BLOCKER | Core Auto-Credit Path Removal | `bootstrap_user_balances` 제거, 계정/잔고는 외부 주입 없이는 주문 불가 |
| I-9030 | I | G4.5/G26 | P0-BLOCKER | Edge Readiness Dependency Guard | `readyz`가 core health + consumer stall/lag를 반영하여 fail-closed 동작 |
| I-9031 | I | G4.5/G26 | P0-BLOCKER | Ledger Readiness Consumer Guard | `readyz`가 settlement/reconciliation consumer 상태를 반영 |
| B-9053 | B | G4.2/G5.1 | P0-BLOCKER | Edge Consumer Manual Commit Semantics | Kafka consume는 처리성공 후 commit, 실패 시 재시도로 수렴 |
| B-9054 | B | G4.2/G27 | P0-BLOCKER | SQLSTATE-Based Duplicate Detection | unique violation 판정을 SQLSTATE 코드 기반으로 표준화 |
| I-9032 | I | G4.6/G33 | P0-BLOCKER | CI Safety Gate Rust Coverage | rust/core 변경에도 load-smoke/dr-rehearsal/safety-case/chaos 게이트 강제 |
| B-9055 | B | G4.3/G27 | P0-BLOCKER | WS Frame Size Guard | `SetReadLimit` 적용, oversized frame 입력 시 즉시 close + 메트릭 기록 |
| I-9033 | I | G4.5/G27 | P0-BLOCKER | Metrics Exposure Hard Block | `/metrics`를 내부망/scraper 인증 경로로 제한, public route 제거 |
| B-9056 | B | G4.1/G24 | P0-BLOCKER | Account-Kind Aware Invariants | 음수 잔고 규칙을 customer/system 계정별로 분리해 오탐 0건 |
| B-9057 | B | G4.2/G4.6 | P0-BLOCKER | Outbox Corruption Quarantine | 손상 레코드 격리 후 후속 레코드 publish 지속, 사고번들 자동 생성 |
| B-9058 | B | G4.2 | P0-BLOCKER | Outbox Cursor Atomic Durability | cursor를 atomic rename+fsync로 기록, 크래시 재시작 일관성 증명 |
| B-9059 | B | G4.1/G4.2 | P0-BLOCKER | Settlement + Watermark Atomic Commit | trade settlement entry 반영과 `last_settled_seq` 갱신이 하나의 트랜잭션으로 원자화됨 |
| B-9060 | B | G4.1/G26 | P0-BLOCKER | Reconciliation Scheduler Singleton | 멀티 레플리카에서 reconciliation evaluate는 분산락/리더 1개만 수행 |
| B-9061 | B | G4.2/G13 | P0-BLOCKER | Settlement DLQ Replay/Retention Control | DLQ 재처리 워커 + max age/size + backlog 알람으로 영구 적체 0건 |
| B-9062 | B | G4.2 | P0-BLOCKER | WAL Truncated-Tail Recovery | tail partial frame 발생 시 손상 구간 절단 후 재기동/리플레이 성공 |
| B-9063 | B | G4.2/G27 | P0-BLOCKER | WAL Frame Length Guard | frame length 상한 검증으로 OOM/악성 WAL 입력 차단 |
| B-9064 | B | G4.2/G26 | P0-BLOCKER | Outbox Streaming Publish | 대규모 outbox backlog에서도 메모리 상한 고정 + publish 지연 SLO 충족 |
| I-9034 | I | G4.5/G10 | P0-BLOCKER | Edge Schema Migration Discipline | 운영에서 app startup DDL 금지, 모든 스키마 변경은 migration pipeline 경유 |
| I-9035 | I | G4.4/G4.6 | P0-BLOCKER | Hardened Load Harness Auth Path | 부하/게이트가 signed/session 인증 경로와 실거래 이벤트 소스로만 동작 |
| B-9065 | B | G5.1/G17 | P0-BLOCKER | Demo Market Data Fallback Removal | `demo-derived` fallback 제거, canonical snapshot/delta 없으면 명시적 stale 신호 반환 |
| B-9066 | B | G4.1/G24 | P0-BLOCKER | Cross-Service Numeric Domain Contract | core→Kafka→ledger 수치 필드를 i64-safe 범위로 계약화하고 overflow 입력은 reject |
| B-9067 | B | G4.2/G4.6 | P0-BLOCKER | Determinism Hash State Completeness | state hash에 orderbook 외 risk/reservation/symbol mode 핵심 상태 포함, replay hash 위양성 0건 |
| B-9068 | B | G4.2/G4.6 | P0-BLOCKER | Determinism Hash Fail-Closed | hash 직렬화 실패 시 fallback 해시 금지, 즉시 오류 반환/게이트 실패 |
| B-9069 | B | G4.2 | P0-BLOCKER | Snapshot Integrity Verification | snapshot checksum/state-hash 검증 실패 시 로드 거부 + 복구 runbook 제공 |
| B-9070 | B | G4.2 | P0-BLOCKER | Snapshot Atomic Durability | snapshot 저장 시 file/dir fsync 포함, crash fault-injection 후 복구 성공 |
| B-9071 | B | G5.0 | P0-BLOCKER | TimeInForce FOK Correctness | FOK는 부분체결 0건, 전량 미충족 시 즉시 REJECT/CANCEL 규칙 고정 |
| B-9072 | B | G4.2 | P0-BLOCKER | Startup Outbox Backlog Flush | core 재기동 직후 pending outbox 자동 발행, 후속 주문 없이도 누락 0건 |
| B-9073 | B | G4.1/G24 | P0-BLOCKER | Overflow-safe Double-Entry Validation | ledger 합산 검증/잔고갱신에서 산술 overflow 시 트랜잭션 차단 |
| B-9074 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Signed-Gap Metrics | 음수 gap/mismatch를 분리 지표로 노출해 경보 누락 0건 |
| I-9036 | I | G4.6/G33 | P0-BLOCKER | Determinism/Snapshot Corruption CI Gate | replay hash completeness + corrupted snapshot reject 시나리오를 CI 필수 게이트로 고정 |
| B-9075 | B | G4.1/G13 | P0-BLOCKER | Invariant Breach Auto-Isolation | invariant 위반 즉시 CANCEL_ONLY/HALT + safety latch + evidence bundle 자동 생성 |
| B-9076 | B | G4.2/G21 | P0-BLOCKER | DLQ Forensic Payload Completeness | DLQ 레코드에 원본 이벤트 본문/메타/스택을 저장해 replay 재현 가능 |
| B-9077 | B | G4.1/G27 | P0-BLOCKER | Ledger Strict Schema Decode | unknown field/버전 불일치 payload는 reject+DLQ 격리, 묵살 0건 |
| I-9037 | I | G4.5/G10 | P0-BLOCKER | Safety Mode Config Validation Gate | invalid safety mode 설정으로는 서비스 부팅 실패(fail-closed) |
| B-9078 | B | G4.1/G5.0 | P0-BLOCKER | Symbol Coverage Reconciliation Guard | 상장 심볼 전체가 recon/invariant 감시 대상에 포함됨을 주기 검증 |
| B-9079 | B | G4.2/G4.6 | P0-BLOCKER | Outbox Partial-Publish Idempotence | 레코드 중간 실패 후 재시도에서도 선발행 이벤트 중복 0건 보장 |
| I-9038 | I | G4.5/G27 | P0-BLOCKER | Ledger Actuator Exposure Hard Block | ledger actuator/metrics 경로를 내부 인증/네트워크로만 접근 허용 |
| I-9039 | I | G4.5/G27 | P0-BLOCKER | ServiceAccount Token Hardening | SA 토큰 기본 비마운트 + 필요 워크로드만 scoped mount |
| I-9040 | I | G4.5/G27 | P0-BLOCKER | NetworkPolicy Metrics Least-Privilege | observability ingress 포트를 서비스별 최소 포트로 축소, 우회 접근 차단 |
| B-9080 | B | G4.2/G4.6 | P0-BLOCKER | Replay Event Strict Decode | WAL replay에서 수치/필드 파싱 실패 시 `0` 대체 금지, 즉시 fail-closed + 복구 절차 실행 |
| B-9081 | B | G4.1/G24 | P0-BLOCKER | Overflow-safe Trade Arithmetic | core/edge의 `price*qty`/`quoteVolume` 계산을 overflow-safe로 통일하고 초과 입력은 차단 |
| B-9082 | B | G4.3/G26 | P0-BLOCKER | WS Candle Interval Allowlist | candles interval은 허용 목록(예: `1m/5m/1h`)만 수용, 임의 문자열 구독 차단 |
| B-9083 | B | G4.2/G4.6 | P0-BLOCKER | Ledger Kafka Manual Ack Discipline | settlement/recon listener를 manual ack + 명시적 error handler로 고정해 commit 시점을 결정론적으로 유지 |
| I-9041 | I | G4.2/G4.6 | P0-BLOCKER | Chaos Replay Live Hash Verification | `chaos_replay.sh`가 pre/post 재기동 시 라이브 core state hash 비교를 필수 수행 |
| I-9042 | I | G4.5/G27 | P0-BLOCKER | Safety-case Secretless Upload | safety-case/minio 업로드에서 하드코딩 키 제거, secret 주입 없으면 업로드 단계 실패 |
| B-9084 | B | G4.5/G27 | P0-BLOCKER | Core Log PII Redaction | 주문 처리 로그에서 `user_id`/민감 필드를 마스킹 또는 제거, 보안 로그 정책 테스트 통과 |
| I-9043 | I | G4.6/G33 | P0-BLOCKER | Replay Strictness CI Gate | replay strict decode/overflow 케이스/chaos live hash 검증을 CI 필수 게이트로 고정 |
| B-9085 | B | G4.2/G4.6 | P0-BLOCKER | WAL Symbol Binding Guard | 복구 중 WAL record.symbol과 core symbol 불일치 레코드는 즉시 복구 실패 처리 |
| B-9086 | B | G4.2/G4.6 | P0-BLOCKER | WAL State Hash Verification | replay 단계에서 상태 해시를 재계산/대조해 변조·불일치 WAL을 차단 |
| B-9087 | B | G4.2/G30 | P0-BLOCKER | WAL Fencing Token Continuity | WAL record의 fencing token epoch 연속성 검증으로 stale writer 레코드 반영 0건 |
| B-9088 | B | G4.2/G26 | P0-BLOCKER | WAL Streaming Replay Memory Guard | 대용량 WAL 복구를 스트리밍으로 수행해 메모리 상한 고정 |
| B-9089 | B | G4.2/G4.6 | P0-BLOCKER | Snapshot Symbol/Version Binding | snapshot metadata(symbol/schema/checksum) 검증 실패 시 로드 거부 |
| B-9090 | B | G4.5/G27 | P0-BLOCKER | Auth Body Size Limit Guard | 서명 검증 경로에 요청 본문 상한 적용(초과 413) + 메모리 폭주 방지 |
| B-9091 | B | G4.1/G27 | P0-BLOCKER | Idempotency Key Policy Enforcement | `Idempotency-Key` 길이/문자셋/정규식 정책 강제, 위반 요청 거부 |
| I-9044 | I | G4.6/G33 | P0-BLOCKER | Recovery Integrity CI Gate | WAL symbol/hash/fencing 변조·교차심볼·대용량 replay 시나리오를 CI 필수 실행 |
| B-9092 | B | G4.1/G24 | P0-BLOCKER | Trade QuoteAmount Consistency Guard | edge/ledger가 `quoteAmount == price*qty`(정책 허용 오차 포함)을 검증하고 불일치 이벤트는 격리/DLQ 처리 |
| B-9093 | B | G4.1/G27 | P0-BLOCKER | Integer-Only Trade Numeric Decode | trade/market-data 숫자 파싱에서 float/decimal 절삭 수용 금지, 정수 계약 위반 입력 차단 |
| B-9094 | B | G4.1/G24 | P0-BLOCKER | Wallet Storage Read Fail-Closed | 지갑 DB read/scan 실패 시 기본시드 대체 금지, 요청 실패+알람으로 처리 |
| B-9095 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Upsert Bounded Retry | reconciliation state/safety upsert 충돌 재시도를 반복문+상한으로 고정, 재귀 제거 |
| B-9096 | B | G4.2/G26 | P0-BLOCKER | WAL/Outbox Single-Writer File Lock | core startup에서 WAL/outbox 파일락을 획득 못하면 즉시 종료, 이중 writer 0건 증명 |
| B-9097 | B | G4.2/G21 | P0-BLOCKER | Settlement DLQ Failure Isolation | DLQ 적재 실패 시 별도 메트릭/알람/격리 경로로 처리하고 누락 커밋 0건 보장 |
| I-9045 | I | G4.5/G10 | P0-BLOCKER | Safety-Critical Flag Boot Guard | prod에서 `LEDGER_KAFKA_ENABLED=false` 또는 auto-switch 비활성이면 부팅/ready 차단(유지보수 override는 감사필수) |
| B-9098 | B | G4.2/G4.6 | P0-BLOCKER | Core Risk Replay Completeness | WAL/snapshot tail replay 후 risk balances/reservations/open-order exposure가 pre-crash와 동일함을 hash+scenario로 증명 |
| B-9099 | B | G4.2/G4.6 | P0-BLOCKER | Snapshot-First Recovery Path | core 부팅이 최신 snapshot + WAL tail 복구를 기본 사용하고 snapshot 불일치 시 fail-closed/fallback 규칙을 기록 |
| B-9100 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Metrics Integrity | read API 호출이 breach summary를 덮어쓰지 않으며, 평가잡 기준 active breach 메트릭이 일관됨 |
| B-9101 | B | G4.2/G4.4 | P0-BLOCKER | Core Publish-Latency Isolation | 주문 RPC 경로에서 동기 flush 제거, publish 지연 시에도 주문/cancel 제어 경로 p99 budget 준수 |
| I-9046 | I | G4.2/G4.6 | P0-BLOCKER | Recovery SLA Snapshot Gate | 대용량 WAL 환경에서 snapshot-first 복구시간 SLO를 CI/chaos 게이트로 상시 검증 |
| I-9047 | I | G4.6/G33 | P0-BLOCKER | Infra Validation Fail-Closed | 보호 브랜치 CI에서 `kubectl`/cluster 부재로 infra 검증이 skip-pass 되지 않고 즉시 실패 |
| I-9048 | I | G4.6/G33 | P0-BLOCKER | K8s/GitOps Schema+Policy Gate | `--validate=false` 제거, server-side dry-run + kubeconform + 정책검증(conftest/kube-linter) 필수화 |
| I-9049 | I | G10/G32 | P0-BLOCKER | JIT Grant Expiry Enforcement | 만료시점 지난 JIT ClusterRoleBinding 자동 회수 + `jit_active_grants` 메트릭/감사로그 일치 |
| I-9050 | I | G10/G27 | P0-BLOCKER | Argo Project Least-Privilege Scope | AppProject 리소스/네임스페이스 wildcard 금지, 허용 목록 외 sync 차단 테스트 통과 |
| I-9051 | I | G4.4/G33 | P0-BLOCKER | Load Harness Measurement Integrity | load harness가 주문 도메인 결과(FILLED/REJECT 등)와 WS 실패를 정확히 계측해 gate 위양성 0건 |
| B-9102 | B | G4.5/G27 | P0-BLOCKER | Edge Trade Error Log Redaction | trade consume 실패 로그에서 raw payload 제거, trade_id/hash 중심 구조화 로그만 허용 |
| I-9052 | I | G27/G33 | P0-BLOCKER | CI Action Supply-Chain Pinning | GitHub Actions를 commit SHA로 pin, 미핀 액션 발견 시 CI 실패 |
| B-9103 | B | G4.5/G27 | P0-BLOCKER | Auth Endpoint Rate-Limit/Lockout | `/v1/auth/signup|login`에 IP+계정 기준 제한/락아웃/지연응답 적용, 크리덴셜 스터핑 시나리오 차단 |
| B-9104 | B | G4.5/G27 | P0-BLOCKER | Session Store Consistency Guard | 프로덕션에서 Redis(또는 중앙 스토어) 필수, 메모리 fallback 금지, 다중 edge logout/revoke 일관성 테스트 통과 |
| U-9001 | U | G4.5/G27 | P0-BLOCKER | Browser Session Token Hardening | web-user가 localStorage 토큰을 사용하지 않고 HttpOnly/SameSite 세션 모델로 동작 |
| I-9053 | I | G4.5/G26 | P0-BLOCKER | NetworkPolicy Traffic Matrix Completeness | edge/core/ledger/infra 통신 경로를 최소허용 정책으로 명시, `default-deny` 환경 E2E 연결 테스트 통과 |
| I-9054 | I | G5.1/G17 | P0-BLOCKER | Streaming Runtime Implementation Gate | flink-jobs에 Kafka source/sink/checkpoint 기반 실제 잡을 배치하고 캔들/티커 재생성 검증 통과 |
| B-9105 | B | G4.1/G5.2 | P0-BLOCKER | Invariant Scan Scalability Guard | invariant scan이 timebox/증분전략으로 운영 부하 상한을 보장하고 스케일 테스트 통과 |
| B-9106 | B | G4.5/G27 | P0-BLOCKER | Edge Error Response Sanitization | 외부 API 응답에 `err.Error()`/내부 상세 노출 금지, 표준 오류코드 체계만 허용 |
| B-9107 | B | G4.1/G24 | P0-BLOCKER | Ledger Internal Input Semantic Validation | trade/reserve/release 입력의 필수필드/enum(side)/값범위를 경계에서 강제 |
| I-9055 | I | G4.2/G23 | P0-BLOCKER | DR Rehearsal Data-Plane Realism Gate | DR drill이 실제 snapshot/WAL/Kafka offset 복구를 포함하고 toy seed-only 경로를 금지 |
| I-9056 | I | G4.4/G33 | P0-BLOCKER | Load Smoke Full-Stack Isolation Gate | load smoke는 격리된 stack에서 deterministic하게 실행되고 외부 로컬 프로세스 의존 0건 |
| I-9057 | I | G27/G33 | P0-BLOCKER | Runtime Image Digest Pinning | compose/운영 스크립트 이미지 digest pin 적용, mutable tag 발견 시 CI 실패 |
| B-9108 | B | G4.1/G13 | P0-BLOCKER | Ledger Safety Flag Coupling Guard | reconciliation/consumer/observer 플래그 조합을 부팅 시 검증하고 잘못된 조합을 차단 |
| B-9109 | B | G4.5/G27 | P0-BLOCKER | Global Request Size/Schema Guard | edge API 전 경로에 body 상한/strict JSON decode를 강제해 DoS·스키마 드리프트 차단 |
| B-9110 | B | G4.1/G24 | P0-BLOCKER | Ledger Symbol Canonicalization Guard | symbol/currency를 대문자 정규화하고 비정규 입력을 거부해 자산 축 분리를 방지 |
| B-9111 | B | G4.1/G24 | P0-BLOCKER | Ledger Principal ID Sanitization | account_id 조합 전 user/system 식별자 문자셋·인코딩 정책을 강제해 구분자 주입 차단 |
| B-9112 | B | G4.1/G24 | P0-BLOCKER | Signup/Wallet Auto-Seed Removal | 운영환경에서 기본 자산 시드 경로를 제거하고 입금/승인 기반 초기화만 허용 |
| I-9058 | I | G4.2/G23 | P0-BLOCKER | DR Migration Chain Fidelity Gate | DR rehearsal이 최신 migration 전체를 적용해 schema drift 없는 복구를 증명 |
| I-9059 | I | G4.6/G33 | P0-BLOCKER | Safety-Case Freshness Guard | safety-case 번들의 load/dr/evidence가 동일 커밋·최신 타임스탬프임을 검증, stale 산출물 차단 |
| B-9113 | B | G4.5/G27 | P0-BLOCKER | Edge Finite Numeric Input Guard | 주문 수치 입력(`price/qty`)에서 `NaN/Inf`를 차단하고 finite-only 계약 위반 요청을 거부 |
| B-9114 | B | G4.2/G26 | P0-BLOCKER | Core Risk State Cardinality Guard | `recent_commands/open_orders` 키 cardinality 상한/정리 정책 적용, 장기 부하에서 메모리 상한 유지 |
| B-9115 | B | G4.3/G26 | P0-BLOCKER | Edge Runtime State Quota Guard | users/sessions/idempotency/wallets map에 quota/LRU/TTL 적용, overflow 시 fail-closed |
| B-9116 | B | G4.2/G26 | P0-BLOCKER | Ledger Online Balance Rebuild Safety | `TRUNCATE` 기반 재빌드 제거, shadow rebuild + atomic swap로 조회공백/경합 0건 |
| B-9117 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Seq Upsert Bounded Retry | `updateEngineSeq/updateSettledSeq` 재귀 재시도 제거, bounded retry + 실패 격리 알람 |
| B-9118 | B | G4.5/G32 | P0-BLOCKER | Principal Namespace Separation | core `user_id`는 canonical principal만 허용, API key ID/user ID 혼용 금지 |
| U-9002 | U | G4.5/G27 | P0-BLOCKER | Web-User Production Smoke Control Removal | `Push Sample Trade` UI/호출을 prod 빌드에서 제거하고 dev-only 플래그로 분리 |
| I-9060 | I | G4.5/G27 | P0-BLOCKER | Core gRPC Server Hardening | tonic keepalive/max-frame/connection budget/timeouts 강제 + abuse 테스트 통과 |
| B-9119 | B | G4.1/G24 | P0-BLOCKER | Order Fill Overrun Guard | 주문별 누적 fill/reserve 상한 검증으로 overfill/over-consume 이벤트를 즉시 격리 |
| B-9120 | B | G4.5/G27 | P0-BLOCKER | Session CSRF/Origin Guard | 쿠키 기반 세션 경로에 CSRF token + origin 검증 + same-site 정책을 강제 |
| B-9121 | B | G5.3/G32 | P0-BLOCKER | Correction Apply Atomicity Guard | correction reversal 반영과 상태전환(`APPLIED`)이 단일 트랜잭션으로 원자 수행 |
| B-9122 | B | G4.1/G27 | P0-BLOCKER | Ledger Schema Constraint Hardening | mode/status/amount/seq/account_kind 제약을 DB CHECK/FK로 강제, 우회 write 차단 |
| I-9061 | I | G10/G33 | P0-BLOCKER | GitOps Immutable Revision Promotion | prod/staging Argo Application은 `main` 추적 금지, 승인된 tag/SHA만 배포 |
| B-9123 | B | G4.5/G27 | P0-BLOCKER | Signup Enumeration Guard | signup/login 응답에서 계정 존재 여부 노출 금지 + 탐지 메트릭/알람 적용 |
| B-9124 | B | G4.5/G27 | P0-BLOCKER | Identifier Length/Charset Guard | command/order/trade/user/symbol 식별자 길이/문자셋 정책 위반 요청 즉시 거부 |
| B-9125 | B | G4.1/G27 | P0-BLOCKER | Event Version Compatibility Gate | 미지원 `eventVersion` 이벤트를 처리하지 않고 격리/DLQ + 버전 메트릭 노출 |
| B-9126 | B | G4.5/G25 | P0-BLOCKER | Auth Lifecycle Audit Trail | signup/login/logout/session 생성·폐기 이벤트를 immutable audit로 보존/조회 가능 |
| I-9062 | I | G4.6/G33 | P0-BLOCKER | Legacy Smoke Security Profile Gate | `smoke_e2e/g0/g3`를 hardened auth/non-stub 모드에서 필수 실행하고 위양성 차단 |
| B-9127 | B | G4.1/G24 | P0-BLOCKER | Ledger Account-Currency Referential Guard | `(account_id,currency)` 무결성 제약으로 posting 통화 불일치 write를 차단 |
| B-9128 | B | G4.2/G4.6 | P0-BLOCKER | WAL/Outbox Sequence Continuity Guard | replay/publish 경로에서 seq 중복·역행·gap을 검증하고 위반 시 fail-closed |
| B-9129 | B | G4.5/G25 | P0-BLOCKER | Core Reject-Path Audit Persistence | validation/권한 reject도 append-only audit 이벤트로 기록되어 추적 가능 |
| B-9130 | B | G4.5/G12 | P0-BLOCKER | User MFA + Verified-Email Enforcement | 거래/출금 민감 액션은 MFA+검증이메일 없으면 차단 |
| B-9131 | B | G4.5/G27 | P0-BLOCKER | Auth Timing Side-Channel Guard | signup/login 실패 응답을 시간 균등화하여 계정 상태 추론을 억제 |
| B-9132 | B | G4.2/G26 | P0-BLOCKER | Settlement DLQ Payload Bound Guard | DLQ payload 크기상한/요약해시 저장/원문 오프로드로 DB 폭주 방지 |
| I-9063 | I | G10/G33 | P0-BLOCKER | Argo Prod Sync Approval Guard | root/prod app에 수동 승인·sync window 강제, 비승인 자동동기화 금지 |
| I-9064 | I | G4.2/G33 | P0-BLOCKER | Kafka Commit Semantics Config Freeze | consumer commit/isolation 핵심옵션을 설정/테스트로 고정해 버전 드리프트 차단 |
| U-9003 | U | G4.5/G12 | P0-BLOCKER | User MFA/Verification UX Flow | MFA 등록·복구코드·이메일 검증 상태를 사용자 UI에서 강제/가시화 |
| B-9133 | B | G4.5/G27 | P0-BLOCKER | Edge Auth Replay/Rate Distributed Store | replay/rate/idempotency 상태를 중앙 원자 저장소로 공유해 다중 edge 우회·불일치 0건 |
| B-9134 | B | G4.3/G27 | P0-BLOCKER | WS Origin Allowlist Enforcement | websocket `CheckOrigin`을 allowlist+환경설정으로 강제, 위반 요청 차단/감사 기록 |
| B-9135 | B | G4.5/G26 | P0-BLOCKER | Edge DB Pool/Timeout Guard | DB pool(max open/idle/lifetime) + statement timeout + saturation 메트릭/알람 적용 |
| B-9136 | B | G4.5/G26 | P0-BLOCKER | Edge DB Context Deadline Propagation | `context.Background()` DB 호출 제거, 요청/백그라운드 경로별 deadline·cancel을 강제 |
| I-9065 | I | G5.2/G33 | P0-BLOCKER | OTel Sampling Budget Fail-Closed | prod tracing 샘플링 비율 정책(상한/하한) 강제, 1.0 fail-open 기본값 금지 |
| I-9066 | I | G4.2/G26 | P0-BLOCKER | Core Graceful Shutdown + Drain | SIGTERM 시 gRPC drain→outbox flush→종료 절차 실행, kill-drain drill 통과 |
| I-9067 | I | G4.3/G13 | P0-BLOCKER | WS Alert Rules Pack | `ws_active_conns/ws_send_queue_p99/ws_dropped_msgs/ws_slow_closes` 알람 규칙과 runbook 연동 |
| I-9068 | I | G4.5/G27 | P0-BLOCKER | Redis Session Transport Hardening | Redis TLS/ACL/timeout을 필수화하고 insecure 연결 설정이면 프로덕션 부팅 실패 |
| B-9137 | B | G4.5/G27 | P0-BLOCKER | API-Key Enumeration/Bruteforce Guard | `unknown_key/missing_header` 경로도 rate-limit·지연·일관응답을 적용해 열거 공격 차단 |
| B-9138 | B | G4.3/G27 | P0-BLOCKER | WS Resume Input Validation Guard | RESUME 요청의 symbol/채널 입력을 allowlist·형식 검증하고 위반 요청 차단 |
| B-9139 | B | G4.3/G26 | P0-BLOCKER | Market-Data Cache Fail-Closed Policy | Redis 장애 시 cache 메모리 fallback 금지, degraded mode + 알람으로 수렴 |
| B-9140 | B | G4.5/G27 | P0-BLOCKER | Edge Duplicate Detection SQLSTATE Guard | 회원가입 duplicate 판정을 문자열이 아닌 SQLSTATE/driver code로 고정 |
| B-9141 | B | G4.1/G26 | P0-BLOCKER | Ledger ensureAccount Atomic Upsert | 계정 생성 경합을 `ON CONFLICT DO NOTHING` 업서트로 처리, unique 예외 누락 0건 |
| B-9142 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Ingress Input Guard | engine seq 입력에서 seq 음수/비정규 symbol을 거부하고 오염 이벤트를 격리 |
| I-9069 | I | G5.3/G27 | P0-BLOCKER | K8s Audit Secret Redaction Gate | audit policy에서 secret/configmap 본문 기록 금지 + 정책검증 게이트 통과 |
| I-9070 | I | G4.5/G27 | P0-BLOCKER | PodSecurity Version Pinning | namespace `enforce-version`을 명시 버전으로 고정하고 `latest` 사용 금지 |
| I-9071 | I | G4.5/G13 | P0-BLOCKER | Auth Failure Alert Rules Pack | `edge_auth_fail_total` reason별(unknown_key/bad_signature/replay) 급증 알람 + runbook 연동 |
| B-9143 | B | G4.4/G26 | P0-BLOCKER | Core Async Mutex Contention Guard | async gRPC 경로의 블로킹 mutex 제거(또는 actor 모델) + 고동시성 tail latency 회귀 0건 |
| B-9144 | B | G4.3/G4.4 | P0-BLOCKER | WS Metrics O(1) Aggregation Guard | `/metrics`가 connection 수와 무관한 복잡도로 응답, scrape 부하에서도 지연 SLO 유지 |
| B-9145 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Metric Semantics Guard | 심볼별 reconciliation 지표를 last-write 전역값 대신 라벨 기반으로 노출 |
| B-9146 | B | G4.5/G13 | P0-BLOCKER | Auth Failure Reason Metrics Guard | `unknown_key/bad_signature/replay/...` reason별 카운터/경보를 표준화 |
| B-9147 | B | G4.5/G12 | P0-BLOCKER | Session Payload Minimization | 세션 저장소에서 email 등 PII 제거, 최소 claim만 저장/검증 |
| B-9148 | B | G4.5/G13 | P0-BLOCKER | Auth Backend Error Semantics Guard | auth DB 오류를 credential 오류로 은닉하지 않고 5xx+알람으로 분리 처리 |
| I-9072 | I | G5.2/G33 | P0-BLOCKER | OTel Environment Tag Integrity | tracing 리소스의 `deployment.environment`를 환경별로 강제하고 `local` 하드코딩 금지 |
| I-9073 | I | G5.3/G33 | P0-BLOCKER | K8s Audit Volume Budget Gate | audit policy wildcard 축소 + 로그 볼륨/retention budget 초과 시 배포 차단 |
| B-9149 | B | G4.3/G26 | P0-BLOCKER | WS Command Plane Rate Guard | SUB/UNSUB/RESUME 명령에 per-conn token bucket을 적용하고 flood 시 표준 close code + 메트릭으로 차단 |
| B-9150 | B | G4.3/G26 | P0-BLOCKER | WS Duplicate SUB Snapshot Suppression | 동일 subscription 반복 SUB는 no-op/쿨다운 정책으로 처리해 snapshot 증폭 및 write 폭주를 방지 |
| B-9151 | B | G4.4/G26 | P0-BLOCKER | Edge State Lock Contention Isolation | `state.mu` 단일락을 도메인별 락/샤드로 분리하고 고동시성 부하에서 tail latency 회귀 0건 |
| B-9152 | B | G4.5/G27 | P0-BLOCKER | Session Token Hash-at-Rest Guard | 세션 저장소에 raw token 저장 금지, 해시 조회+상수시간 비교로 토큰 유출면 축소 |
| I-9074 | I | G27/G33 | P0-BLOCKER | CI Security Scan Fail-Closed | Trivy secret/vuln high+critical 검출 시 PR 실패(승인된 allowlist 예외만 허용) |
| I-9075 | I | G27/G33 | P0-BLOCKER | SARIF Security Event Gate | SARIF를 code scanning에 업로드하고 미해결 high/critical 이슈 존재 시 merge 차단 |
| I-9076 | I | G4.5/G33 | P0-BLOCKER | Secret Rotation Drill Realism Gate | `secret_rotation_drill.sh`를 실제 시크릿 스토어 API 증거 기반으로 전환하고 simulation-only 모드 금지 |
| B-9153 | B | G4.2/G5.1 | P0-BLOCKER | Kafka Partition Key Determinism Guard | trade 이벤트 key를 심볼/샤드 전략으로 고정해 multi-partition에서도 심볼별 seq 단조성을 보장 |
| B-9154 | B | G4.1/G4.2 | P0-BLOCKER | Core gRPC Domain Error Classification Guard | 도메인 reject/권한 오류를 `INTERNAL`로 은닉하지 않고 상태코드 매핑 계약 + 재시도 정책 테스트 통과 |
| B-9155 | B | G4.5/G27 | P0-BLOCKER | Session Revocation Index + Active Session Cap | 사용자별 활성 세션 상한, revoke-all watermark, 탈취 세션 즉시 무효화 E2E 검증 |
| B-9156 | B | G4.5/G27 | P0-BLOCKER | API Secret Quality/Expiry Guard | API secret 최소 길이·entropy·만료 메타를 강제하고 약한/만료 키는 인증 단계에서 차단 |
| B-9157 | B | G4.1/G26 | P0-BLOCKER | Reconciliation History Query Efficiency Guard | 전역 최신조회 인덱스 + cursor pagination + 조회 rate-limit으로 고빈도 폴링 부하를 제어 |
| B-9158 | B | G4.2/G26 | P0-BLOCKER | Core Recent-Events Memory Cap Guard | `recent_events`를 bounded ring buffer로 전환해 장시간 운용 메모리 상한을 유지 |
| I-9077 | I | G4.2/G33 | P0-BLOCKER | Multi-Partition Ordering Chaos Gate | partition>1 토픽에서 chaos replay를 실행해 심볼별 seq 단조성·중복/역행 0건을 CI 게이트로 강제 |
| I-9078 | I | G4.5/G33 | P0-BLOCKER | Session Revocation Consistency Drill | 다중 edge 인스턴스에서 logout-all/revoke-all 후 구토큰 요청이 전부 차단됨을 드릴로 증명 |
| I-9079 | I | G4.5/G33 | P0-BLOCKER | API Secret Expiry Inventory Gate | key owner/created_at/expires_at 인벤토리와 만료 임박 알람을 릴리즈 게이트에 연동 |
| B-9159 | B | G4.3/G27 | P0-BLOCKER | WS Error Contract Sanitization Guard | WS Error frame에서 내부 `err.Error()` 노출 금지, 표준 오류코드/사유코드 계약으로 고정 |
| B-9160 | B | G4.1/G4.2 | P0-BLOCKER | Kafka Numeric Serialization Fail-Closed Guard | producer 직렬화 수치 파싱 실패를 `0`으로 강등하지 않고 이벤트 발행 실패/격리로 처리 |
| B-9161 | B | G4.5/G26 | P0-BLOCKER | Ledger DB Pool/Timeout Guard | ledger datasource pool 상한/수명/statement timeout과 saturation·slow-query 알람을 강제 |
| I-9080 | I | G27/G33 | P0-BLOCKER | CI SARIF Upload Permission Gate | workflow `security-events: write` 권한 + SARIF 업로드 스텝을 강제하고 실패 시 PR 차단 |
| I-9081 | I | G4.2/G30 | P0-BLOCKER | Network Partition Chaos Gate | core↔ledger, edge↔core network partition/복구 시나리오를 표준 chaos에 포함하고 invariants/recon 합격 필수화 |
| I-9082 | I | G33 | P0-BLOCKER | CI Timeout/Concurrency Guard | 모든 장기 job timeout과 브랜치 concurrency cancel-in-progress를 적용해 stale green 0건 보장 |
| I-9083 | I | G4.5/G27 | P0-BLOCKER | Edge TLS Termination + Cert Rotation Gate | ingress TLS 필수화, cert 만료 모니터링/회전 드릴 증거 없으면 릴리즈 차단 |
| B-9162 | B | G4.3/G5.1 | P0-BLOCKER | WS Resume Durable Buffer Guard | trades resume는 in-memory 1024 고정창을 넘는 구간도 내구 저장소 기반 range replay로 복구 |
| B-9163 | B | G4.5/G27 | P0-BLOCKER | Edge Symbol Canonicalization Guard | 주문/WS/market-data 전 경로에서 symbol canonical form/allowlist를 단일 규칙으로 강제 |
| B-9164 | B | G4.3/G26 | P0-BLOCKER | Public Market Data Rate-Limit Guard | `/v1/markets/*`에 IP tier rate-limit/caching/429 정책을 적용해 scrape 폭주를 차단 |
| I-9084 | I | G27/G33 | P0-BLOCKER | Security Baseline Unfixed Policy Gate | `ignore-unfixed` 예외목록+만료정책을 도입하고 기본값은 fail-closed로 운영 |
| I-9085 | I | G4.3/G13 | P0-BLOCKER | Market Data Abuse Drill Gate | 공개 market-data API/WS에 대해 scrape/flood 드릴을 자동화하고 알람/제한정책 합격을 필수화 |
| B-9165 | B | G4.3/G5.1 | P0-BLOCKER | WS Resume Subscription Isolation Guard | RESUME 재전송은 현재 구독 채널만 전달하고 book/candle/ticker 재동기화는 채널별 정책으로 분리 |
| B-9166 | B | G4.3/G26 | P0-BLOCKER | Edge Order Map Lifecycle Guard | 완료/취소 주문을 TTL·아카이브로 정리해 `state.orders` 메모리 상한과 조회 일관성을 유지 |
| B-9167 | B | G4.2/G27 | P0-BLOCKER | Kafka Env Namespace Guard | topic/group-id를 환경·리전 접두사로 네임스페이스하고 충돌 시 부팅/배포를 차단 |
| B-9168 | B | G4.5/G27 | P0-BLOCKER | Redis Key Namespace Isolation Guard | session/cache/replay/idempotency key에 env+service prefix를 강제해 keyspace 충돌 0건 보장 |
| B-9169 | B | G4.5/G26 | P0-BLOCKER | Session Expiry GC Sweep Guard | `sessionsMemory` 만료 세션을 접근 여부와 무관하게 주기 청소하고 장기 런에서 메모리 증가율 budget을 충족 |
| B-9170 | B | G4.5/G26 | P0-BLOCKER | Replay/Idempotency O(1) Eviction Guard | `isReplay/idempotencyGet`의 전맵 스캔 제거(타임휠/버킷/heap)로 인증 hot-path 락경합과 p99 급등을 차단 |
| B-9171 | B | G4.5/G27 | P0-BLOCKER | Auth Cache Secret-Minimization Guard | 메모리 사용자 캐시에 `password_hash` 보관 금지, 인증 이후 민감 필드는 즉시 제거/비노출 |
| B-9172 | B | G4.5/G27 | P0-BLOCKER | Trade API Dual-Key Rate Guard | 주문/취소 경로에 `principal+IP` 이중 rate limit을 적용해 키공유/단일 IP 폭주를 동시 차단 |
| B-9173 | B | G4.1/G27 | P0-BLOCKER | Cancel Symbol Fallback Removal Guard | cancel 경로의 `BTC-KRW` 기본 fallback 제거, 주문 symbol 미확정 시 fail-closed + audit로 처리 |
| B-9174 | B | G4.2/G33 | P0-BLOCKER | Ledger Consumer Concurrency Determinism Guard | settlement/reconciliation consumer 동시성 정책(파티션-워커 매핑, concurrency=1 기본)을 고정하고 회귀 테스트로 보증 |
| B-9175 | B | G4.5/G27 | P0-BLOCKER | Password Hash Policy + Rehash Guard | bcrypt cost/알고리즘 정책을 설정화하고 약한 해시는 로그인 시 재해시, 정책 미달 해시 로그인 차단 |
| B-9176 | B | G4.3/G26 | P0-BLOCKER | WS Queue Byte Budget Guard | per-conn send/conflated 큐에 메시지 개수뿐 아니라 바이트 상한을 적용하고 초과 시 표준 close+메트릭 기록 |
| B-9177 | B | G4.2/G27 | P0-BLOCKER | Kafka Payload Size Contract Guard | trade 이벤트 payload 크기 상한·스키마 검증을 강제하고 초과/오염 메시지는 격리(DLT) 처리 |
| B-9178 | B | G4.3/G26 | P0-BLOCKER | Channel-Specific Query Limit Guard | `/markets/*`의 `limit/depth`를 채널별 상한으로 강제하고 과대 요청은 fallback이 아닌 4xx로 거부 |
| B-9179 | B | G4.5/G27 | P0-BLOCKER | Session Idle+Absolute Lifetime Guard | 세션에 idle timeout + absolute max lifetime를 동시에 적용하고 재사용 토큰 수명 연장을 제한 |
| B-9180 | B | G4.5/G26 | P0-BLOCKER | User/Auth Cache TTL+Quota Guard | `usersByEmail/usersByID` 캐시에 TTL/용량 상한/LRU를 적용해 사용자 카디널리티 증가 시 메모리 상한 유지 |
| B-9181 | B | G4.5/G27 | P0-BLOCKER | Auth Signature Canonical Query Guard | 서명 canonical에 raw query/content-type/body-digest를 포함해 쿼리 변조·재서명 우회 시도를 차단 |
| B-9182 | B | G4.2/G26 | P0-BLOCKER | Trade Dedupe Eviction Hot-Path Guard | `markTradeApplied`의 전맵 청소를 O(1) 만료구조로 교체해 고체결 구간 락경합과 p99 급등을 방지 |
| B-9183 | B | G5.3/G32 | P0-BLOCKER | Correction Mode Enum Validation Guard | correction 요청 생성 시 허용 mode(`REVERSAL` 등)만 수용하고 미지원 mode는 사전 거부/감사 기록 |
| B-9184 | B | G4.5/G26 | P0-BLOCKER | Ledger Balance Listing Pagination Guard | `/v1/balances`·admin balance 조회를 cursor pagination/limit 상한으로 전환해 대량 스캔·응답폭주 차단 |
| B-9185 | B | G4.2/G26 | P0-BLOCKER | Retryable DB Error Classification Guard | deadlock/serialization timeout은 재시도 큐로 분리하고 비재시도 오류만 DLQ로 격리해 데이터 손실 0건 보장 |
| B-9186 | B | G4.1/G27 | P0-BLOCKER | Core Symbol Canonicalization Guard | core 명령 `meta.symbol`을 canonical form으로 정규화·검증해 case/format 편차로 인한 오거부·오처리를 제거 |
| B-9187 | B | G4.5/G27 | P0-BLOCKER | Ledger DTO Boundary Validation Guard | Ledger API DTO에 길이/형식/범위 제약(`@Valid`)을 적용하고 malformed 입력을 경계에서 4xx로 차단 |
| B-9188 | B | G4.5/G27 | P0-BLOCKER | Signup Password Strength Guard | 비밀번호 최소 길이 외에 복잡도/금지목록/재사용 정책을 적용하고 약한 비밀번호 등록을 차단 |
| I-9086 | I | G4.1/G33 | P0-BLOCKER | Invariant Alert Retention Gate | `invariant_alerts` retention/dedup/인덱스 정책과 housekeeping 잡을 CI/운영 게이트로 고정 |
| I-9087 | I | G4.2/G33 | P0-BLOCKER | Cross-Env Messaging Isolation Drill | 공유 Kafka/Redis 환경에서 dev/staging/prod 간 메시지·키 충돌이 없음을 드릴로 증명 |
| I-9088 | I | G10/G33 | P0-BLOCKER | Branch Protection Enforcement Gate | `main`에 required checks/required approvals/rebase(or merge-queue) 정책이 없으면 릴리즈 파이프라인 차단 |
| I-9089 | I | G10/G32 | P0-BLOCKER | CODEOWNERS Critical Path Gate | core/ledger/infra/security 경로는 CODEOWNERS 승인 없이는 병합 불가를 저장소 정책으로 강제 |
| I-9090 | I | G4.2/G33 | P0-BLOCKER | Migration Rollback Rehearsal Gate | 마이그레이션을 snapshot clone에 적용→롤백/복구 리허설까지 자동 실행, 실패 시 배포 차단 |
| I-9091 | I | G4.5/G10 | P0-BLOCKER | Runtime Env Parse Strictness Gate | 숫자/불리언/시크릿 환경변수 파싱 실패를 기본값으로 강등하지 않고 부팅 실패(fail-closed) 처리 |
| I-9092 | I | G4.4/G33 | P0-BLOCKER | 24h Soak Stability Gate | 주문+WS+consumer 장시간(예: 24h) soak에서 메모리/FD/고루틴 누수 budget 위반 시 릴리즈 차단 |
| I-9093 | I | G10/G33 | P0-BLOCKER | Repo Policy Drift Monitor Gate | branch protection/CODEOWNERS/required-checks 설정 드리프트를 주기 검사하고 미준수 시 릴리즈 차단 |
| I-9094 | I | G4.2/G33 | P0-BLOCKER | Kafka Message-Size Policy Alignment Gate | broker/topic/producer/consumer의 message-size 설정을 일관 검증하고 불일치 시 배포 차단 |
| I-9095 | I | G4.3/G33 | P0-BLOCKER | WS Long-Run Soak Gate | mixed slow/fast client 장시간 soak(예: 6h/24h)에서 ws queue/drop/close/memory SLO를 검증해 회귀 차단 |
| I-9096 | I | G4.5/G27 | P0-BLOCKER | K8s Workload SecurityContext Gate | runAsNonRoot/readOnlyRootFilesystem/capDrop/seccomp를 워크로드 표준으로 강제하고 미준수 배포 차단 |
| I-9097 | I | G4.5/G26 | P0-BLOCKER | gRPC Health Probe Contract Gate | core/내부 gRPC 서비스에 표준 health checking API를 노출하고 readiness/liveness probe와 연동 |
| I-9098 | I | G4.2/G33 | P0-BLOCKER | DB Expand-Contract Migration Gate | 스키마 변경을 expand/contract 2단계로 강제하고 구·신 버전 동시 가동 호환성 테스트 통과 |
| I-9099 | I | G4.2/G23 | P0-BLOCKER | Backup Encryption + Key Rotation Drill Gate | 백업 아티팩트 암호화/KMS 키버전 메타를 강제하고 복구+키회전 리허설을 주기 자동 검증 |
| I-9100 | I | G4.5/G33 | P0-BLOCKER | Auth Canonicalization Contract Test Gate | query/body/header 변형 공격 벡터에 대한 서명검증 회귀 테스트를 CI 필수 게이트로 고정 |
| I-9101 | I | G4.5/G33 | P0-BLOCKER | Auth/Session Memory Soak Gate | 인증/세션 트래픽 장시간 soak에서 `sessions/replay/idempotency/user-cache` 메모리·latency budget 준수 검증 |
| B-9189 | B | G4.2/G24 | P0-BLOCKER | Sequence Overflow/Rollover Guard | core/ledger seq 카운터 overflow/rollover를 사전 탐지하고 fail-closed로 차단 |
| B-9190 | B | G4.1/G24 | P0-BLOCKER | Trade/Settlement ID Global Uniqueness Guard | `trade_id/settlement_id` 전역 고유성(파티션/일자 무관) DB 제약과 회귀테스트로 보장 |
| B-9191 | B | G4.1/G5.3 | P0-BLOCKER | Symbol Mode Propagation Consistency Guard | mode 전환이 core 상태·outbox 이벤트·admin 조회모델에 원자 반영되고 불일치 0건 유지 |
| B-9192 | B | G4.1/G26 | P0-BLOCKER | Cancel-All Atomicity/Resume Guard | cancel-all 중 장애 발생 시 부분취소 상태 없이 재시도로 수렴하고 복구 후 open-order 누락 0건 |
| B-9193 | B | G4.1/G24 | P0-BLOCKER | Orphan Hold Leak Detection Guard | open-order 없는 hold 잔여를 주기 스캔해 누수 budget 0건 유지, 발견 시 자동 격리/증거 생성 |
| B-9194 | B | G4.2/G28 | P0-BLOCKER | Deterministic Tie-Break Guard | 가격동일 주문의 우선순위가 wall-clock 지터와 무관하게 deterministic replay에서 동일해야 함 |
| B-9195 | B | G4.5/G27 | P0-BLOCKER | Signed Timestamp Window Guard | 서명요청 timestamp skew/nonce 재사용 정책을 강제해 재전송·시계조작 공격을 차단 |
| I-9102 | I | G4.2/G23 | P0-BLOCKER | Postgres PITR Drill Gate | 지정 시점(point-in-time) 복구 리허설을 정기 실행하고 복구 후 invariants/recon 통과 강제 |
| I-9103 | I | G4.2/G27 | P0-BLOCKER | Kafka ACL Drift Audit Gate | topic/group ACL 최소권한 정책 드리프트를 주기 검증하고 위반 시 배포 차단 |
| I-9104 | I | G4.4/G33 | P0-BLOCKER | Observability Cardinality Budget Gate | 메트릭 라벨 카디널리티 예산 초과를 CI/운영에서 감지해 스크랩 지연·OOM 회귀를 차단 |
| I-9105 | I | G13/G33 | P0-BLOCKER | Alert-Runbook Coverage Gate | P0/P1 알람 100%에 owner/escalation/runbook 링크가 존재해야 게이트 통과 |
| I-9106 | I | G27/G33 | P0-BLOCKER | Build Provenance Verification Gate | 빌드 provenance/SBOM/서명 산출물을 검증하고 위변조·누락 시 배포 차단 |
| I-9107 | I | G27/G13 | P0-BLOCKER | TLS Certificate Lifecycle Gate | 인증서 만료/갱신/폐기(OCSP/CRL 포함) 드릴을 자동화하고 실패 시 온콜 알람 |
| I-9108 | I | G5.2/G13 | P0-BLOCKER | Time Sync Integrity Gate | NTP/PTP step/leap 감지 및 허용치 초과 시 거래/정산 경로 보호모드 전환 |
| I-9109 | I | G25/G31 | P0-BLOCKER | External Audit Anchor Gate | 감사 hash-chain root를 외부 불변 저장소에 주기 앵커링하고 검증 실패 시 사고 처리 |
| B-9196 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Event-Time Drift Guard | lag 판정에 event-time/processing-time 드리프트를 함께 반영해 정지·지연 오탐을 분리하고 안전모드 사유를 표준화 |
| B-9197 | B | G25/G31 | P0-BLOCKER | Ledger Posting Hash-Chain Guard | ledger posting에 이전 해시 체인을 부여해 DB 내부 변조를 탐지하고 검증 실패 시 즉시 읽기제한/사고모드 전환 |
| B-9198 | B | G10/G33 | P0-BLOCKER | API Schema Compatibility Guard | 공개 API/이벤트 스키마의 breaking change를 계약테스트로 차단하고 버전별 deprecation 창구를 강제 |
| B-9199 | B | G5.0/G24 | P0-BLOCKER | Cancel-Replace Atomicity Guard | 주문 정정(cancel-replace) 경로를 원자 처리해 부분취소/중복주문 상태를 남기지 않고 재시도 시 동일 결과 보장 |
| B-9200 | B | G5.1/G26 | P0-BLOCKER | Symbol Halt Reason Propagation Guard | `HALT/CANCEL_ONLY` 전환 사유코드를 WS/API/감사로그에 일관 전파해 운영자·고객 관측 불일치 0건 보장 |
| B-9201 | B | G4.2/G21 | P0-BLOCKER | DLQ Replay Ordering Guard | DLQ 재처리 시 심볼·seq 순서를 보존하고 out-of-order 재적용을 차단해 재처리 후 해시 동일성 유지 |
| B-9202 | B | G4.2/G33 | P0-BLOCKER | Read Model Rebuild Parity Guard | 주문/잔고 조회모델 재빌드 결과가 원장 기준 checksum과 일치해야 하며 불일치 시 서비스 승격 차단 |
| B-9203 | B | G5.0/G19 | P0-BLOCKER | Fee Schedule Effective-Time Guard | 수수료 정책 발효시각이 단조 증가하며 과거시점 소급/중복발효를 금지하고 정산 결과 재현성을 보장 |
| A-9010 | A | G10/G32 | P0-BLOCKER | Admin Change Ticket Binding Guard | 고위험 admin 액션은 RFC/incident ticket ID 바인딩 없이는 실행 불가, 실행내역에 변경근거 링크 필수 |
| A-9011 | A | G5.3/G32 | P0-BLOCKER | Admin Bulk Action Dry-Run Guard | 대량 취소/모드변경 전 dry-run diff/영향건수 확인을 강제하고 승인화면에 checksum을 고정 표시 |
| I-9110 | I | G5.1/G33 | P0-BLOCKER | ClickHouse Schema Drift Gate | candle/trade 조회 스키마 드리프트를 마이그레이션 검증으로 탐지하고 쿼리 호환성 실패 시 배포 차단 |
| I-9111 | I | G12/G25 | P0-BLOCKER | Legal Hold Retention Gate | 사고/분쟁 건의 로그·이벤트·원장 데이터에 legal hold를 적용해 TTL 삭제에서 예외 처리하고 감사추적 보존 |
| I-9112 | I | G4.2/G30 | P0-BLOCKER | Network Impairment Chaos Gate | partition뿐 아니라 지연·패킷손실·중복전송 장애를 주입해 복구 후 invariants/recon 통과를 필수화 |
| I-9113 | I | G27/G33 | P0-BLOCKER | Reproducible Build Gate | 동일 소스/동일 입력에서 동일 아티팩트 해시를 재현하고 불일치 빌드는 승격 차단 |
| I-9114 | I | G27/G33 | P0-BLOCKER | Security Exception Expiry Gate | CVE/정책 예외는 만료일·승인자·완화조치가 없으면 적용 불가, 만료 초과 시 자동 배포 차단 |
| I-9115 | I | G8/G13 | P0-BLOCKER | Key Usage Anomaly Detection Gate | API/서명키 사용 패턴 급변(지역/시간대/빈도)을 탐지해 자동 키잠금·추가승인 흐름으로 연결 |
| I-9116 | I | G23/G13 | P0-BLOCKER | Cross-Region Sequence Audit Gate | active/passive 전환 후 core/ledger seq 연속성과 시계편차를 교차검증하고 불일치 시 트래픽 승격 차단 |
| B-9204 | B | G4.2/G27 | P0-BLOCKER | Kafka Event Signature Verification Guard | core 이벤트에 producer 서명/해시를 부여하고 ledger/edge가 검증 실패 메시지를 즉시 격리 |
| B-9205 | B | G4.2/G24 | P0-BLOCKER | Outbox-WAL Atomic Boundary Guard | 명령 내구화(WAL)와 outbox enqueue의 경계가 원자적으로 보장되어 한쪽만 반영되는 상태를 금지 |
| B-9206 | B | G4.1/G24 | P0-BLOCKER | Settlement Isolation-Level Guard | settlement 트랜잭션이 직렬화 규칙(또는 동등한 충돌검출)을 강제해 동시성 이상으로 잔고가 깨지지 않음 |
| B-9207 | B | G5.0/G24 | P0-BLOCKER | Cross-Symbol Exposure Netting Guard | 계정 노출도 계산이 심볼별/전체 net exposure 규칙을 동시에 만족하고 한도우회 주문을 차단 |
| B-9208 | B | G4.2/G26 | P0-BLOCKER | Restart Read-Only Warmup Guard | 재기동 직후 catch-up 완료 전에는 mutating API를 read-only로 제한하고 동기화 완료 후에만 해제 |
| B-9209 | B | G12/G25 | P0-BLOCKER | Account Closure & Erasure Guard | 계정해지/삭제요청 시 보존의무 데이터와 삭제대상 데이터를 분리 처리하고 감사증적을 자동 생성 |
| B-9210 | B | G22/G27 | P0-BLOCKER | Withdrawal Address Integrity Guard | 출금주소는 체인별 포맷/체크섬/태그 규칙을 검증하고 whitelist 변경은 승인·타임락을 강제 |
| B-9211 | B | G10/G32 | P0-BLOCKER | Admin API Key Rotation Idempotency Guard | admin 키 회전/폐기 API가 재시도에도 단일 결과를 보장하고 이전 키 재활성화를 금지 |
| B-9212 | B | G4.5/G26 | P0-BLOCKER | Rate-Limit State Durability Guard | 재기동/스케일아웃 이후에도 principal/IP 제한 상태가 유지되어 rate-limit 우회 윈도우가 발생하지 않음 |
| A-9012 | A | G5.3/G32 | P0-BLOCKER | Multi-Approver Quorum Policy Guard | 액션 위험등급별 승인 정족수(1/2/3인)를 UI/백엔드에서 강제하고 우회 승인 불가 |
| A-9013 | A | G13/G32 | P0-BLOCKER | Emergency Action Reason Enforcement Guard | HALT/WITHDRAW_HALT 등 긴급조치는 표준 사유코드·영향범위·복구계획 입력 없이는 실행 불가 |
| I-9117 | I | G13/G33 | P0-BLOCKER | GameDay SLO Compliance Gate | 월간 게임데이에서 MTTD/MTTR/SLA 목표 미달 시 릴리즈 승격 차단 |
| I-9118 | I | G4.5/G26 | P0-BLOCKER | Startup Dependency Order Gate | core/ledger/kafka/db 의존성 시작순서 검증과 readiness 의존 관계를 강제해 부팅 레이스를 차단 |
| I-9119 | I | G27/G33 | P0-BLOCKER | Third-Party Dependency Risk Gate | 외부 라이브러리/서비스 위험도 인벤토리(SBOM+취약점+EOL)를 주기 평가해 임계치 초과 시 배포 차단 |
| I-9120 | I | G4.2/G23 | P0-BLOCKER | Restore Differential Verification Gate | 백업 복구 후 원본 대비 핵심 테이블/해시 diff를 자동 검증해 silent corruption을 탐지 |
| I-9121 | I | G12/G25 | P0-BLOCKER | Privacy Deletion SLA Gate | 개인정보 삭제요청(법적 예외 제외)의 처리기한/SLA를 추적하고 지연 시 자동 경보·보고 |
| I-9122 | I | G13/G33 | P0-BLOCKER | Incident Postmortem SLA Gate | SEV 사고 포스트모템(원인/재발방지/소유자/기한) 미작성·미완료 상태에서 릴리즈 승격 차단 |
| I-9123 | I | G10/G33 | P0-BLOCKER | Feature-Flag Change Audit Gate | 운영 플래그 변경은 승인·만료·롤백정보를 필수 기록하고 무감사 플래그 변경을 차단 |
| B-9213 | B | G31/G33 | P0-BLOCKER | Safety Bundle Manifest Integrity Guard | evidence bundle에 파일별 해시 manifest+서명을 포함하고 검증 실패 산출물은 릴리즈 증적으로 채택 금지 |
| B-9214 | B | G24/G32 | P0-BLOCKER | Tenant Scope Propagation Guard | API→core→ledger 전 경로에서 tenant/account scope 누락을 차단해 교차계정 데이터 접근 0건 보장 |
| B-9215 | B | G4.2/G26 | P0-BLOCKER | DLQ Replay Loop Prevention Guard | 동일 poison 이벤트의 무한 재처리 루프를 차단하고 최대 재시도 초과 시 격리상태를 명확히 표기 |
| B-9216 | B | G5.1/G26 | P0-BLOCKER | WS Snapshot Checksum Guard | snapshot payload에 checksum/version을 포함하고 클라이언트·서버가 mismatch를 즉시 감지/재동기화 |
| B-9217 | B | G5.1/G17 | P0-BLOCKER | Orderbook Delta Continuity Guard | depth별 delta sequence 연속성 검증을 강제해 누락/역행 delta가 book 상태를 오염시키지 않음 |
| B-9218 | B | G5.0/G19 | P0-BLOCKER | Fee Rounding Invariant Guard | 부분체결·다중수수료 자산 시나리오에서 수수료 반올림 누계오차가 계정 단위 불변조건을 위반하지 않음 |
| B-9219 | B | G4.1/G27 | P0-BLOCKER | Distributed Idempotency Clock-Skew Guard | 멀티노드 시간편차에서도 idem TTL 판정이 일관되도록 monotonic time source/lease 기반 검증을 강제 |
| B-9220 | B | G26/G32 | P0-BLOCKER | Recovery-Mode Write Fence Guard | 복구모드(READ_ONLY/DEGRADED)에서는 승인된 운영 액션 외 쓰기 API가 절대 실행되지 않도록 차단 |
| B-9221 | B | G12/G25 | P0-BLOCKER | Evidence Bundle PII Scrub Guard | evidence/safety-case 번들에 PII/비밀정보 포함을 자동 스캔하고 검출 시 번들 생성 실패 처리 |
| B-9222 | B | G4.1/G24 | P0-BLOCKER | Settlement Reversal Causality Guard | reversal/correction posting은 원거래 인과관계 링크가 필수이며 orphan reversal 생성이 불가능해야 함 |
| A-9014 | A | G4.5/G32 | P0-BLOCKER | Safety Latch Release Dual-Confirm Guard | safety latch 해제는 2인 승인 + 재확인 단계(impact summary 확인)를 통과해야만 실행 가능 |
| A-9015 | A | G4.5/G32 | P0-BLOCKER | Admin Step-Up Reauth Guard | 고위험 액션 직전 운영자 step-up 재인증(MFA 재검증/짧은 TTL)을 강제해 세션 탈취 오남용 차단 |
| I-9124 | I | G4.2/G30 | P0-BLOCKER | Kafka Disk-Pressure Chaos Gate | broker disk-full/segment quota 초과 시나리오를 주입하고 producer/consumer 복구 후 정합성 통과를 검증 |
| I-9125 | I | G21/G25 | P0-BLOCKER | WORM Object-Lock Enforcement Gate | 증적/감사 아카이브 버킷에 object-lock/retention 정책을 강제하고 변경 시도는 감사지표로 즉시 탐지 |
| I-9126 | I | G23/G27 | P0-BLOCKER | Backup Restore Isolation Account Gate | 백업 복구는 격리된 복구계정/네트워크에서만 수행되고 프로덕션 자격증명 공유가 없음을 주기 검증 |
| I-9127 | I | G10/G33 | P0-BLOCKER | Runtime Drift Detection Gate | 실제 클러스터 런타임 설정이 Git 선언과 다르면 drift 경보/배포차단이 동작하도록 상시 검증 |
| I-9128 | I | G13/G33 | P0-BLOCKER | Synthetic Canary Trade Monitor Gate | 정기 합성 주문→체결→정산→조회 경로를 자동 실행해 실패 시 즉시 경보 및 안전모드 연동 |
| I-9129 | I | G25/G31 | P0-BLOCKER | Signed Log Timestamp Gate | 핵심 감사로그에 서명된 타임스탬프를 부여해 사후 시간조작/재정렬 의혹을 독립 검증 가능하게 유지 |
| I-9130 | I | G27/G32 | P0-BLOCKER | Secret Access Audit Completeness Gate | secret read/write 접근 이벤트가 100% 감사기록에 남고 누락 시 보안게이트 실패 처리 |
| I-9131 | I | G13/G33 | P0-BLOCKER | Paging Delivery SLO Probe Gate | synthetic alert로 pager 전달 성공률/지연 SLO를 측정하고 미달 시 온콜 체계 승격 차단 |
| B-9223 | B | G4.1/G33 | P0-BLOCKER | Event Correlation Propagation Guard | 주문 요청의 correlation/causation ID가 edge→core→ledger→audit 전 경로에서 누락 없이 전파되어 추적 단절 0건 보장 |
| B-9224 | B | G21/G31 | P0-BLOCKER | Replay Source Traceability Guard | replay/rebuild 결과가 사용한 archive range·snapshot·commit hash를 증거에 고정해 재현 출처를 완전 추적 |
| B-9225 | B | G4.2/G28 | P0-BLOCKER | Settlement Batch Determinism Guard | 동일 입력 배치의 settlement 적용 순서/결과가 노드·재시작과 무관하게 동일해야 하며 해시 불일치 0건 |
| B-9226 | B | G4.2/G33 | P0-BLOCKER | WAL/Snapshot Schema Evolution Guard | 스키마 버전 업/다운 시 WAL·snapshot 호환성 검증을 통과하지 못하면 부팅/복구를 차단 |
| B-9227 | B | G5.0/G26 | P0-BLOCKER | Halt-Auction Transition Timer Guard | HALT→AUCTION→CONTINUOUS 전환 타이머/조건이 정책대로만 실행되고 수동개입은 감사추적을 남김 |
| B-9228 | B | G24/G27 | P0-BLOCKER | Mixed-Scale Balance Rejection Guard | 자산별 precision scale 불일치 입력은 경계에서 거부되어 단위 혼합으로 인한 잔고 오염을 방지 |
| B-9229 | B | G4.1/G25 | P0-BLOCKER | Reconciliation History Append-Only Guard | reconciliation history/safety 상태 변경은 append-only 이벤트로 남고 수정·삭제 시도는 즉시 탐지 |
| B-9230 | B | G22/G24 | P0-BLOCKER | Withdrawal Fingerprint Idempotency Guard | 동일 출금요청(계정/주소/금액/nonce) fingerprint를 강제해 재시도·중복 제출에서도 단일 효과 보장 |
| B-9231 | B | G5.0/G10 | P0-BLOCKER | Listing Effective-Date Guard | 상장/거래중지/폐지 상태는 발효시각 기반으로만 전환되고 조기·지연 적용이 없도록 검증 |
| B-9232 | B | G5.0/G28 | P0-BLOCKER | Risk Rule Determinism Guard | 동일 시장데이터/포지션 입력에서 risk policy 평가 결과가 노드별로 일치하고 플래그 race로 흔들리지 않음 |
| A-9016 | A | G5.3/G32 | P0-BLOCKER | Approval Conflict Visibility Guard | 다중 승인 경합/거절/만료 상태를 실시간 가시화해 운영자가 stale 승인으로 실행하지 못하도록 차단 |
| A-9017 | A | G13/G32 | P0-BLOCKER | Emergency Exit Checklist Guard | 긴급모드 해제 전 필수 점검항목(invariants/recon/lag/온콜승인) 체크리스트 완료 없이는 해제 불가 |
| I-9132 | I | G4.2/G30 | P0-BLOCKER | Consumer Rebalance Chaos Gate | Kafka consumer rebalance/fencing churn 상황을 주입해 중복적용·누락 없이 복구되는지 자동 검증 |
| I-9133 | I | G21/G33 | P0-BLOCKER | Archive Replay Throughput SLO Gate | 장기 archive replay 처리량/완료시간 SLO를 측정하고 기준 미달 시 복구게이트 실패 처리 |
| I-9134 | I | G21/G25 | P0-BLOCKER | Object Storage Lifecycle Drift Gate | 아카이브 버킷 lifecycle/retention 정책 drift를 주기검증해 의도치 않은 조기삭제를 차단 |
| I-9135 | I | G31/G33 | P0-BLOCKER | Control Evidence Freshness Gate | controls/assurance 증거의 최신성(TTL) 검증을 강제해 오래된 증거로 릴리즈 통과를 금지 |
| I-9136 | I | G23/G13 | P0-BLOCKER | Regional DNS Failover Drill Gate | 리전 장애 시 DNS/트래픽 전환 드릴을 정기 실행하고 전환시간 SLO 미달 시 승격 차단 |
| I-9137 | I | G5.2/G13 | P0-BLOCKER | Clock Source Redundancy Gate | 단일 시간원 의존을 제거하고 다중 NTP/PTP 소스 장애 시에도 안전모드 전환·알람이 동작 |
| I-9138 | I | G25/G36 | P0-BLOCKER | Compliance Export Reproducibility Gate | 동일 기간 규제 리포트 export 결과가 재실행마다 동일하며 차이는 서명된 변경사유로만 허용 |
| I-9139 | I | G25/G27 | P0-BLOCKER | SIEM Ingestion Completeness Gate | 보안/감사 이벤트가 SIEM으로 누락 없이 전달되는지 샘플링 검증하고 누락률 임계치 초과 시 차단 |
| B-9233 | B | G4.1/G13 | P0-BLOCKER | Safety Action Causality Binding Guard | 안전모드 전환/해제 액션은 원인 breach/invariant 이벤트 ID를 반드시 참조해 사후 인과관계 추적을 보장 |
| B-9234 | B | G4.1/G23 | P0-BLOCKER | Reconciliation Gap Backfill Guard | seq hole 탐지 후 backfill/replay 성공 전에는 정상모드 복귀를 금지하고 backfill 결과를 증거로 고정 |
| B-9235 | B | G24/G19 | P0-BLOCKER | Cross-Currency Conservation Guard | 환산/수수료 자산이 다른 체결에서도 기준통화 보존식이 깨지지 않음을 invariant로 상시 검증 |
| B-9236 | B | G5.3/G32 | P0-BLOCKER | Symbol Mode Cooldown Guard | HALT/CANCEL_ONLY/NORMAL 잦은 토글을 cooldown 정책으로 제한해 운영 오조작/진동 상태를 방지 |
| B-9237 | B | G28/G30 | P0-BLOCKER | Scheduler-Noise Determinism Guard | 스레드 스케줄 지터/랜덤 지연 주입 조건에서도 core replay state hash가 동일함을 반복 검증 |
| B-9238 | B | G5.1/G26 | P0-BLOCKER | Market Data Staleness Signaling Guard | feed 지연/정지 시 WS/API가 `stale` 신호와 마지막 업데이트 시각을 일관 표기해 오판 거래를 방지 |
| B-9239 | B | G12/G32 | P0-BLOCKER | Compliance Case State Machine Guard | KYT/AML 케이스가 `OPEN→REVIEW→ACTIONED→CLOSED` 전이를 강제하고 불법 전이를 차단 |
| B-9240 | B | G22/G23 | P0-BLOCKER | Chain Reorg Handling Guard | 온체인 reorg 발생 시 입금 확정/출금 상태를 재평가하고 이중 credit/조기 확정을 차단 |
| B-9241 | B | G4.2/G26 | P0-BLOCKER | Downstream Retry-Budget Guard | 외부 의존(DB/Kafka/KMS) 장애 시 무한 재시도 대신 retry-budget+circuit 정책으로 시스템 생존성 유지 |
| B-9242 | B | G5.0/G25 | P0-BLOCKER | Order Reject Reason Code Normalization Guard | 주문 거절 사유코드를 표준 taxonomy로 고정해 규제 리포트/감사 추적에서 의미 불일치 0건 보장 |
| A-9018 | A | G13/G32 | P0-BLOCKER | Safety Timeline Dashboard Guard | breach 탐지→안전모드 전환→복구승인까지 타임라인/근거 링크를 단일 화면에서 추적 가능하게 제공 |
| A-9019 | A | G13/G32 | P0-BLOCKER | Approval SLA Escalation Guard | 승인 대기 SLA 초과 건을 자동 에스컬레이션하고 누락 승인으로 위험 액션이 방치되지 않게 보장 |
| I-9140 | I | G27/G33 | P0-BLOCKER | Secret Leak Pre-Receive Gate | 저장소 push 단계에서 secret 패턴 검출 시 차단하고 우회승인은 만료/승인자/근거를 강제 |
| I-9141 | I | G5.2/G33 | P0-BLOCKER | Capacity Saturation Probe Gate | CPU/메모리/FD/디스크 임계치 근접 상황을 synthetic로 주입해 자동 제한/알람 동작을 검증 |
| I-9142 | I | G25/G31 | P0-BLOCKER | Audit Query Integrity Gate | 감사조회 결과가 원본 hash-chain 앵커와 일치함을 샘플링 검증해 조회 스토어 변조를 탐지 |
| I-9143 | I | G26/G33 | P0-BLOCKER | Cost Anomaly Budget Gate | Kafka/ClickHouse/S3 비용지표가 예산을 초과하면 자동 경보와 단계적 기능제한 정책을 발동 |
| I-9144 | I | G27/G33 | P0-BLOCKER | Dependency Pin Drift Gate | base image/외부 action/패키지 pin 드리프트를 탐지해 미승인 버전 승격을 차단 |
| I-9145 | I | G25/G36 | P0-BLOCKER | Regulatory Cutoff Calendar Gate | 일/월 마감 및 규제 제출 cut-off 달력을 시스템화해 누락·지연 제출을 배포 게이트로 차단 |
| I-9146 | I | G13/G33 | P0-BLOCKER | Incident Communication Drill Gate | 상태페이지/고객공지/내부보고 커뮤니케이션 훈련을 정기 자동 점검하고 미달 시 승격 차단 |
| I-9147 | I | G23/G33 | P0-BLOCKER | Region Evacuation Rehearsal Gate | 특정 리전 격리(evacuation) 시나리오를 정기 훈련해 트래픽 우회·데이터 정합성 유지 여부를 검증 |
| B-9243 | B | G4.2/G33 | P0-BLOCKER | Event Schema Hash Pinning Guard | producer/consumer가 허용된 schema hash 목록만 수용해 스키마 오염·임의 변형 payload를 차단 |
| B-9244 | B | G4.1/G26 | P0-BLOCKER | Reconciliation Symbol Enrollment Guard | 신규 상장/재상장 심볼이 대사 감시대상에 자동 등록되지 않으면 거래개시를 차단 |
| B-9245 | B | G4.2/G23 | P0-BLOCKER | Snapshot Restore Dry-Run Isolation Guard | 복구 dry-run이 실제 운영 DB/스토리지 상태를 변경하지 않음을 격리환경 검증으로 보장 |
| B-9246 | B | G5.3/G32 | P0-BLOCKER | Correction Blast-Radius Guard | correction 적용 전 영향 계정/자산/총액 상한을 계산해 임계치 초과 시 자동 2차 승인 요구 |
| B-9247 | B | G4.2/G24 | P0-BLOCKER | Settlement Journal Gap Marker Guard | settlement 입력 누락 구간을 journal gap marker로 명시 기록하고 해소 전 마감/복귀를 금지 |
| B-9248 | B | G4.3/G27 | P0-BLOCKER | WS Resume Anti-Replay Nonce Guard | RESUME 요청 nonce/TTL을 검증해 캡처된 재연결 요청 재사용 공격을 차단 |
| B-9249 | B | G4.3/G26 | P0-BLOCKER | Fanout Rebalance Consistency Guard | WS 샤드 리밸런싱 중 중복전송·누락 없이 연결 이전이 완료되고 seq 연속성이 유지됨을 보장 |
| B-9250 | B | G12/G24 | P0-BLOCKER | Account Lock Propagation Latency Guard | 계정 동결/해제 명령이 주문·출금·세션 경로에 SLA 내 전파되지 않으면 자동 경보/차단 |
| B-9251 | B | G5.0/G26 | P0-BLOCKER | Liquidation Price-Band Coupling Guard | 강제청산/위험정리 주문도 가격밴드/서킷브레이커 규칙을 우회하지 못하도록 정책 결합 |
| B-9252 | B | G28/G33 | P0-BLOCKER | Deterministic Seed Governance Guard | 시뮬레이션/재현 실행의 난수 seed를 증거 번들에 고정하고 누락 seed 실행은 릴리즈 검증에서 거부 |
| A-9020 | A | G12/G32 | P0-BLOCKER | Compliance Case Queue SLA Board | AML/KYT 케이스 처리 대기시간·우선순위·에스컬레이션 상태를 운영 UI에서 실시간 관리 |
| A-9021 | A | G31/G32 | P0-BLOCKER | Evidence Attestation Console Guard | 릴리즈 증거 번들의 서명/검증상태/만료를 관리자 UI에서 확인하고 미검증 번들 승격을 차단 |
| I-9148 | I | G4.2/G30 | P0-BLOCKER | Kernel Fault Chaos Gate | 디스크 I/O 지연/파일시스템 오류/프로세스 OOM-kill 주입 후 복구 정합성 통과를 자동 검증 |
| I-9149 | I | G4.2/G25 | P0-BLOCKER | Snapshot Checksum Escrow Gate | snapshot checksum 목록을 독립 저장소에 이중 보관해 백업 저장소 변조 시 교차검증으로 탐지 |
| I-9150 | I | G10/G33 | P0-BLOCKER | API Deprecation Deadline Gate | 폐기 예정 API의 종료 기한을 넘기면 빌드/배포를 차단하고 마이그레이션 상태를 강제 보고 |
| I-9151 | I | G23/G25 | P0-BLOCKER | Backup Catalog Integrity Gate | 백업 카탈로그(세대/암호화키/체크섬/보존기한)의 누락·불일치를 주기 점검해 복구 실패를 사전 차단 |
| I-9152 | I | G13/G33 | P0-BLOCKER | Oncall Handoff Continuity Gate | 교대 시 미해결 알람/사고 컨텍스트 인수인계 완료 여부를 검증하고 누락 시 온콜 체계 승격 차단 |
| I-9153 | I | G8/G27 | P0-BLOCKER | Token Signing Key Rollover Drill Gate | JWT/세션 서명키 회전 시 구키 grace/신키 발급/검증 실패 차단이 무중단으로 동작함을 정기 검증 |
| I-9154 | I | G4.1/G13 | P0-BLOCKER | Real-time Reconciliation SLO Gate | 대사 지표 수집·평가 주기 지연이 SLO를 초과하면 안전모드 판단 신뢰도 저하로 즉시 경보 발동 |
| I-9155 | I | G13/G33 | P0-BLOCKER | Multi-Channel Incident Delivery Gate | 사고 공지 채널(상태페이지/메일/웹훅) 다중 전달 성공률을 synthetic로 검증해 누락 공지를 차단 |
| B-9253 | B | G21/G33 | P0-BLOCKER | Data Lineage Checkpoint Guard | 주문→체결→정산→리포트 경로에 lineage checkpoint를 기록해 중간 변환 누락/분기를 자동 탐지 |
| B-9254 | B | G21/G27 | P0-BLOCKER | Replay Input Allowlist Guard | replay/rebuild 입력은 승인된 archive/snapshot source만 허용하고 임의 파일 주입을 차단 |
| B-9255 | B | G26/G32 | P0-BLOCKER | Halt-Mode Order Intake Fence Guard | HALT 모드에서 신규 주문 유입 경로(REST/WS/internal)가 완전 차단되고 취소 경로만 허용 |
| B-9256 | B | G25/G36 | P0-BLOCKER | Ledger Posting Reason Taxonomy Guard | 모든 posting/correction에 표준 reason code를 필수화해 회계/감사 분류 불일치 0건 보장 |
| B-9257 | B | G10/G32 | P0-BLOCKER | Admin Override Expiry Guard | 운영자 override 권한은 TTL 만료 시 자동 회수되고 만료된 override로 실행이 불가능해야 함 |
| B-9258 | B | G23/G13 | P0-BLOCKER | Cross-Region Timestamp Monotonicity Guard | 리전간 이벤트 병합 시 timestamp monotonic 규칙을 강제해 역행 정렬로 인한 오탐/누락을 차단 |
| B-9259 | B | G4.2/G27 | P0-BLOCKER | Snapshot Encryption Context Binding Guard | snapshot 암호화 키는 환경/리전/서비스 컨텍스트에 바인딩되어 교차환경 복호화가 불가능해야 함 |
| B-9260 | B | G7/G19 | P0-BLOCKER | Portfolio Valuation Source Pinning Guard | 잔고평가/손익 계산의 가격 소스를 버전 고정해 동일 시점 재평가 결과가 항상 동일하도록 보장 |
| B-9261 | B | G5.0/G33 | P0-BLOCKER | Risk Rule Shadow-Eval Guard | 신규 risk 정책은 shadow 모드에서 실운영 트래픽으로 오탐률/누락률을 검증 후에만 활성화 |
| B-9262 | B | G13/G26 | P0-BLOCKER | User Notification Idempotency Guard | 동일 사고/모드전환 공지는 채널별 멱등키로 중복 발송을 방지하고 누락 없이 1회 이상 전달 |
| A-9022 | A | G10/G32 | P0-BLOCKER | Policy Diff Risk Heatmap Guard | 정책 변경 diff를 위험도(영향 계정/금액/심볼) 히트맵으로 시각화해 승인 전에 위험을 정량 검토 |
| A-9023 | A | G31/G32 | P0-BLOCKER | Incident Evidence Review Console Guard | 사고별 evidence bundle 검토·승인 상태를 UI로 추적하고 미검토 상태의 종결 처리를 차단 |
| I-9156 | I | G23/G33 | P0-BLOCKER | Restore Calendar Compliance Gate | 복구 리허설 캘린더(일간/주간/월간) 미이행이 발생하면 자동 경보 및 릴리즈 승격 차단 |
| I-9157 | I | G27/G32 | P0-BLOCKER | KMS Permission Drift Gate | KMS key policy/role binding drift를 주기 검증해 과권한/오권한 상태를 배포 전에 차단 |
| I-9158 | I | G12/G25 | P0-BLOCKER | Retention-Deletion Conflict Gate | legal hold/보존정책/삭제요청 충돌을 자동 판정해 정책 위반 삭제 또는 과보존을 차단 |
| I-9159 | I | G4.6/G33 | P0-BLOCKER | Cross-Service Contract Matrix Gate | edge-core-ledger 계약 테스트 매트릭스를 버전 조합별로 실행해 호환성 깨짐을 릴리즈 전에 차단 |
| I-9160 | I | G33 | P0-BLOCKER | Flaky Gate Quarantine Policy | 검증 파이프라인 flaky 테스트를 자동 탐지/격리하고 대체 게이트 없이 릴리즈 통과를 금지 |
| I-9161 | I | G13/G27 | P0-BLOCKER | Panic/CoreDump Handling Gate | 패닉/크래시 시 코어덤프 보안처리(암호화/접근제어/TTL)와 자동 수집 정책을 강제 |
| I-9162 | I | G25/G36 | P0-BLOCKER | Data Export Watermark Gate | 외부 제출용 리포트/CSV에 발급자·시각·해시 워터마크를 삽입해 2차 유출 추적성을 보장 |
| I-9163 | I | G4.4/G33 | P0-BLOCKER | Shadow Traffic Regression Gate | 배포 전 shadow traffic 비교로 응답코드/지연/정산결과 편차를 검증하고 임계치 초과 시 차단 |
| B-9263 | B | G4.1/G33 | P0-BLOCKER | Reconciliation Decision Snapshot Guard | 안전모드 판정 시 rule 입력/임계치/판정결과 스냅샷을 저장해 사후 explainability를 보장 |
| B-9264 | B | G4.1/G24 | P0-BLOCKER | Processed-Event Key Stability Guard | processed-events 멱등키 구성요소 변경 시 마이그레이션 검증 없이 배포를 차단해 중복반영 회귀를 방지 |
| B-9265 | B | G4.2/G33 | P0-BLOCKER | Binary-Restore Version Fence Guard | snapshot/WAL 복구 시 바이너리 호환 버전을 검증하고 미지원 버전 복구를 fail-closed로 차단 |
| B-9266 | B | G26/G32 | P0-BLOCKER | Kill-Switch Scope Isolation Guard | 심볼/채널별 kill-switch가 스코프 외 트래픽에 영향 주지 않도록 경계 격리를 강제 |
| B-9267 | B | G7/G19 | P0-BLOCKER | FX Source Attestation Guard | 환산(FX) 소스 버전/타임스탬프/서명을 저장해 정산·회계 재현 시 동일 입력을 보장 |
| B-9268 | B | G7/G19 | P0-BLOCKER | User Statement Reproducibility Guard | 사용자 거래명세서 생성 결과가 동일 기간 재생성 시 완전히 동일하도록 포맷/정렬/반올림 규칙을 고정 |
| B-9269 | B | G5.0/G24 | P0-BLOCKER | Fee Rebate Idempotency Guard | 수수료 리베이트/프로모션 정산이 재시도/재처리에도 1회 효과만 반영되도록 멱등키를 강제 |
| B-9270 | B | G12/G24 | P0-BLOCKER | Freeze-InFlight Race Guard | 계정 동결과 in-flight 주문/출금 처리 경합에서 동결 이후 신규 체결/출금이 발생하지 않도록 원자화 |
| B-9271 | B | G5.1/G17 | P0-BLOCKER | Market Data Replay Watermark Guard | 재연결/재시작 후 market data replay가 워터마크 이전 데이터만 재전송하고 중복 구간을 차단 |
| B-9272 | B | G25/G31 | P0-BLOCKER | DLQ Evidence Retention Guard | DLQ 레코드와 연관 증거(원본 offset/hash/error context)를 보존기간 동안 완전 추적 가능하게 유지 |
| A-9024 | A | G12/G32 | P0-BLOCKER | Compliance Override Review Queue Guard | 준법 override 요청은 전용 리뷰 큐에서만 처리되고 일반 운영 승인 플로우 우회를 차단 |
| A-9025 | A | G5.3/G32 | P0-BLOCKER | Dual-Control Timeout Auto-Revoke Guard | 승인 대기/타임락 초과 건은 자동 취소·권한 회수되어 만료 액션 실행을 방지 |
| I-9164 | I | G13/G30 | P0-BLOCKER | Randomized Disaster Drill Gate | 장애주입 시나리오의 시점/순서를 난수화해 고정 시나리오 최적화 회귀를 방지 |
| I-9165 | I | G13/G33 | P0-BLOCKER | Alert Noise Budget Gate | 경보 오탐률/중복률 예산을 측정하고 초과 시 규칙 튜닝 완료 전 승격 차단 |
| I-9166 | I | G25/G33 | P0-BLOCKER | Audit Storage Capacity Guard | 감사 저장소 용량/증가율 예산을 관리하고 임계치 초과 전 자동 확장·보존정책 조정을 강제 |
| I-9167 | I | G23/G27 | P0-BLOCKER | Backup Air-Gap Verification Gate | 백업 사본이 논리적/물리적 분리 저장소에 존재하는지 주기 검증해 랜섬웨어 동시오염을 방지 |
| I-9168 | I | G13/G32 | P0-BLOCKER | Incident Command Rotation Gate | 사고 대응 지휘 역할(Incident Commander) 순환훈련/백업지정이 유지되지 않으면 온콜 체계 승격 차단 |
| I-9169 | I | G8/G27 | P0-BLOCKER | Key Compromise Simulation Gate | 키 유출 가정 시나리오(폐기/재발급/세션무효화/감사보고)를 정기 검증해 대응시간 SLO를 관리 |
| I-9170 | I | G27/G33 | P0-BLOCKER | Supply-Chain SLSA Gate | 빌드/배포 파이프라인이 정의된 공급망 무결성 수준(SLSA 목표)을 충족하지 못하면 승격 차단 |
| I-9171 | I | G4.5/G33 | P0-BLOCKER | Observability Backpressure Gate | metrics/logs/traces 파이프라인 적체 시 서비스 경로를 보호하는 backpressure/drop 정책을 검증 |
| B-9273 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Hysteresis Guard | 경계치 인근 lag 진동에서 safety mode가 flap되지 않도록 히스테리시스/최소유지시간 정책을 강제 |
| B-9274 | B | G4.2/G24 | P0-BLOCKER | Outbox Cursor Replay Idempotency Guard | publish 중단/재시작 시 cursor 재처리 구간이 있어도 다운스트림 반영 결과가 1회 효과로 수렴 |
| B-9275 | B | G4.3/G27 | P0-BLOCKER | WS Subscription Auth Scope Guard | 사용자별 구독 가능 채널/심볼 스코프를 강제해 비권한 market/private 데이터 구독을 차단 |
| B-9276 | B | G7/G19 | P0-BLOCKER | Settlement FX-Rate Freeze Guard | 체결 시점 FX 기준이 정산 완료까지 고정되어 재평가 시점 차이로 정산 결과가 변하지 않음 |
| B-9277 | B | G5.3/G32 | P0-BLOCKER | Correction Replay Protection Guard | 동일 correction request/apply 재시도는 멱등 처리되고 중복 reversal 생성이 발생하지 않음 |
| B-9278 | B | G5.0/G33 | P0-BLOCKER | Risk Decision Version Stamp Guard | 모든 리스크 허용/거절 결정에 policy version/hash를 기록해 사후 재현·분석 가능성을 보장 |
| B-9279 | B | G5.0/G19 | P0-BLOCKER | Partial-Fill Fee Accumulator Guard | 부분체결 누적 수수료 계산이 분할 전략과 무관하게 동일 총액으로 수렴하도록 검증 |
| B-9280 | B | G22/G24 | P0-BLOCKER | Withdrawal State Monotonicity Guard | 출금 상태머신 전이가 단조 규칙을 따르며 역행/건너뛰기 전이를 DB 경계에서 차단 |
| B-9281 | B | G25/G31 | P0-BLOCKER | Audit Entity Ordering Guard | 동일 entity의 감사 이벤트 순서가 단조 증가 논리시계로 보존되어 재정렬 오해를 차단 |
| B-9282 | B | G26/G32 | P0-BLOCKER | Service-Mode API Contract Guard | NORMAL/CANCEL_ONLY/HALT/READ_ONLY 모드별 허용/거부 API와 에러코드 계약을 고정 |
| A-9026 | A | G13/G32 | P0-BLOCKER | Incident Command Assignment Board Guard | 사고 지휘/통신/기술조치 담당자와 대체자 할당 상태를 실시간 관리하고 공석 상태를 차단 |
| A-9027 | A | G25/G32 | P0-BLOCKER | Evidence Redaction Approval Guard | 외부 제출 전 증거 번들의 민감정보 마스킹 결과를 2인 승인 없이 배포할 수 없도록 강제 |
| I-9172 | I | G13/G33 | P0-BLOCKER | Chaos Seed Registry Gate | chaos 실행 seed/시나리오/결과를 레지스트리에 보존해 재현 불가능한 훈련 결과를 차단 |
| I-9173 | I | G5.2/G13 | P0-BLOCKER | Time-Source Integrity Audit Gate | NTP/PTP 소스 변경·오프셋 이상 이벤트를 tamper-evident 로그로 기록해 시간조작 의혹을 차단 |
| I-9174 | I | G23/G33 | P0-BLOCKER | DR Dependency Inventory Gate | DR 복구 필수 의존성(DB/Kafka/KMS/DNS/Secret)의 준비상태 인벤토리를 주기 점검하고 누락 시 차단 |
| I-9175 | I | G13/G33 | P0-BLOCKER | Alert Rule Unit-Test Gate | 핵심 알람 룰은 synthetic 입력 단위테스트를 통과해야 활성화되어 오탐/미탐 회귀를 방지 |
| I-9176 | I | G4.2/G33 | P0-BLOCKER | Kafka Topic Policy Drift Gate | retention/compaction/cleanup/minISR 등 토픽 정책 드리프트를 탐지해 의도치 않은 데이터 손실을 차단 |
| I-9177 | I | G5.2/G33 | P0-BLOCKER | OTel Sampling Budget Gate | trace/log 샘플링 정책이 환경별 budget을 넘기면 자동 경보 및 설정 롤백을 강제 |
| I-9178 | I | G21/G33 | P0-BLOCKER | Artifact Retention Budget Gate | 증적/리플레이 아티팩트 보존량이 예산을 초과하면 계층화/압축/아카이브 정책이 자동 실행 |
| I-9179 | I | G36/G33 | P0-BLOCKER | Compliance Mapping Freshness Gate | 통제-규제 매핑 문서의 최신성 SLA를 관리해 만료된 매핑 상태에서 릴리즈를 차단 |
| B-9283 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Rule Version Pin Guard | 대사 규칙/임계치 버전이 평가결과와 함께 고정 기록되어 룰 변경 후에도 과거 판정을 재현 가능하게 유지 |
| B-9284 | B | G4.2/G24 | P0-BLOCKER | Applied-Seq Fence Guard | ledger applied seq 갱신은 fence token 검증을 통과한 consumer만 수행해 stale worker의 역행 갱신을 차단 |
| B-9285 | B | G4.3/G26 | P0-BLOCKER | WS Conflation Accuracy Guard | book/candle conflation이 최신 상태를 정확히 대변하고 stale message가 최신을 덮어쓰지 않도록 보장 |
| B-9286 | B | G5.1/G17 | P0-BLOCKER | Trade Tape Gap Annotation Guard | trade resume에서 복구 불가 gap은 명시 어노테이션으로 노출되어 클라이언트 오인 표시를 차단 |
| B-9287 | B | G5.0/G24 | P0-BLOCKER | Price-Band Source Integrity Guard | 가격밴드 기준가격 산출 소스/윈도우를 고정해 기준 변조·시점 불일치로 인한 오차단을 방지 |
| B-9288 | B | G7/G19 | P0-BLOCKER | EOD Close Freeze Window Guard | EOD close 동안 허용된 작업 외 상태변경을 차단해 마감 스냅샷 일관성을 보장 |
| B-9289 | B | G22/G24 | P0-BLOCKER | Withdrawal Replay-Window Guard | 출금 요청 재제출 허용창을 정책화해 오래된 요청 재생으로 인한 이중출금 위험을 차단 |
| B-9290 | B | G12/G32 | P0-BLOCKER | Account Restriction Cascade Guard | 계정 제한(거래/출금/로그인 제한)이 하위 권한/세션/API key로 즉시 전파되어 우회를 차단 |
| B-9291 | B | G25/G31 | P0-BLOCKER | Audit Correlation Completeness Guard | 관리자 액션-시스템 반응-알람 이벤트가 공통 correlation ID로 연결되어 단일 추적이 가능해야 함 |
| B-9292 | B | G26/G33 | P0-BLOCKER | Safety-Mode Exit Replay Guard | 정상복귀 전 최근 breach 구간 replay 검증을 필수화해 재발 가능 상태에서의 조기 복귀를 차단 |
| A-9028 | A | G13/G32 | P0-BLOCKER | Reconciliation Breach Triage Board Guard | breach 원인/영향심볼/복구상태를 triage 보드로 운영하고 미분류 breach 종료를 차단 |
| A-9029 | A | G5.3/G32 | P0-BLOCKER | Mode Change Conflict Resolver Guard | 동시 모드변경 요청 충돌을 우선순위 규칙으로 해소하고 모순된 최종모드를 방지 |
| I-9180 | I | G13/G33 | P0-BLOCKER | Alarm-to-Ticket Automation Gate | P0/P1 알람 발생 시 티켓 자동생성/연결이 누락되면 운영 게이트 실패 처리 |
| I-9181 | I | G4.2/G33 | P0-BLOCKER | Replay Runtime Budget Gate | 대용량 replay 실행 중 CPU/메모리/시간 예산 초과를 감지해 복구 실패를 조기 판정 |
| I-9182 | I | G23/G33 | P0-BLOCKER | DR Drill Data Freshness Gate | DR 훈련 입력(snapshot/archive/offset)의 최신성 기준을 강제해 오래된 데이터로 합격하는 위양성을 차단 |
| I-9183 | I | G27/G33 | P0-BLOCKER | Image Vulnerability Freshness Gate | 이미지 취약점 스캔 결과의 유효기간을 관리해 stale 스캔 결과로 배포되는 것을 차단 |
| I-9184 | I | G5.2/G33 | P0-BLOCKER | Latency Budget Attribution Gate | p99 악화 시 서비스별(Edge/Core/Ledger/WS) 원인 분해 리포트가 자동 생성되지 않으면 게이트 실패 |
| I-9185 | I | G25/G36 | P0-BLOCKER | Regulatory Filing Evidence Link Gate | 규제 제출물마다 대응 evidence bundle 링크가 필수이며 누락 제출은 차단 |
| I-9186 | I | G13/G33 | P0-BLOCKER | Escalation Path Healthcheck Gate | 에스컬레이션 채널(콜/메시지/웹훅) 헬스체크 실패가 지속되면 온콜 승격/배포 승격을 차단 |
| I-9187 | I | G4.5/G33 | P0-BLOCKER | Observability Schema Contract Gate | metrics/logs/traces 필드 스키마 변경은 계약테스트 통과 전 배포 불가로 관측 파이프라인 호환성 보장 |
| B-9293 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Source Quorum Guard | core seq 수집 소스 다중화 시 quorum 검증을 통과한 값만 판정에 사용해 단일 소스 오염을 차단 |
| B-9294 | B | G4.1/G24 | P0-BLOCKER | Settlement Watermark Monotonic Guard | settlement watermark/last_settled_seq는 단조 증가만 허용하고 역행 업데이트를 DB 경계에서 차단 |
| B-9295 | B | G4.3/G26 | P0-BLOCKER | WS Replay Window Negotiation Guard | RESUME replay 가능 범위를 서버가 명시 협상하고 범위 밖 요청은 표준 오류+재동기화로 처리 |
| B-9296 | B | G5.1/G17 | P0-BLOCKER | Orderbook Snapshot Epoch Guard | snapshot epoch와 delta epoch 일치 검증을 강제해 epoch 불일치 데이터 혼합을 차단 |
| B-9297 | B | G10/G32 | P0-BLOCKER | Admin Action Signed-Payload Guard | 고위험 admin 요청 본문은 서버/클라이언트 서명 검증을 통과해야 실행되어 중간변조를 차단 |
| B-9298 | B | G5.0/G19 | P0-BLOCKER | Fee Schedule Rollback Fence Guard | 수수료 정책 롤백은 허용된 이전 버전으로만 가능하고 중간버전 건너뛰기/비승인 롤백을 금지 |
| B-9299 | B | G5.0/G24 | P0-BLOCKER | Trade Bust Causality Guard | 오류체결 취소(bust)는 원체결/정산취소 이벤트 인과관계가 완전할 때만 실행되며 orphan bust를 차단 |
| B-9300 | B | G7/G19 | P0-BLOCKER | PnL Carry-Forward Consistency Guard | 일마감 손익 이월값이 다음 영업일 시작값과 일치하고 경계일 이중반영이 없음을 검증 |
| B-9301 | B | G5.0/G26 | P0-BLOCKER | Risk Exposure Cache Invalidation Guard | 주문/체결/취소/정산 이벤트 후 노출도 캐시가 즉시 무효화되어 stale exposure 판정이 발생하지 않음 |
| B-9302 | B | G4.1/G32 | P0-BLOCKER | Safety Latch Durability Guard | safety latch 상태/해제승인 이력이 재시작·장애 후에도 내구 저장되어 fail-open 해제가 불가능해야 함 |
| A-9030 | A | G13/G32 | P0-BLOCKER | Reconciliation Explainability Panel Guard | breach 판정 근거(입력지표/규칙버전/임계치/액션)를 운영 UI에서 즉시 조회 가능하게 제공 |
| A-9031 | A | G23/G32 | P0-BLOCKER | DR Rehearsal Approval Checklist Guard | DR 복구 재개 전 필수 검증항목 승인체크가 완료되지 않으면 서비스 재개 버튼이 비활성화됨 |
| I-9188 | I | G4.2/G33 | P0-BLOCKER | Consumer Lag Forecast Gate | 소비지연 추세 예측으로 임계치 도달 전 선제 경보를 발동하고 미조치 상태 승격을 차단 |
| I-9189 | I | G23/G33 | P0-BLOCKER | Restore Checksum Challenge Gate | 복구된 데이터셋에 무작위 checksum challenge를 수행해 무결성 위양성 통과를 차단 |
| I-9190 | I | G13/G30 | P0-BLOCKER | Chaos Environment Parity Gate | chaos/DR 훈련 환경이 운영 구성과 동등하지 않으면 합격을 무효 처리해 훈련 신뢰성을 보장 |
| I-9191 | I | G25/G33 | P0-BLOCKER | Object-Lock Audit Export Gate | object-lock/retention 변경 이벤트를 주기 export·검증해 보존정책 무단변경을 탐지 |
| I-9192 | I | G10/G33 | P0-BLOCKER | Policy Rollback Rehearsal Gate | 정책 롤백 시나리오를 정기 리허설해 롤백 실패 시 운영 배포 승격을 차단 |
| I-9193 | I | G13/G33 | P0-BLOCKER | Incident Timeline Clock Alignment Gate | 사고 타임라인 이벤트가 시간원 보정 규칙으로 정렬되어 채널별 시각 불일치 보고를 차단 |
| I-9194 | I | G25/G36 | P0-BLOCKER | Compliance Evidence Notarization Gate | 핵심 준법 증거 번들을 외부 공증/타임스탬프 서비스로 고정해 사후 변조 논란을 차단 |
| I-9195 | I | G4.5/G33 | P0-BLOCKER | Dashboard Drift Detection Gate | 운영 대시보드(알람/패널) 구성이 기준 템플릿과 다르면 자동 경보·복구를 수행 |
| B-9303 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Rule Conflict Guard | 동시 적용된 대사 규칙 충돌 시 우선순위/차단 규칙으로 단일 판정만 허용하고 모호 판정을 금지 |
| B-9304 | B | G4.2/G24 | P0-BLOCKER | Settlement Retry Causality Guard | settlement 재시도는 원시도 attempt ID와 인과관계를 유지해 중복적용 없이 정확히 수렴 |
| B-9305 | B | G4.3/G26 | P0-BLOCKER | WS Backfill Throttle Guard | resume backfill이 실시간 fanout을 압도하지 않도록 심볼/연결별 throttle 예산을 강제 |
| B-9306 | B | G5.1/G17 | P0-BLOCKER | Candle Window Boundary Guard | 캔들 집계 경계(열림/닫힘 시각) 규칙을 고정해 경계 초/말 이벤트가 중복·누락 집계되지 않음 |
| B-9307 | B | G5.0/G24 | P0-BLOCKER | Risk Freeze on Config Drift Guard | 리스크 정책 파일 드리프트 감지 시 신규 주문 허용을 중지하고 승인 복구 전까지 freeze 모드 유지 |
| B-9308 | B | G7/G19 | P0-BLOCKER | PnL Recompute Determinism Guard | 과거 기간 손익 재계산이 실행환경/노드와 무관하게 동일 결과를 보장 |
| B-9309 | B | G22/G24 | P0-BLOCKER | Withdrawal Approval Chain Guard | 출금 승인 체인은 요청자/승인자/최종실행자 분리를 강제해 self-approve 경로를 차단 |
| B-9310 | B | G12/G32 | P0-BLOCKER | Restriction Expiry Safe-Release Guard | 계정 제한 만료는 조건 검증(케이스 종결/리스크 정상화) 통과 시에만 해제되고 자동 fail-open을 금지 |
| B-9311 | B | G25/G31 | P0-BLOCKER | Audit Backfill Integrity Guard | 감사로그 누락 복구(backfill) 시 원본 순서/해시 사슬을 유지하고 재기록 변조를 차단 |
| B-9312 | B | G26/G33 | P0-BLOCKER | Safety Escalation Ladder Guard | breach 심화 시 CANCEL_ONLY→HALT→WITHDRAW_HALT 단계 승격이 정책대로 자동 적용되고 역행 승격을 금지 |
| A-9032 | A | G13/G32 | P0-BLOCKER | Escalation Ladder Control Board Guard | 안전모드 단계 승격/완화 내역을 UI에서 시각화하고 승인 이력 없이 단계변경을 허용하지 않음 |
| A-9033 | A | G25/G32 | P0-BLOCKER | Regulatory Submission Readiness Board Guard | 제출 항목별 증거 링크/승인상태/마감시각을 한 화면에서 검증하고 미완료 제출을 차단 |
| I-9196 | I | G13/G33 | P0-BLOCKER | Alert Delivery Latency Gate | 알람 발행부터 수신까지 지연 SLO를 측정하고 초과가 지속되면 승격 차단 |
| I-9197 | I | G4.2/G33 | P0-BLOCKER | Recovery Pipeline Deadlock Gate | 복구 파이프라인 단계 간 데드락/대기교착을 탐지해 타임아웃 기반 fail-fast를 강제 |
| I-9198 | I | G23/G33 | P0-BLOCKER | DR Approval Chain Audit Gate | DR 전환/복구 승인 체인을 tamper-evident 로그로 보존하고 단일 승인 전환을 차단 |
| I-9199 | I | G27/G33 | P0-BLOCKER | Runtime Secret Age Gate | 실행중 시크릿의 나이/만료 주기를 측정해 정책 초과 시 자동 경보와 교체 드릴을 강제 |
| I-9200 | I | G5.2/G33 | P0-BLOCKER | Latency Histogram Integrity Gate | 지연 히스토그램 수집 누락/리셋 이상을 탐지해 성능게이트 위양성 통과를 차단 |
| I-9201 | I | G25/G36 | P0-BLOCKER | Filing Calendar Drift Gate | 규제 제출 달력 변경은 승인·이력·알림 없이 반영될 수 없고 드리프트 시 즉시 차단 |
| I-9202 | I | G13/G33 | P0-BLOCKER | Incident Artifact Completeness Gate | 사고 티켓 종결 전 필수 아티팩트(타임라인/원인/재발방지/증거)가 모두 첨부되지 않으면 차단 |
| I-9203 | I | G4.5/G33 | P0-BLOCKER | Dashboard Alert Mapping Gate | 대시보드 패널과 알람 룰의 매핑 누락을 검출해 관측은 있으나 경보 없는 blind spot을 차단 |
| B-9313 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Label Cardinality Guard | 대사 메트릭 라벨 cardinality 상한을 강제해 심볼 폭증 시 관측 시스템 과부하를 차단 |
| B-9314 | B | G4.2/G24 | P0-BLOCKER | Settlement Duplicate Source Guard | 동일 거래가 다중 consumer source로 유입돼도 source fingerprint로 중복적용을 차단 |
| B-9315 | B | G4.3/G26 | P0-BLOCKER | WS Close Reason Contract Guard | slow/drop/invalid resume 등 close 사유코드를 표준화해 클라이언트 복구 동작 혼선을 제거 |
| B-9316 | B | G5.1/G17 | P0-BLOCKER | Candle Late-Trade Policy Guard | 지연 체결(late trade) 반영 정책을 고정해 실시간 캔들/재생성 캔들 불일치를 차단 |
| B-9317 | B | G5.0/G24 | P0-BLOCKER | Risk Limit Hierarchy Guard | 계정/심볼/전사 한도 충돌 시 우선순위 체계를 강제해 허용·거절 결정 일관성 유지 |
| B-9318 | B | G7/G19 | P0-BLOCKER | Daily Cutover Ledger Fence Guard | 영업일 전환 cutover 중 ledger 쓰기 fence를 적용해 경계시간 이중반영을 방지 |
| B-9319 | B | G22/G24 | P0-BLOCKER | Withdrawal Queue Fairness Guard | 출금 대기열이 특정 계정/자산에 편향되지 않도록 공정성 규칙과 starvation 방지 정책을 강제 |
| B-9320 | B | G12/G32 | P0-BLOCKER | Restriction Reason Taxonomy Guard | 계정 제한/해제 사유코드를 표준 taxonomy로 강제해 준법/운영 보고 일관성을 보장 |
| B-9321 | B | G25/G31 | P0-BLOCKER | Audit Export Consistency Guard | 감사로그 export 결과가 조회 API 결과와 일치하며 필터/정렬 차이로 누락이 발생하지 않음 |
| B-9322 | B | G26/G33 | P0-BLOCKER | Safety Recovery Cooldown Guard | 안전모드 해제 후 일정 cooldown 동안 재해제/재진입 정책을 강제해 모드 진동을 완화 |
| A-9034 | A | G13/G32 | P0-BLOCKER | Incident SLA Breach Board Guard | 사고 SLA 위반 항목을 보드에서 분류·조치 완료 전 종결 불가로 강제 |
| A-9035 | A | G25/G32 | P0-BLOCKER | Filing Evidence Checklist Guard | 제출물별 필수 증거 체크리스트 누락 시 제출 승인 버튼을 비활성화 |
| I-9204 | I | G13/G33 | P0-BLOCKER | Alert Suppression Audit Gate | 알람 suppression/silence 변경을 tamper-evident 로그로 기록하고 만료 초과 suppression을 차단 |
| I-9205 | I | G4.2/G33 | P0-BLOCKER | Replay IO Budget Gate | replay 중 디스크/네트워크 I/O 예산을 초과하면 단계적 제한·경보를 발동 |
| I-9206 | I | G23/G33 | P0-BLOCKER | DR Runbook Checksum Gate | DR 런북/스크립트 체크섬을 고정해 승인되지 않은 변경으로 훈련/복구가 수행되지 않도록 차단 |
| I-9207 | I | G27/G33 | P0-BLOCKER | Secret Rotation Evidence Gate | 시크릿 회전 성공 증적(전후 검증/거부 로그)이 없으면 릴리즈 승격을 차단 |
| I-9208 | I | G5.2/G33 | P0-BLOCKER | SLO Window Integrity Gate | SLO 계산 윈도우 누락/중복 집계를 탐지해 잘못된 SLO 합격 판정을 차단 |
| I-9209 | I | G25/G36 | P0-BLOCKER | Filing Delivery Ack Gate | 규제 제출물 전송 후 수신 확인(ack) 증적이 없으면 제출 완료로 간주하지 않음 |
| I-9210 | I | G13/G33 | P0-BLOCKER | Escalation Ack Timeout Gate | 에스컬레이션 통보 ack 미수신이 timeout을 넘기면 자동 상위 에스컬레이션을 강제 |
| I-9211 | I | G4.5/G33 | P0-BLOCKER | Dashboard Version Pin Gate | 운영 대시보드 버전을 릴리즈와 함께 pin하여 임의 변경 대시보드 배포를 차단 |
| B-9323 | B | G4.1/G10 | P0-BLOCKER | Reconciliation Threshold Rollout Guard | 대사 임계치 변경은 canary 심볼 검증 후 단계적 반영만 허용하고 일괄 변경을 차단 |
| B-9324 | B | G4.2/G23 | P0-BLOCKER | Settlement Checkpoint Attestation Guard | settlement checkpoint는 seq/hash/작성주체를 서명 보존해 복구 시 checkpoint 위조를 차단 |
| B-9325 | B | G4.3/G26 | P0-BLOCKER | WS Replay Dedupe Horizon Guard | reconnect replay에서 최근 구간 중복 메시지를 dedupe horizon으로 제거해 중복 렌더링을 방지 |
| B-9326 | B | G5.1/G17 | P0-BLOCKER | Orderbook Depth Contract Guard | depth별 스냅샷/델타가 명시된 depth 계약을 위반하면 즉시 재동기화로 전환 |
| B-9327 | B | G5.0/G24 | P0-BLOCKER | Risk Band Snapshot Guard | 주문 승인 시점의 리스크 밴드 스냅샷을 저장해 사후 승인/거절 근거 재현을 보장 |
| B-9328 | B | G7/G19 | P0-BLOCKER | EOD Freeze Exception Audit Guard | 마감 freeze 예외 수행은 예외코드·승인자·영향범위 감사기록 없이는 실행 불가 |
| B-9329 | B | G22/G24 | P0-BLOCKER | Withdrawal Queue Checkpoint Guard | 출금 대기열 상태를 주기 checkpoint로 저장해 장애 후 순서/상태 복구의 결정성을 보장 |
| B-9330 | B | G12/G32 | P0-BLOCKER | Account Unlock Cooldown Guard | 계정 제한 해제 후 일정 cooldown 내 고위험 액션을 제한해 즉시 재남용을 차단 |
| B-9331 | B | G25/G31 | P0-BLOCKER | Audit Sampling Integrity Guard | 감사 표본추출 리포트가 원본 이벤트 집합과 일치하는지 자동 검증해 표본 왜곡을 차단 |
| B-9332 | B | G26/G33 | P0-BLOCKER | Safety Mode Metric Consistency Guard | 안전모드 상태와 노출 메트릭 값 불일치가 발생하면 자동 경보/격리로 전환 |
| A-9036 | A | G10/G32 | P0-BLOCKER | Reconciliation Policy Change Approval Guard | 대사 정책 변경은 diff·영향요약·2인 승인 없이는 적용 불가 |
| A-9037 | A | G13/G32 | P0-BLOCKER | Incident Closure Evidence Matrix Guard | 사고 종결 시 필수 증거 항목 매트릭스 누락이 있으면 종결 승인 차단 |
| I-9212 | I | G13/G33 | P0-BLOCKER | Alert Dependency Health Gate | 알람 의존 시스템(Pager/Webhook/SMTP) 헬스 실패가 지속되면 알람 신뢰도 경보를 발동 |
| I-9213 | I | G4.2/G33 | P0-BLOCKER | Replay Artifact Availability Gate | 복구에 필요한 snapshot/WAL/archive 아티팩트 가용성을 주기 점검하고 누락 시 즉시 차단 |
| I-9214 | I | G23/G33 | P0-BLOCKER | DR DNS TTL Audit Gate | DR 전환 대상 도메인의 TTL/캐시 정책이 전환 SLO에 맞는지 주기 감사 |
| I-9215 | I | G27/G33 | P0-BLOCKER | Secret Revocation Propagation Gate | 폐기된 시크릿/키가 모든 서비스 인스턴스에 SLA 내 전파되어 재사용이 불가능해야 함 |
| I-9216 | I | G5.2/G33 | P0-BLOCKER | SLO Burn-Rate Window Gate | burn-rate 계산 윈도우 설정 drift를 탐지해 경보 민감도 붕괴를 차단 |
| I-9217 | I | G25/G36 | P0-BLOCKER | Compliance Submission Retry Gate | 규제 제출 실패 시 재전송 전략/백오프/최대시도 정책이 동작하고 누락 제출을 차단 |
| I-9218 | I | G13/G33 | P0-BLOCKER | Oncall Roster Freshness Gate | 온콜 로스터 최신성(휴가/대체자/연락처) 검증 실패 시 온콜 승격/배포 승격을 차단 |
| I-9219 | I | G4.5/G33 | P0-BLOCKER | Dashboard Provisioning Drift Gate | 대시보드 프로비저닝 코드와 실배포 상태 drift를 감지해 수동패치 누락을 차단 |
| B-9333 | B | G4.1/G31 | P0-BLOCKER | Breach Snapshot Atomicity Guard | breach 탐지 시 core seq/ledger seq/safety mode를 단일 원자 스냅샷으로 기록해 경합 오판정을 차단 |
| B-9334 | B | G4.2/G16 | P0-BLOCKER | Trade Finality Drift Guard | trade 단위 EXECUTED→SETTLED 지연 예산을 강제하고 예산 초과 체결을 출금·정산 경로에서 차단 |
| B-9335 | B | G4.3/G17 | P0-BLOCKER | WS Resume Cursor Validation Guard | stale/future resume cursor를 결정론적 오류코드로 거부하고 표준 재동기화 경로만 허용 |
| B-9336 | B | G5.1/G17 | P0-BLOCKER | Book Epoch Monotonicity Guard | fan-out되는 book snapshot/delta의 epoch·seq 단조성을 강제해 혼합 epoch 반영을 차단 |
| B-9337 | B | G5.0/G24 | P0-BLOCKER | Exposure Cache Receipt Guard | 리스크 노출 캐시 무효화/재계산 결과에 receipt를 남겨 stale 판정 복구 경로를 추적 가능하게 보장 |
| B-9338 | B | G7/G19 | P0-BLOCKER | Fee Rounding Determinism Guard | core·ledger·리포트의 수수료 반올림 규칙을 단일 라이브러리로 고정해 채널별 금액 편차를 차단 |
| B-9339 | B | G22/G24 | P0-BLOCKER | Withdrawal Idempotency Scope Guard | 출금 idempotency 키를 account/asset/request 범위로 고정하고 payload 상이 중복요청을 거부 |
| B-9340 | B | G12/G32 | P0-BLOCKER | Restriction Propagation SLA Guard | 계정 제한/해제 이벤트가 모든 주문·출금 경계에 SLA 내 전파되지 않으면 고위험 액션을 차단 |
| B-9341 | B | G25/G31 | P0-BLOCKER | Audit Clock Skew Annotation Guard | 감사 이벤트에 소스 시계오프셋/보정정보를 포함해 다중 소스 타임라인 재구성 오류를 방지 |
| B-9342 | B | G26/G33 | P0-BLOCKER | Safety Mode Domain Write Fence Guard | HALT/READ_ONLY 모드에서 API 우회 내부 경로까지 도메인 write fence로 강제 차단 |
| A-9038 | A | G13/G32 | P0-BLOCKER | Safety Latch Approval Timeline Guard | safety latch 설정/해제 후보·승인·근거를 타임라인 보드로 강제하고 근거 누락 해제를 차단 |
| A-9039 | A | G25/G32 | P0-BLOCKER | Audit Query Reproducibility Board Guard | 동일 필터 조회/내보내기 결과 해시를 UI에 표시해 감사 질의 재현성과 누락 여부를 즉시 검증 |
| I-9220 | I | G13/G33 | P0-BLOCKER | Time Sync Budget Gate | core/ledger/ws 노드 시계편차(NTP/PTP) 예산을 계측하고 초과 시 배포·승격을 차단 |
| I-9221 | I | G4.2/G33 | P0-BLOCKER | Recovery Dependency Order Gate | Kafka/Core/Ledger/WS 재기동 순서 의존성을 chaos로 검증해 split-brain성 복구를 차단 |
| I-9222 | I | G23/G33 | P0-BLOCKER | DR Dual-Write Isolation Gate | DR 훈련 중 active/passive 동시 writable 상태를 탐지하면 즉시 fence를 걸어 이중쓰기 사고를 차단 |
| I-9223 | I | G27/G33 | P0-BLOCKER | Runtime Image Drift Attestation Gate | 실행중 컨테이너 digest가 서명된 배포 attestation과 다르면 자동 격리·승격 차단 |
| I-9224 | I | G5.2/G33 | P0-BLOCKER | WS Backfill Budget Isolation Gate | resume backfill 처리량/큐 예산을 분리해 라이브 fan-out p99를 침해하면 자동 throttle/격리 |
| I-9225 | I | G25/G36 | P0-BLOCKER | Compliance Cutoff Timezone Gate | 규제 제출 cutoff 시각을 timezone/DST 포함 계약테스트로 고정해 마감 오판정을 차단 |
| I-9226 | I | G13/G33 | P0-BLOCKER | Incident Timeline Source Fusion Gate | 사고 타임라인 생성 시 로그·트레이스·감사로그 소스 결합 완전성을 검증하고 누락 시 종결 차단 |
| I-9227 | I | G4.5/G33 | P0-BLOCKER | Safety Config Blast-Radius Gate | safety-critical 설정 롤아웃에 배치 상한·자동 롤백 규칙을 강제해 광역 오적용을 차단 |
| B-9343 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Timestamp Cohesion Guard | core/ledger seq는 동일 cutoff 시각 기준으로만 비교되어 phantom lag/mismatch 오탐을 차단 |
| B-9344 | B | G4.2/G16 | P0-BLOCKER | Applied Seq Commit Atomicity Guard | ledger posting 반영과 applied_seq 갱신을 원자 트랜잭션으로 묶어 부분커밋 불일치를 차단 |
| B-9345 | B | G4.3/G17 | P0-BLOCKER | WS Event Version Contract Guard | WS 채널별 eventVersion allowlist를 강제해 미지원 버전 메시지 수용으로 인한 복구 혼선을 차단 |
| B-9346 | B | G5.1/G17 | P0-BLOCKER | Book Delta Chain Checksum Guard | snapshot 이후 delta 체인에 prev_seq/checksum 검증을 적용해 누락·재정렬 반영을 차단 |
| B-9347 | B | G5.0/G29 | P0-BLOCKER | Risk Decision Determinism Guard | 동일 입력(주문/한도/정책버전)은 replica 간 동일 허용·거절 결과를 보장하고 편차를 차단 |
| B-9348 | B | G7/G19 | P0-BLOCKER | Settlement Retry Ceiling Guard | settlement 재시도는 상한·백오프·에스컬레이션 정책을 강제해 무한 재시도/침묵 실패를 차단 |
| B-9349 | B | G22/G24 | P0-BLOCKER | Withdrawal State Transition Guard | 출금 상태머신 전이가 유효 경로만 허용되어 skip/backward/중복 전이로 인한 이중실행을 차단 |
| B-9350 | B | G12/G26 | P0-BLOCKER | Mode Precedence Determinism Guard | 계정제한·심볼모드·전사모드 충돌 시 우선순위 규칙을 고정해 경계별 상이 동작을 차단 |
| B-9351 | B | G25/G31 | P0-BLOCKER | Trade-Settlement Correlation SLO Guard | 모든 체결은 SLO 내 settlement/예외사유를 가져야 하며 orphan trade가 남으면 자동 격리 |
| B-9352 | B | G26/G33 | P0-BLOCKER | Emergency Cancel-All Idempotency Guard | cancel-all 반복 호출/재시도에서도 주문상태·감사로그가 단일 결과로 수렴하도록 보장 |
| A-9040 | A | G13/G32 | P0-BLOCKER | Safety Override Justification Signature Guard | 안전모드 override 요청은 사유·영향범위·서명 검증 없이는 제출/승인할 수 없도록 강제 |
| A-9041 | A | G25/G32 | P0-BLOCKER | Release Exception Expiry Board Guard | 릴리즈 예외(waiver)는 만료시각·승인자·대체통제 증거가 없으면 적용 불가하고 자동 만료 |
| I-9228 | I | G13/G33 | P0-BLOCKER | Schema Compatibility Gate | 프로토/이벤트 스키마 변경은 backward/forward 호환 테스트를 통과하지 못하면 빌드·배포 차단 |
| I-9229 | I | G4.2/G33 | P0-BLOCKER | Kafka Partition Skew Gate | 토픽 partition skew/hot partition 지표를 감시해 소비지연 편중이 임계치를 넘으면 자동 경보·격리 |
| I-9230 | I | G23/G33 | P0-BLOCKER | Snapshot Object-Lock Verification Gate | snapshot 업로드 후 object-lock/retention 적용 여부를 검증하고 미적용 아티팩트 사용을 차단 |
| I-9231 | I | G27/G33 | P0-BLOCKER | Time Jump Chaos Gate | NTP step/leap-second/clock jump 장애주입에서 시간기반 판정 오작동이 없음을 주기 검증 |
| I-9232 | I | G5.2/G33 | P0-BLOCKER | Safe-Config Canary Abort Gate | safety-critical 설정 canary 중 SLO/lag 악화가 감지되면 자동 중단·롤백을 강제 |
| I-9233 | I | G25/G36 | P0-BLOCKER | Trace-Audit Correlation Gate | API→Kafka→Ledger→Audit 전 구간 trace/correlation ID 연계 누락이 있으면 릴리즈 승격 차단 |
| I-9234 | I | G13/G33 | P0-BLOCKER | Signed Config Drift Gate | 런타임 설정 해시가 서명된 소스와 다르면 drift로 판정해 즉시 경보·승격 차단 |
| I-9235 | I | G4.5/G33 | P0-BLOCKER | Backup Freshness Restore Drill Gate | 백업 최신성(RPO)과 실제 복원 성공 증적이 없으면 배포/재개 승인을 차단 |
| B-9353 | B | G4.1/G31 | P0-BLOCKER | Reconciliation Watermark Cohesion Guard | core/ledger watermarks는 동일 배치 경계 기준으로 산출되어 배치 경계 불일치 오판정을 차단 |
| B-9354 | B | G4.2/G16 | P0-BLOCKER | Ledger Resume Cursor Atomicity Guard | consumer resume cursor와 applied_seq 저장을 원자화해 재기동 후 역행/중복 재처리를 차단 |
| B-9355 | B | G4.3/G17 | P0-BLOCKER | WS Subscription Auth Scope Guard | 구독 채널 권한 스코프를 계정/심볼 단위로 강제해 권한외 스트림 수신을 차단 |
| B-9356 | B | G5.1/G17 | P0-BLOCKER | Candle Window Boundary Determinism Guard | 캔들 윈도우 경계(UTC/DST/지연입력) 계산을 고정해 집계 노드 간 결과 편차를 차단 |
| B-9357 | B | G5.0/G29 | P0-BLOCKER | Policy Rollout Version Fence Guard | 주문 판정 시 policy_version fence를 강제해 롤아웃 중 혼합 정책 판정을 차단 |
| B-9358 | B | G7/G19 | P0-BLOCKER | EOD Carry Forward Idempotency Guard | EOD 손익/잔고 이월 작업 재실행에서도 단일 결과로 수렴해 중복 이월을 차단 |
| B-9359 | B | G22/G24 | P0-BLOCKER | Withdrawal Address Policy Snapshot Guard | 출금 승인 시점 whitelist/risk policy 스냅샷을 보존해 사후 검증·분쟁 재현성을 보장 |
| B-9360 | B | G12/G26 | P0-BLOCKER | Restriction-Replay Consistency Guard | 계정 제한 상태가 replay/재기동 후 동일하게 복원되어 제한 우회 fail-open을 차단 |
| B-9361 | B | G25/G31 | P0-BLOCKER | Audit Actor Attribution Guard | 모든 감사 이벤트에 actor type/id/source를 강제해 익명·불명확 주체 기록을 차단 |
| B-9362 | B | G26/G33 | P0-BLOCKER | Safety Mode Transition Idempotency Guard | 동일 모드 전환 요청 재시도에서도 승인/감사/상태가 단일 전이로 수렴하도록 보장 |
| A-9042 | A | G10/G32 | P0-BLOCKER | Approval Quorum Consistency Board Guard | 2인 승인 quorum 계산은 중복 승인자/역할 충돌을 배제하고 일관된 승인판정을 보장 |
| A-9043 | A | G25/G32 | P0-BLOCKER | Evidence Legal-Hold Board Guard | 증거 번들 legal-hold 상태/만료/예외를 UI에서 추적하고 hold 미적용 종결을 차단 |
| I-9236 | I | G13/G33 | P0-BLOCKER | Alert Rule Provenance Gate | 운영 알람 룰 변경은 PR/승인/버전 provenance가 없는 경우 배포 적용을 차단 |
| I-9237 | I | G4.2/G33 | P0-BLOCKER | Consumer Rebalance Duplicate Gate | consumer group rebalance 중 중복 처리율을 측정하고 임계 초과 시 자동 격리·재조정 |
| I-9238 | I | G23/G33 | P0-BLOCKER | DR Promotion Write Freeze Gate | DR 승격 단계에서 source/target write freeze 검증이 실패하면 승격을 중단 |
| I-9239 | I | G27/G33 | P0-BLOCKER | Secret Scope Minimization Gate | 런타임 시크릿 접근범위가 정책 최소권한을 벗어나면 배포/승격을 차단 |
| I-9240 | I | G5.2/G33 | P0-BLOCKER | Latency Budget Attribution Gate | p99 초과 발생 시 서비스/구간별 budget attribution 리포트가 없으면 성능게이트를 실패 처리 |
| I-9241 | I | G25/G36 | P0-BLOCKER | Compliance Evidence Retention Gate | 규제 증거 산출물 보존기간/삭제정책 위반을 탐지해 제출 완결성을 차단 |
| I-9242 | I | G13/G33 | P0-BLOCKER | Incident Linkage Integrity Gate | 사고 티켓-알람-커밋-배포 링크 무결성이 깨지면 종결·승격을 차단 |
| I-9243 | I | G4.5/G33 | P0-BLOCKER | Backup Restore Isolation Gate | 복구 리허설은 격리 환경에서만 허용되고 운영 자원 오염 가능 경로를 차단 |
| B-9363 | B | G4.1/G13 | P0-BLOCKER | Reconciliation Source Latency Normalization Guard | core/ledger 수집 지연 차이를 보정한 기준 시각으로 lag를 계산해 지연편차 오탐을 차단 |
| B-9364 | B | G4.2/G16 | P0-BLOCKER | Ledger Offset-Seq Mapping Guard | kafka offset과 ledger applied_seq 매핑 무결성을 강제해 재처리 시 범위 누락/중복을 차단 |
| B-9365 | B | G4.3/G17 | P0-BLOCKER | WS Conflation Key Determinism Guard | book/candle conflation key 규칙을 고정해 인스턴스 간 상이한 latest-only 결과를 차단 |
| B-9366 | B | G5.1/G17 | P0-BLOCKER | Trade Replay Range Integrity Guard | trades replay range 응답은 연속 seq 완전성을 검증해 gap/중복 구간 반환을 차단 |
| B-9367 | B | G5.0/G29 | P0-BLOCKER | Exposure Precision Consistency Guard | 노출도 계산의 decimal precision/rounding 규칙을 단일화해 경계값 오판정을 차단 |
| B-9368 | B | G7/G19 | P0-BLOCKER | EOD Freeze Fence Idempotency Guard | EOD freeze/unfreeze 재시도에서도 동일 상태로 수렴해 경계시간 이중전환을 차단 |
| B-9369 | B | G22/G24 | P0-BLOCKER | Withdrawal Approval Snapshot Drift Guard | 승인 시점 계정상태/KYT 결과 스냅샷과 실행시점 drift를 검증해 조건변경 출금을 차단 |
| B-9370 | B | G12/G26 | P0-BLOCKER | Restriction Expiry Determinism Guard | 계정 제한 만료 스케줄러가 재기동/중복 실행에도 동일 시각·단일 전이로 동작 |
| B-9371 | B | G25/G31 | P0-BLOCKER | Audit Hash-Chain Segment Anchor Guard | 감사 해시체인 세그먼트마다 앵커 해시를 고정해 구간 누락·재배열 변조를 차단 |
| B-9372 | B | G26/G33 | P0-BLOCKER | Safety Mode Deadband Transition Guard | 안전모드 자동 전환에 deadband/hysteresis를 적용해 임계치 인접 구간 모드 플래핑을 차단 |
| A-9044 | A | G13/G32 | P0-BLOCKER | DR Promotion Checklist Board Guard | DR 승격 체크리스트 항목별 증거/승인/완료상태가 누락되면 승격 버튼을 차단 |
| A-9045 | A | G25/G32 | P0-BLOCKER | Policy Diff Acknowledgement Board Guard | 정책 변경 diff의 영향요약·리스크 acknowledgement 없이는 승인 진행을 차단 |
| I-9244 | I | G13/G33 | P0-BLOCKER | Event Schema Registry Lock Gate | 운영 이벤트 스키마 레지스트리 변경은 승인된 lockfile/버전 해시와 일치하지 않으면 차단 |
| I-9245 | I | G4.2/G33 | P0-BLOCKER | Consumer Commit Delay Budget Gate | consumer commit 지연 예산을 계측해 초과 시 lag 원인분해·자동 격리를 강제 |
| I-9246 | I | G23/G33 | P0-BLOCKER | DR Snapshot Copy Integrity Gate | DR 대상 스냅샷 복제본은 source/destination checksum 동등성 검증 없이는 사용 불가 |
| I-9247 | I | G27/G33 | P0-BLOCKER | Secret Usage Telemetry Gate | 시크릿 접근 사용량/주체 텔레메트리를 수집하고 비정상 패턴 시 자동 경보·승격 차단 |
| I-9248 | I | G5.2/G33 | P0-BLOCKER | WS Queue Saturation Forecast Gate | WS send queue 포화 예측 지표를 기반으로 선제 throttle/close 정책을 자동 적용 |
| I-9249 | I | G25/G36 | P0-BLOCKER | Compliance Calendar Integrity Gate | 규제 일정 캘린더 파일의 서명/체크섬 무결성이 깨지면 제출 스케줄 실행을 차단 |
| I-9250 | I | G13/G33 | P0-BLOCKER | Incident Evidence Immutability Verify Gate | 사고 증거 번들의 immutable 저장/검증 결과가 없으면 종결 승인·재개 승인을 차단 |
| I-9251 | I | G4.5/G33 | P0-BLOCKER | Backup Encryption Rotation Gate | 백업 암호화 키 회전 주기 준수와 구키 폐기가 검증되지 않으면 복구·배포 승인을 차단 |

## 4) 우선순위 티켓 (P0: 즉시 착수)

| ID | Type | Gate | Priority | 티켓 | Done 기준 |
|---|---|---|---|---|---|
| B-1001 | B | G4.1 | P0 | Invariants Scanner v2 (INV-001~005 전부) | Core/Ledger/ClickHouse 대상 `make invariants` 실행, 위반 시 non-zero exit + 위반 상세 JSON |
| I-2001 | I | G4.1 | P0 | Invariants CI Gate 고정 | CI에서 invariants 실패 시 merge/release 차단 |
| I-2002 | I | G4.1 | P0 | Evidence Bundle v2 | 로그/메트릭/최근 이벤트 N건/offset/hash를 번들로 자동 생성 |
| B-1002 | B | G4.1 | P0 | Reconciliation Safety Latch + Manual Release | 래치 ON 시 자동복귀 금지, 승인 API/감사로그로만 해제 |
| B-1003 | B | G4.1 | P0 | Reconciliation 복구정책 엔진 | `lag==0 + invariants pass` 조건 평가 및 수동/자동 복귀 정책 분리 |
| B-1004 | B | G4.1 | P0 | Exactly-once 효과 실험(중복 100만건) | 중복 이벤트 대량 주입 후 잔고 변화 1회만 반영 보고서 출력 |
| I-2003 | I | G4.2 | P0 | Chaos 시나리오 표준화(core/ledger/redpanda) | `scripts/chaos/*.sh`에 3대 장애 시나리오 정규화 |
| I-2004 | I | G4.2 | P0 | Chaos 합격조건에 invariants/reconciliation 포함 | 장애복구 후 invariant/recon 실패 시 스크립트 실패 |
| I-2005 | I | G4.2 | P0 | Snapshot/WAL 운영정책 문서+설정화 | 주기/트리거/목표 replay 시간/SLO가 config+runbook에 반영 |
| I-2006 | I | G4.2 | P0 | Snapshot verify 커맨드 | 다운로드→checksum 검증→복구 리허설 자동화 |
| B-1101 | B | G4.3 | P0 | WS Protocol v2 명세화 (SUB/UNSUB/RESUME) | 메시지 표준 필드(seq/ts/symbol) 문서+테스트+호환성 체크 |
| B-1102 | B | G4.3 | P0 | Trades range replay + gap signal | `RESUME(last_seq)`에서 replay 가능/불가능 시 명확한 서버 응답 |
| B-1103 | B | G4.3 | P0 | Book snapshot+delta gap recovery 강화 | gap 감지 시 snapshot 재동기화 동작 자동 테스트 통과 |
| I-2101 | I | G4.3 | P0 | Slow client 시뮬레이터 고도화 | drop/close/지연 지표 임계치 검증 자동화 |
| I-2201 | I | G4.4 | P0 | Load suite 단계화 (smoke/10k/50k) | `make load-smoke/load-10k/load-50k` 제공 |
| I-2202 | I | G4.4 | P0 | 성능 리그레션 게이트 | 기준 대비 p95/p99 악화 임계치 초과 시 PR 실패 |
| A-3001 | A | G4.5 | P0 | Admin 고위험 액션 레지스트리 | cancel-all/halt/correction/fee/policy 변경 공통 규격화 |
| A-3002 | A | G4.5 | P0 | 4-eyes + timelock 공통 프레임워크 | 승인자 분리/타임락/실행 전 diff preview 강제 |
| I-2301 | I | G4.5 | P0 | Immutable audit 저장 | 관리자 액션 요청/응답을 tamper-evident 형태로 보관 |
| I-2302 | I | G4.5 | P0 | Break-glass 워크플로우 | TTL, 자동 만료, 사후 보고서 템플릿 생성 |

## 5) 원문(G4.1~G6) 요구사항 추적 매핑

| 원문 요구 | 현재 판단 | 대응 티켓 |
|---|---|---|
| INV-001~005 자동검증 + 실패시 증거번들/실패코드 | 부분구현 | B-1001, I-2001, I-2002 |
| reconciliation lag/mismatch 기반 안전모드 | 기본구현 | B-1002, B-1003 (완성형) |
| `/v1/admin/reconciliation/status + history` | 구현됨 | 유지 + B-1003 |
| safety latch (자동해제 금지) | 미구현 | B-1002 |
| 중복 100만건 실험 | 미구현 | B-1004, B-9011 |
| core/ledger/redpanda crash drill 표준화 | 부분구현 | I-2003, I-2004, B-9009 |
| snapshot/WAL 정책 + verify | 미구현 | I-2005, I-2006, I-9018 |
| WS snapshot/delta/resume 명확화 | 부분구현 | B-1101, B-1102, B-1103 |
| slow consumer 정책 검증 | 기본구현 | I-2101 (강화), B-9013 |
| 샤딩/수평확장/reshard 전략 | 미구현 | B-9013, I-2312 |
| load-smoke/10k/50k 패키지 | 부분구현 | I-2201 |
| latency budget + profiling 자동화 | 부분구현 | I-2303, I-2311 |
| admin 4-eyes + immutable audit | 부분구현 | A-3001, A-3002, I-2301, A-9003 |
| key/secret 운영모델 현실화 | 부분구현 | I-1005, I-9010, I-9011 |
| safety_case 릴리즈 게이트 격상 | 부분구현 | I-2002, I-9019 |
| deterministic replay 공식시험 | 부분구현 | I-2307 + (신규 스크립트는 B-1001/B-1004 연계) |
| DR/multi-region/compliance 실전 | 미구현~부분구현 | I-2308, I-2507, B-9001/B-9002 |

## 6) 중기 티켓 (P1: Launch 운영 품질 고도화)

| ID | Type | Gate | Priority | 티켓 | Done 기준 |
|---|---|---|---|---|---|
| B-1201 | B | G4.6/G16 | P1 | Trade Finality 2단계 (EXECUTED/SETTLED) | 상태 분리 저장, 출금/정산은 SETTLED만 사용 |
| B-1202 | B | G16 | P1 | TradeSettled Commit Receipt 이벤트 | `trade_id` 당 1회 멱등 발행 + 재기동 후 재구성 가능 |
| B-1203 | B | G5.0 | P1 | Risk Policy Engine (policy-as-data) | 재컴파일 없이 정책 변경/버전/롤백 가능 |
| B-1204 | B | G5.0 | P1 | Circuit Breaker + Auction Mode | 급변 시 HALT→AUCTION→CONTINUOUS 시뮬레이터 검증 |
| B-1205 | B | G5.0 | P1 | Fee/Rounding 회귀 테스트 라이브러리 | 벡터 1,000+ 기준 회귀 통과 |
| B-1206 | B | G5.1 | P1 | Market Data SSOT 정리 (canonical vs derived) | canonical log 기반 재생성 가능 증명 |
| B-1207 | B | G5.1/G17 | P1 | Candle correctness proof + rebuild | 실시간 캔들 vs 재생성 diff=0 자동검증 |
| B-1208 | B | G5.0/G18 | P1 | STP + stop-limit + OCO | 시뮬레이션에서 상태머신/리스크 일관성 통과 |
| I-2303 | I | G5.2 | P1 | Profiling/Tracing budget 자동 수집 | Core/Edge/Ledger 단계별 예산 초과 탐지 |
| I-2304 | I | G5.3/G14 | P1 | EOD close v2 + GL export | 일마감 보고서/대사/분개 export + 증거 번들 |
| I-2305 | I | G5.3/G19 | P1 | Solvency report v2 | liabilities vs reserves 차이 원인 자동 분해 |
| I-2306 | I | G21 | P1 | Legal Archive (WORM-style) | topic offset 범위 아카이브/무결성 검증 스크립트 |
| I-2307 | I | G21 | P1 | Replay Tooling v2 | archive→core replay→ledger rebuild→candle rebuild 일괄 실행 |
| I-2308 | I | G23 | P1 | DR 빈 클러스터 복구 자동화 | 복구 후 invariants/recon 통과 시에만 거래 재개 |
| B-1209 | B | G26 | P1 | Safe Degradation Matrix 강제 | NORMAL/CANCEL_ONLY/TRADE_HALT/WITHDRAW_HALT/READ_ONLY API 강제 |
| B-1210 | B | G24 | P1 | Segregation of Funds 제약 | 고객자산↔회사자산 금지 규칙 위반 시 트랜잭션 실패 |
| I-2309 | I | G25 | P1 | Audit hash-chain 검증기 | 감사로그 변조 탐지 자동화 |
| I-2310 | I | G12/G27 | P1 | PII log leak gate | 로그에 민감정보 검출 시 CI 실패 |

## 7) 고도화 티켓 (P2: 기관/감사/규제 대응)

| ID | Type | Gate | Priority | 티켓 | Done 기준 |
|---|---|---|---|---|---|
| I-2401 | I | G31 | P2 | Assurance Pack (GSN + Evidence Auto-link) | `make assurance-pack`으로 최신 증거 자동 수집/렌더링 |
| I-2402 | I | G31 | P2 | Safety Budget Enforcement | 예산 초과 시 자동 안전모드 + 증거 번들 |
| I-2403 | I | G32 | P2 | Controls Catalog + controls-check | 통제항목 20+ 자동점검, 실패 시 릴리즈 차단 |
| I-2404 | I | G32 | P2 | SoD RBAC 강제 | Operator/Approver/Auditor/Custodian 역할 오남용 테스트 통과 |
| I-2405 | I | G33 | P2 | Continuous Verification Factory | PR 파이프라인에서 smoke/replay/invariants/controls/assurance 자동 수행 |
| I-2406 | I | G34 | P2 | Transparency Report | 공개 가능한 안정성 산출물 생성 + 민감정보 스캔 통과 |
| I-2407 | I | G34 | P2 | External Replay Kit | 외부 감사인이 독립적으로 해시 일치 검증 가능 |
| B-1301 | B | G35 | P2 | Loss-bounding breakers | notional/price-band/order-rate/withdraw-velocity 브레이커 작동 |
| I-2408 | I | G36 | P2 | Compliance mapping matrix | controls ↔ SOC2/ISO 항목 매핑 + evidence pack 자동 생성 |
| I-2409 | I | G36 | P2 | Access review 자동화 | 주기 권한 검토/미사용 권한 정리 제안/감사로그 생성 |

## 8) 확장 티켓 (P3: 형식검증/수탁/멀티리전)

| ID | Type | Gate | Priority | 티켓 | Done 기준 |
|---|---|---|---|---|---|
| I-2501 | I | G28 | P3 | 상태머신 명세 + 모델체킹 최소 1개 CI | 주문/최종성/출금 중 1개 이상 반례 없음 |
| I-2502 | I | G29 | P3 | Signed Policy (서명 없는 정책 거부) | 런타임 verify 실패 시 부팅/적용 거부 |
| I-2503 | I | G30 | P3 | Adversarial test suite | 중복/역순/replay/timestamp skew/lag 시나리오 자동화 |
| I-2504 | I | G30 | P3 | 주기 GameDay 자동화 | chaos 주입→복구→invariants→postmortem 템플릿 자동 생성 |
| B-1302 | B | G22 | P3 | signer-service 경계 도입 (MPC/HSM 교체 가능) | SignTx 인터페이스 고정 + 로컬 mock 드릴 통과 |
| A-3003 | A | G22 | P3 | 출금 2인 승인 + timelock + 한도 정책 | 승인/타임락 전 출금 진행 불가 E2E 검증 |
| I-2505 | I | G14/G8 | P3 | Proof of Liabilities (Merkle) | root/leaf proof 생성 및 검증기 통과 |
| I-2506 | I | G8 | P3 | Proof of Reserves 파이프라인 | liabilities/proof/reserve 근거 산출물 연동 |
| I-2507 | I | G23/G9 | P3 | Multi-region active/passive DR 모드 | 리전 장애 시 서비스 모드 전환/복구 드릴 통과 |
| I-2508 | I | G26 | P3 | Capacity/Cost guardrails | 폭주/비용급증 감지 시 단계적 제한 정책 작동 |

## 9) 분야별 세부 보강 티켓 (정밀 진단 확장)

| ID | Type | Gate | Priority | 티켓 | Done 기준 |
|---|---|---|---|---|---|
| B-1211 | B | G5.0 | P1 | Symbol Rules Registry | 심볼별 tick/lot/min-notional/max-leverage(향후) 룰을 중앙관리하고 주문검증과 동기화 |
| B-1212 | B | G5.0 | P1 | Trade Bust/Cancel Policy | 명백한 오류체결 취소 정책, 승인흐름, 재정산 자동화 |
| B-1213 | B | G5.0 | P1 | Listing/Delisting Workflow | 상장/거래중지/상장폐지 상태머신과 공지/리스크룰 연동 |
| B-1214 | B | G5.0 | P1 | Fee Version Governance | 수수료 변경시 버전·발효시점·소급금지·감사로그 강제 |
| B-1215 | B | G5.1 | P1 | Order/Trade Audit Trail API | 사용자/감사인이 주문→체결→정산까지 추적 가능한 조회 API 제공 |
| B-1216 | B | G5.1 | P1 | Wallet Consistency Watchdog | Edge 표시잔고 vs Ledger 잔고 주기 비교 및 불일치 시 자동 격리 |
| B-1217 | B | G5.2 | P1 | Clock Discipline | NTP/PTP drift 모니터링, 허용치 초과 시 경고/격리 |
| I-2311 | I | G5.2 | P1 | SLO Burn-rate Alerts | 지표 급격 악화 시 burn-rate 기반 다단계 알람 |
| I-2312 | I | G5.2 | P1 | Capacity Plan + HPA Strategy | 심볼/채널별 용량모델 및 자동확장 정책 수립 |
| I-2313 | I | G5.3 | P1 | DB Reliability Hardening | Postgres 파티셔닝/인덱스 정책, vacuum/lock 모니터링, failover runbook |
| I-2314 | I | G5.3 | P1 | Kafka Reliability Hardening | ISR/min.insync.replicas/acks 정책 표준화, 재처리 runbook 고정 |
| I-2315 | I | G5.3 | P1 | Artifact/SBOM/이미지서명 | SBOM 생성, 이미지 서명 검증, provenance gate 적용 |
| I-2316 | I | G5.3/G27 | P1 | API Input Hardening Pack | request body size limit + strict JSON decoder + unknown field reject 적용 |
| B-1218 | B | G5.3/G27 | P1 | Error Response Sanitization | 내부 에러 문자열(`err.Error`) 직접 노출 금지, 표준 오류코드 체계 도입 |
| I-2317 | I | G5.3/G27 | P1 | Metrics Endpoint Exposure Control | `/metrics`/`/readyz` 접근을 내부망·scraper 전용으로 제한 |
| B-1219 | B | G5.1/G26 | P1 | Market Data Symbol Allowlist | 상장 심볼 외 이벤트/요청 차단으로 고카디널리티 DoS 방지 |
| I-2318 | I | G5.3/G27 | P1 | HTTP Security Header/CORS Baseline | HSTS/CSP/XCTO 등 보안헤더 + CORS Origin allowlist 적용 |
| B-1220 | B | G5.3/G27 | P1 | API Key Principal Registry | API Key와 user/account principal의 명시적 매핑, 회수/비활성 즉시 반영 |
| I-2319 | I | G5.3/G27 | P1 | Log Redaction/PII Scrub Gate | raw payload/민감필드 로그 출력 금지, CI log-scan 게이트 적용 |
| I-2320 | I | G4.1/G11 | P1 | Reconciliation History Retention Policy | history/safety_state 보존기간·파티셔닝·아카이브 정책 수립 |
| A-3004 | A | G5.3 | P1 | Admin Action UX Guardrails | 고위험 액션은 영향범위 시뮬레이션 + 재확인 단계 강제 |
| A-3005 | A | G5.3 | P1 | Dual-control Dashboard | 승인대기/타임락/만료/거부 이력 가시화 |
| I-2410 | I | G34 | P2 | Regulatory Evidence Pack | 분기/월별 감독기관 제출 포맷 자동 생성 |
| I-2411 | I | G34 | P2 | Customer Disclosure Pack | 수수료/체결규칙/중단정책/위험고지 변경 이력 공개 산출물 |

## 10) 권장 실행 순서 (다음 주 착수)

1. I-9001~I-9251, A-9001~A-9045, B-9001~B-9372, U-9001~U-9003 (Live-Go 블로커 해소)
2. B-1001, I-2001, I-2002 (인바리언트/증거/게이트)
3. B-1002, B-1003 (Safety latch + 수동 복귀 통제)
4. I-2003, I-2004 (Chaos 표준화 + 합격조건 강화)
5. B-1101, B-1102, B-1103, I-2101 (WS 운영형 프로토콜 완성)
6. I-2201, I-2202 (부하/성능 리그레션 게이트)
7. A-3001, A-3002, I-2301 (운영 통제/감사 불변성)

## 11) Go/No-Go 최소 체크리스트 (외부 사용자 오픈 전)

아래 625개가 모두 통과할 때만 Go:

1. Live-Go 블로커 티켓 전부 `done`.
2. `make safety-case` + invariants + reconciliation + chaos 표준 시나리오 모두 통과.
3. Core/Ledger/WS p95/p99 목표치 충족 및 최근 7일 리그레션 없음.
4. Admin 고위험 액션 4-eyes/timelock/audit 강제 확인.
5. DR 복구 리허설에서 목표 RTO/RPO 충족.
6. KYC/KYT/AML + 계정동결 + 출금통제 E2E 검증 통과.
7. 외부 PenTest Critical/High 0건.
8. SEV1 온콜 훈련(게임데이) 최근 30일 내 성공 기록 존재.
9. 내부 통신(gRPC/OTLP/Kafka) TLS 및 서비스 인증이 평문 없이 동작.
10. Ledger 잔고 조회는 권한 스코프를 강제하며 공개/무인증 경로가 없음.
11. core idempotency가 사용자/커맨드 범위로 격리되어 교차 사용자 충돌이 0건.
12. core cancel 권한 검증(주문 소유자 강제) 우회 테스트가 모두 실패(차단)한다.
13. 운영 기본 RBAC는 secret write/delete 권한이 없고, 긴급 권한은 break-glass 경로로만 사용된다.
14. 중복 `order_id` 입력 시 core가 deterministic reject 하며 orderbook 무결성이 깨지지 않는다.
15. correction 생성은 원본 entry 존재/상태 검증을 통과해야 하며, 요청 본문으로 주체를 위조할 수 없다.
16. settlement idempotency 저장소가 실제 소비 경로에 연결되어 중복/재시작 실험에서 1회 효과를 증명한다.
17. core의 주문 응답은 publish 실패와 분리되어 일관된 결과 상태(`ACCEPTED/REJECTED/UNKNOWN`)를 제공한다.
18. cancel/set-mode/cancel-all 포함 모든 명령 경로에서 outbox publish 지연 상한을 만족한다.
19. idempotency key 재사용 시 payload hash 불일치 요청은 항상 거부된다.
20. correction 승인 동시성 테스트에서 상태 꼬임 없이 2인 승인 규칙이 원자적으로 유지된다.
21. reconciliation은 lag 뿐 아니라 seq hole(누락 구간)까지 탐지하고 자동 안전모드로 전환한다.
22. 고객계정 음수 잔고 시도는 ledger write-path에서 즉시 실패한다(사후 보정 의존 금지).
23. WS 연결 폭주 상황에서도 글로벌/IP별 연결 상한과 rate limit이 강제되어 프로세스가 생존한다.
24. core Kafka producer 내구 프로파일(`acks=all`, idempotence)이 적용되어 broker 장애 재시도에서도 이벤트 유실이 없다.
25. core `set_symbol_mode/cancel_all`는 meta 누락·불일치 요청을 fail-open으로 처리하지 않고 즉시 거부한다.
26. `cancel_order/set_symbol_mode/cancel_all`를 포함한 모든 mutating 명령이 리더 fencing 검증을 통과한 경우에만 반영된다.
27. non-place 명령은 `meta.symbol` 스코프 검증을 강제하여 교차 symbol 요청을 차단한다.
28. WS는 ping/pong + read deadline으로 zombie connection을 SLO 내 정리한다.
29. WS는 per-connection subscription 상한을 강제하며 SUB flood에서도 메모리 사용량이 제한된다.
30. malformed Kafka payload가 유입되어도 settlement/reconciliation consumer는 DLT 격리 후 진행을 유지한다.
31. production에서 core WAL/Outbox 경로가 영속 스토리지로 강제되며 `/tmp` 기본 경로로는 부팅되지 않는다.
32. 주문 취소는 edge 메모리 캐시가 아닌 영속 주문 소스 기준으로 검증되어 edge 재기동 후에도 정상 동작한다.
33. edge trade consumer는 처리 실패 레코드를 단순 로그 후 손실시키지 않고 retry/DLQ/gap marker로 복구 가능해야 한다.
34. edge `trade_id` 중복 방지는 재시작/다중 레플리카에서도 유지되는 영속 dedupe로 보장된다.
35. reconciliation breach 상태에서 안전모드 전환 실패 시 자동 재시도(backoff)와 실패 알람이 동작한다.
36. reconciliation은 lag뿐 아니라 데이터 신선도(`updated_at` staleness) 위반도 breach로 판정한다.
37. core idempotency TTL은 서버 수신시각을 기준으로 계산되며 client timestamp 조작으로 우회되지 않는다.
38. core gRPC는 프로덕션에서 mTLS+인증 없이 접근 불가하고 public bind(`0.0.0.0`)로 기동되지 않는다.
39. edge의 `trade_id` dedupe 마킹은 반영 완료 후에만 기록되어 중간 실패 시 영구 스킵이 발생하지 않는다.
40. edge wallet 영속화 실패는 무시되지 않고 즉시 실패/재시도/격리로 처리되어 메모리-DB 분기가 남지 않는다.
41. core canonical 이벤트 스트림은 TradeExecuted 외 Order/Mode 관련 이벤트도 포함해 재현 가능성을 보장한다.
42. outbox cursor 파일 손상 시 `0` fallback으로 진행하지 않고 fail-closed 후 복구 절차가 강제된다.
43. 릴리즈 게이트는 stub/무인증 dev profile뿐 아니라 hardened profile drills도 반드시 통과해야 한다.
44. core는 신규 사용자 자동크레딧 경로가 제거되어 외부 SoT 잔고 없이 주문을 수용하지 않는다.
45. edge `readyz`는 core RPC 비정상/consumer stall·lag 시 fail을 반환해 트래픽 유입을 차단한다.
46. ledger `readyz`는 settlement/reconciliation consumer 정지·비정상 lag를 감지해 fail을 반환한다.
47. edge Kafka consumer는 처리 성공 후에만 commit하며 처리 실패 메시지는 재시도/격리로 수렴한다.
48. ledger duplicate 판정은 문자열 매칭이 아닌 SQLSTATE 기반으로 안정적으로 동작한다.
49. rust(core) 코드 변경 PR도 load-smoke/dr-rehearsal/safety-case/chaos 게이트를 우회하지 못한다.
50. WS 입력은 read limit을 초과하는 프레임을 즉시 차단하고 연결을 종료한다.
51. `/metrics`는 인증된 내부 scraper 경로에서만 접근 가능하며 공개 엔드포인트가 없다.
52. invariant 음수 검사는 customer/system 계정 규칙을 구분해 오탐 없이 동작한다.
53. outbox 레코드 일부 손상 시 손상분은 격리되고 후속 정상 이벤트 publish가 지속된다.
54. outbox cursor는 원자적 내구 기록을 사용하여 크래시 후 재시작에서도 cursor rollback이 발생하지 않는다.
55. ledger settlement 반영과 `last_settled_seq` 업데이트가 원자적으로 커밋되어 partial success 상태가 남지 않는다.
56. reconciliation scheduler는 멀티 레플리카 환경에서도 분산락/리더 단일 실행으로 중복 액션을 발생시키지 않는다.
57. settlement DLQ는 재처리 워커/보존상한/백로그 알람을 갖추고, 적체 이벤트가 운영창 내에 해소된다.
58. WAL tail partial frame(크래시 truncation) 발생 시 손상 구간을 자동 격리하고 재기동이 성공한다.
59. WAL replay는 frame length 상한 검증을 강제해 비정상 길이 프레임으로 인한 OOM을 유발하지 않는다.
60. outbox publish는 파일 전체 적재 없이 streaming 방식으로 동작해 backlog 증가 시에도 메모리 상한을 유지한다.
61. edge 프로덕션 기동은 runtime DDL을 수행하지 않고 승인된 migration 아티팩트가 선적용된 경우에만 성공한다.
62. load/chaos/safety 게이트는 무인증 주문·`/v1/smoke/trades` 의존 없이 인증된 실경로로만 트래픽을 생성한다.
63. market data API/WS는 `demo-derived` fallback을 노출하지 않고 canonical snapshot/delta 기반 상태만 제공한다.
64. core→Kafka→ledger 수치 필드는 동일한 정수 범위 계약을 준수하며 범위 초과 입력은 변환 없이 거부된다.
65. state hash는 주문장뿐 아니라 리스크/예약/모드 상태를 포함해 replay 동일성 위양성이 없다.
66. state hash 생성 직렬화 실패는 fallback 없이 즉시 오류로 처리되어 검증이 fail-closed 된다.
67. snapshot load는 checksum/state-hash 검증을 통과한 파일만 수용한다.
68. snapshot save는 file+dir fsync를 포함한 원자 저장으로 크래시 fault-injection 후에도 복구된다.
69. FOK 주문은 부분체결이 절대 발생하지 않고 전량 미충족 시 즉시 거부/취소된다.
70. core 재기동 시 outbox backlog가 자동 flush되어 후속 주문 없이도 이벤트 전파 누락이 없다.
71. ledger double-entry 검증은 overflow-safe 연산으로 구현되어 대형 수치에서도 오탐/미탐이 없다.
72. reconciliation 메트릭은 signed gap/mismatch를 직접 노출해 음수 gap 상황이 대시보드에서 숨겨지지 않는다.
73. CI는 corrupted snapshot/replay hash completeness 시나리오를 필수 실행해 결정성 증명을 우회할 수 없다.
74. invariant scheduler는 위반을 탐지하면 로그에 그치지 않고 즉시 안전모드+증거번들을 실행한다.
75. settlement DLQ 레코드만으로 원본 이벤트 재처리(replay)가 가능할 만큼 포렌식 정보가 보존된다.
76. ledger 입력 DTO는 unknown field를 허용하지 않으며 스키마 불일치 입력을 격리한다.
77. safety mode 설정값이 유효하지 않으면 부팅이 차단되어 fail-open 강등이 발생하지 않는다.
78. 상장 심볼 전체가 reconciliation/invariant 감시 대상에 포함되는지 자동 검증된다.
79. outbox 레코드 내부 다중 이벤트 발행 중간 실패 후 재시도에서도 중복 발행이 발생하지 않는다.
80. ledger actuator/metrics 엔드포인트는 인증된 내부 경로에서만 접근 가능하다.
81. 서비스어카운트 토큰은 기본 비마운트이며 필요한 워크로드에만 최소 권한으로 제공된다.
82. observability 네트워크정책은 서비스별 최소 메트릭 포트만 허용하고 비의도 포트를 차단한다.
83. core WAL replay는 이벤트 수치/필드 파싱 실패를 `0`으로 보정하지 않고 즉시 fail-closed 된다.
84. core/edge의 체결 금액(`price*qty`)과 ticker 집계는 overflow-safe 연산으로 구현되어 wrap/saturation이 발생하지 않는다.
85. WS candles 구독 interval은 allowlist 검증을 통과한 값만 허용되고 임의 interval 입력은 거부된다.
86. ledger settlement/reconciliation consumer는 manual ack + 명시적 error handler 구성으로 commit 시점이 코드로 고정된다.
87. `chaos_replay.sh`는 재기동 전/후 WAL 레코드뿐 아니라 라이브 core state hash 동등성을 검증한다.
88. `scripts/safety_case.sh`는 저장소 접근키를 코드에 포함하지 않으며 시크릿 주입 경로로만 업로드를 수행한다.
89. trading-core 운영 로그는 `user_id` 등 식별자를 평문으로 남기지 않고 마스킹/제거 정책을 준수한다.
90. CI는 replay strict decode + arithmetic overflow + chaos live hash 시나리오를 필수 게이트로 실행한다.
91. WAL 복구는 record symbol과 실행 심볼의 불일치를 허용하지 않으며 교차 심볼 WAL을 fail-closed로 차단한다.
92. WAL 복구 중 상태 해시는 재계산/대조되어 record 해시 변조가 있으면 즉시 복구 실패한다.
93. WAL replay는 fencing token epoch 연속성을 검증해 stale writer 기록을 반영하지 않는다.
94. 대용량 WAL 복구는 스트리밍 방식으로 수행되어 메모리 상한을 넘지 않는다.
95. snapshot은 symbol/schema/checksum 메타데이터를 포함하고, 불일치 snapshot 로드는 거부된다.
96. auth 서명 검증 경로는 요청 본문 크기 상한(예: 1MB)을 강제하고 초과 요청을 413으로 차단한다.
97. 주문/취소 API의 `Idempotency-Key`는 길이/문자셋 정책을 위반하면 즉시 거부된다.
98. CI는 WAL 무결성(심볼/해시/fencing) 변조 및 대용량 replay 시나리오를 필수로 실행한다.
99. edge/ledger는 체결 이벤트의 `quoteAmount`와 `price*qty` 일치성을 검증하고 불일치 이벤트를 격리한다.
100. trade/market-data 숫자 입력에서 float/decimal 절삭 수용이 없고 정수 계약 위반은 즉시 차단된다.
101. 지갑 DB 읽기/스캔 실패 시 기본시드 잔고로 강등하지 않고 fail-closed로 응답한다.
102. reconciliation state/safety upsert는 재귀가 아닌 bounded retry로 동작하며 경합 테스트에서 스택 증가가 없다.
103. core는 WAL/outbox 단일 writer 파일락을 강제하고 lock 충돌 시 두 번째 인스턴스가 즉시 종료된다.
104. settlement 처리 중 DLQ write 실패가 발생해도 누락 커밋 없이 격리/경보가 동작한다.
105. 프로덕션에서 safety-critical 플래그(consumer/auto-switch)가 비활성이면 부팅 또는 readiness가 차단된다.
106. core WAL/snapshot tail replay 이후 risk balances/reservations/open-order exposure가 재기동 전 상태와 결정론적으로 동일하다.
107. core는 snapshot-first(최신 snapshot + WAL tail) 복구 경로를 기본 사용하고 snapshot 무결성 실패 시 fail-closed 규칙을 따른다.
108. reconciliation read API 호출이 active breach 요약 메트릭을 0으로 덮어쓰지 않으며 평가잡 기준 지표가 유지된다.
109. Kafka 지연 상황에서도 주문 RPC가 동기 flush에 막히지 않고 cancel/set-mode 경로가 p99 제어예산을 만족한다.
110. CI/chaos 게이트는 대용량 WAL에서 snapshot-first 복구시간 SLO를 상시 검증한다.
111. infra 검증 파이프라인은 `kubectl`/cluster 부재를 자동 성공 처리하지 않고 보호 브랜치에서 fail-closed로 동작한다.
112. K8s/GitOps 검증은 `--validate=false` 우회를 허용하지 않고 schema/policy/server-side dry-run을 모두 통과해야 한다.
113. JIT admin grant는 만료시점 이후 자동 회수되며, 만료된 고권한 binding 잔존이 0건임을 주기 점검으로 증명한다.
114. Argo AppProject는 리소스/네임스페이스 wildcard 권한이 제거되어 허용 목록 외 배포를 차단한다.
115. 부하게이트는 HTTP 2xx가 아닌 주문 도메인 결과 기준으로 성공률을 집계하고, WS read 실패를 누락 없이 계측한다.
116. edge trade consume 실패 로그에는 raw payload가 포함되지 않으며 최소식별자(trade_id/hash)만 기록된다.
117. CI workflow의 외부 액션은 commit SHA로 고정되어 태그 기반 공급망 위험을 허용하지 않는다.
118. `/v1/auth/signup`과 `/v1/auth/login`은 IP+계정 기준 rate limit/lockout/backoff를 강제해 브루트포스 시나리오를 차단한다.
119. 세션 검증은 중앙 저장소 기준으로 동작하며 Redis 장애 시 메모리 fallback으로 인증을 허용하지 않는다.
120. web-user는 session token을 localStorage에 저장하지 않고 HttpOnly/SameSite 세션 모델을 사용한다.
121. `default-deny` 네트워크정책 환경에서 edge↔core/ledger/infra 필수 트래픽이 최소허용 정책으로만 통과한다.
122. streaming 파이프라인은 Flink 실제 잡(Kafka source/sink + checkpoint/watermark)으로 실행되며 캔들/티커 재생성 검증을 통과한다.
123. invariant 스캐너는 운영 트래픽 하에서 timebox/증분전략으로 DB 부하 상한을 지키며 경보 누락 없이 동작한다.
124. edge 외부 API 응답은 내부 예외 문자열을 직접 노출하지 않고 표준 오류코드/메시지만 반환한다.
125. ledger의 reserve/release/trade 내부 입력은 `side` enum, 필수 식별자, 값 범위를 경계에서 엄격히 검증한다.
126. DR rehearsal은 toy seed 데이터가 아니라 실제 snapshot/WAL/Kafka offset 데이터 경로를 복원해 검증한다.
127. load smoke 게이트는 격리된 full-stack 환경에서만 실행되며 외부 로컬 프로세스 의존이 없다.
128. compose/운영 스크립트 런타임 이미지는 digest로 고정되어 mutable tag drift가 CI에서 차단된다.
129. ledger safety-critical 플래그 조합(reconciliation/settlement/observer)이 부팅 시 검증되어 잘못된 조합으로 기동하지 않는다.
130. edge 주요 POST API는 요청 body 크기 상한과 strict JSON decode(unknown field reject)를 강제한다.
131. ledger는 symbol/currency를 canonical form(대문자)으로 정규화해 동일 자산의 case-split을 허용하지 않는다.
132. ledger account 식별자 생성 시 principal ID 문자셋/인코딩 정책을 적용해 구분자 주입을 차단한다.
133. 운영환경에서 회원가입/지갑조회 경로의 기본 자산 auto-seed가 제거되어 무상 크레딧이 발생하지 않는다.
134. DR rehearsal은 최신 migration 체인을 적용한 실제 스키마에서 수행되어 schema drift가 없음을 증명한다.
135. safety-case 번들은 동일 커밋의 최신 산출물만 수집하며 stale report 재사용으로 게이트를 통과할 수 없다.
136. 주문 입력(`price/qty`)은 finite 수치만 허용되며 `NaN/Inf` 입력이 reserve/지갑 상태를 오염시키지 않는다.
137. core risk 상태맵(`recent_commands/open_orders`)은 장기 고카디널리티 트래픽에서도 키가 무한 증가하지 않는다.
138. edge 런타임 상태(users/sessions/idempotency/wallets)는 quota/LRU/TTL로 제어되어 메모리 상한을 초과하지 않는다.
139. ledger 잔고 재빌드는 `TRUNCATE` 공백 없이 shadow 계산 후 atomic swap으로 완료된다.
140. reconciliation seq upsert 충돌은 bounded retry로 수렴하며 재귀 재시도로 스레드/스택을 소모하지 않는다.
141. core 명령의 주체 식별자는 canonical principal namespace로만 전달되어 API key ID/user ID 충돌이 없다.
142. web-user 운영 빌드에는 `Push Sample Trade` UI/호출 경로가 존재하지 않는다.
143. core gRPC 서버는 keepalive/메시지크기/연결 제한을 적용해 대형 요청/느린 연결 공격에 대해 성능 예산을 유지한다.
144. 주문별 누적 fill/reserve 상한을 초과하는 이벤트는 반영되지 않고 격리되어 잔고/주문 상태가 보존된다.
145. 쿠키 기반 세션 모델에서 CSRF token + origin 검증이 강제되어 교차사이트 요청 위조가 차단된다.
146. correction apply는 reversal 반영과 상태전환(`APPLIED`)을 원자 트랜잭션으로 처리해 중간장애에도 일관성을 유지한다.
147. Ledger DB는 `amount/seq/status/mode/account_kind`에 대한 CHECK/FK 제약으로 앱 검증 우회 쓰기를 차단한다.
148. GitOps prod/staging 애플리케이션은 `targetRevision: main`을 사용하지 않고 승인된 immutable revision만 배포한다.
149. signup/login API 응답은 계정 존재 여부를 노출하지 않아 이메일 열거 공격을 허용하지 않는다.
150. command/order/trade/user/symbol 식별자는 길이·문자셋 정책을 통과한 값만 수용된다.
151. 이벤트 소비 경계는 허용된 `eventVersion`만 처리하고 미지원 버전은 격리/DLQ로 수렴한다.
152. signup/login/logout/session 생성·폐기 이력이 immutable audit에 남아 계정 사고 포렌식이 가능하다.
153. `smoke_e2e/g0/g3`는 hardened security profile(실인증/non-stub)에서도 필수 통과해 보안 위양성 게이트가 없다.
154. ledger posting은 `(account_id,currency)` 참조 무결성을 통과한 경우에만 반영되어 통화축 혼합이 발생하지 않는다.
155. WAL/outbox replay는 seq 연속성(증가/중복/역행/gap)을 검증하고 위반 시 즉시 fail-closed 된다.
156. core validation reject/권한 reject 시도도 append-only 감사 이벤트로 남아 탐지·포렌식이 가능하다.
157. 사용자 계정은 MFA + verified-email 상태 없이는 민감 액션(거래/출금)을 수행할 수 없다.
158. signup/login 실패 응답은 시간 균등화 정책으로 계정 존재 유무를 타이밍으로 추론하기 어렵다.
159. settlement DLQ는 payload 크기 상한과 해시/오프로드 정책으로 오류폭주 시 DB 폭증을 방지한다.
160. Argo root/prod 앱은 승인 없는 자동 sync로 운영 반영되지 않으며 manual-gated 정책을 강제한다.
161. ledger Kafka consumer의 commit/isolation 핵심옵션은 설정파일과 테스트로 고정되어 런타임 기본값 변화에 영향받지 않는다.
162. 사용자 웹은 MFA 등록·복구코드·이메일 검증 상태를 필수 온보딩으로 유도해 보안정책 우회를 허용하지 않는다.
163. edge의 replay/rate/idempotency 검증 상태는 중앙 저장소에서 원자적으로 공유되어 다중 레플리카 우회가 발생하지 않는다.
164. WS handshake는 Origin allowlist를 강제하고 비허용 origin 연결을 표준 close/audit로 차단한다.
165. edge DB 연결은 max-open/max-idle/lifetime/statement-timeout이 설정되고 포화 메트릭 경보가 연결된다.
166. edge DB read/write 경로는 `context.Background()`에 의존하지 않고 deadline/cancel이 있는 context로 실행된다.
167. tracing 샘플링 비율은 환경별 상한/하한 정책을 따르며 fail-open 1.0 기본값으로 운영되지 않는다.
168. core는 SIGTERM 수신 시 gRPC 요청 드레인과 outbox flush를 수행한 뒤 종료되어 배포 중 데이터 경계가 보존된다.
169. WS 운영 메트릭(`ws_active_conns/ws_send_queue_p99/ws_dropped_msgs/ws_slow_closes`)은 알람 규칙과 온콜 런북으로 연결된다.
170. Redis 세션/재생방지 저장소는 TLS+ACL 경로만 허용되며 insecure 연결 설정은 프로덕션에서 차단된다.
171. API key 인증 실패(`unknown_key/missing_header`) 경로도 rate-limit·지연·일관응답 정책을 적용해 키 열거 공격을 차단한다.
172. WS RESUME 요청은 symbol 형식/allowlist를 SUB와 동일하게 검증하며 비정상 입력은 즉시 거부된다.
173. market-data cache는 Redis 장애 시 메모리 fallback으로 분기하지 않고 fail-closed/degraded mode로 전환된다.
174. 회원가입 duplicate 판정은 문자열 매칭이 아닌 SQLSTATE/driver code 기준으로 동작해 드라이버 변경에도 안정적이다.
175. ledger 계정 생성은 upsert 원자성을 갖추어 동시 처리에서도 unique 예외로 settlement가 불안정해지지 않는다.
176. reconciliation engine-seq 입력은 `seq>=0`과 symbol 규칙을 통과한 값만 반영되어 상태 오염을 방지한다.
177. K8s audit policy는 secret/configmap 본문을 RequestResponse로 기록하지 않고 redaction 정책을 준수한다.
178. namespace PodSecurity `enforce-version`은 명시 버전으로 pin되어 클러스터 업그레이드 시 정책 drift가 통제된다.
179. auth 실패 reason(`unknown_key/bad_signature/replay`)별 경보가 구성되어 공격 징후를 온콜이 즉시 탐지한다.
180. core gRPC 처리 경로는 async 런타임을 블로킹하는 전역 mutex 경합 없이 동작하며 고동시성 부하에서도 tail latency가 급등하지 않는다.
181. WS 메트릭 수집은 connection 수와 무관한 상수 복잡도로 노출되어 `/metrics` 스크랩이 서비스 성능을 저해하지 않는다.
182. reconciliation 메트릭은 심볼별 라벨 기반으로 수집되어 특정 API 호출이 전역 상태를 덮어써도 가시성이 왜곡되지 않는다.
183. auth 실패 메트릭은 reason별로 분리 노출되어 `unknown_key`와 `replay` 급증을 독립적으로 경보할 수 있다.
184. 세션 저장소에는 최소 claim만 저장되고 email 등 PII는 분리 조회되어 세션 유출 시 노출면이 최소화된다.
185. 인증 저장소 장애는 credential 오류와 구분되어 5xx/알람으로 즉시 관측되며 장애 은닉이 없다.
186. tracing 리소스 태그의 `deployment.environment`는 환경별로 정확히 주입되고 `local` 하드코딩 값으로 운영되지 않는다.
187. K8s audit 정책은 로그 볼륨 budget/retention 한도를 준수하도록 최소권한 규칙으로 구성되어 노이즈·비용 폭주가 통제된다.
188. WS command plane(SUB/UNSUB/RESUME)은 per-connection rate limit을 적용해 flood 입력을 표준 close code/메트릭으로 차단한다.
189. 동일 subscription 반복 SUB는 no-op/쿨다운 정책으로 처리되어 snapshot 재전송 증폭을 유발하지 않는다.
190. edge 런타임 상태 락은 단일 전역 mutex 병목 없이 분리되어 WS fan-out + 주문 동시부하에서도 tail latency 예산을 만족한다.
191. 세션 저장소는 raw token을 저장하지 않고 hash 기반 조회/검증으로 유출 시 즉시 재사용이 불가능한 구조를 강제한다.
192. CI security baseline은 Trivy high/critical 결과에서 fail-closed로 동작해 취약점이 있는 PR을 차단한다.
193. 보안 스캔 SARIF는 code scanning에 업로드되고 미해결 high/critical 이슈가 있으면 merge가 차단된다.
194. `scripts/secret_rotation_drill.sh`는 시뮬레이션 값이 아니라 실제 시크릿 스토어 회전/거부/감사로그 증거로 합격을 판정한다.
195. core Kafka producer는 multi-partition 환경에서도 심볼별 seq ordering이 깨지지 않도록 key 전략(심볼/샤드)을 강제한다.
196. CI/chaos 게이트는 partition>1 토픽에서 심볼별 seq 단조성(역행/중복 0건)을 필수 검증한다.
197. core gRPC는 도메인 reject/권한 오류를 `INTERNAL`로 반환하지 않고 표준 상태코드 계약으로 분류한다.
198. 세션 시스템은 사용자별 활성 세션 상한과 revoke-all watermark를 적용해 탈취 토큰 장기 재사용을 차단한다.
199. 다중 edge 환경에서 logout-all/revoke-all 실행 후 기존 세션 토큰이 전 인스턴스에서 즉시 무효화된다.
200. `EDGE_API_SECRETS`는 최소 길이·entropy·만료 메타 정책을 통과한 key만 로드되며 약한 secret은 부팅 단계에서 차단된다.
201. API key 인벤토리(owner/created_at/expires_at)와 만료 임박 알람이 릴리즈 게이트·운영 알람에 연동된다.
202. `/v1/admin/reconciliation/status` 조회는 전역 최신조회 인덱스와 cursor pagination/rate-limit으로 고빈도 폴링 부하를 통제한다.
203. core `recent_events`는 bounded ring buffer로 관리되어 장시간 운용에서도 메모리 예산을 초과하지 않는다.
204. WS 오류 응답은 내부 `err.Error()` 문자열을 외부로 노출하지 않고 표준 오류코드 계약만 반환한다.
205. core Kafka producer는 수치 직렬화 실패를 `0`으로 강등하지 않고 fail-closed로 이벤트 발행을 중단/격리한다.
206. ledger datasource는 pool 상한/수명/statement timeout 정책과 saturation·slow-query 알람을 갖춘다.
207. CI security workflow는 `security-events: write` 권한과 SARIF 업로드 스텝을 갖추며 업로드 실패 시 즉시 실패한다.
208. chaos 스위트는 core↔ledger, edge↔core network partition/복구 시나리오를 포함하고 복구 후 invariants/reconciliation을 통과한다.
209. CI는 job timeout과 branch concurrency cancel-in-progress로 hang/stale 성공 표시를 허용하지 않는다.
210. edge 외부 트래픽은 TLS termination과 인증서 만료 모니터링/회전 드릴 증거가 없으면 운영 게이트를 통과하지 못한다.
211. WS trades resume는 in-memory 고정창을 넘어도 durable replay buffer 기반 range replay로 갭을 복구할 수 있어야 한다.
212. 주문/WS/market-data 전 경로의 symbol은 canonical form/allowlist 단일 규칙을 통과한 값만 수용한다.
213. 공개 `/v1/markets/*` 엔드포인트는 IP tier rate-limit, 캐시, 429 정책으로 scrape/flood를 흡수한다.
214. security baseline은 `ignore-unfixed`를 기본 허용하지 않고 예외목록·만료일 정책으로만 제한적으로 허용한다.
215. market-data API/WS 대상 abuse drill(고빈도 폴링·연결폭주)을 CI/게임데이에서 상시 검증해 정책 회귀를 차단한다.
216. WS RESUME 재전송은 현재 구독 채널만 전달하며 비구독 채널 데이터가 섞여 전달되지 않는다.
217. edge `state.orders`는 완료 주문 TTL/아카이브 정책으로 장기 운용 메모리 상한을 유지한다.
218. Kafka topic/group-id는 환경·리전 네임스페이스를 강제해 공유 클러스터에서도 cross-env offset 간섭이 없다.
219. Redis session/cache/replay/idempotency 키는 env+service prefix를 강제해 keyspace 충돌이 발생하지 않는다.
220. `invariant_alerts`는 retention/dedup/index 정책과 housekeeping 잡으로 용량 예산을 초과하지 않는다.
221. 공유 Kafka/Redis 환경 분리 드릴에서 dev/staging/prod 간 메시지·키 오염이 0건임을 주기적으로 증명한다.
222. edge 세션 메모리 저장소는 만료 세션에 대한 주기 GC를 수행해 장시간 운용에서도 메모리 증가율 budget을 준수한다.
223. replay/idempotency 만료 정리는 요청당 전맵 스캔 없이 O(1)에 가까운 구조로 동작해 auth hot-path p99를 안정적으로 유지한다.
224. 인증 이후 사용자 캐시/로그에는 `password_hash` 같은 비밀 파생값이 남지 않으며 메모리 덤프 점검에서도 노출되지 않는다.
225. 주문/취소 API는 principal 기반 제한과 IP 기반 제한을 동시에 적용해 키공유·봇폭주 상황에서도 제어를 유지한다.
226. cancel 경로는 symbol 미확정 상태에서 `BTC-KRW` 같은 기본값으로 강등하지 않고 요청을 fail-closed로 종료한다.
227. ledger settlement/reconciliation consumer 동시성 정책은 설정·테스트로 고정되어 버전/운영 변경에도 결정성이 유지된다.
228. `main` 브랜치는 required checks/required approvals 정책이 강제되어 필수 게이트 우회 병합이 발생하지 않는다.
229. core/ledger/infra/security 경로 변경은 CODEOWNERS 리뷰 승인 없이는 병합되지 않는다.
230. DB 마이그레이션은 적용뿐 아니라 rollback/복구 리허설까지 CI에서 통과해야 배포 가능하다.
231. 런타임 환경변수 파싱 실패(숫자/불리언/시크릿)는 기본값 대체 없이 즉시 부팅 실패로 처리된다.
232. 주문+WS+consumer 24시간 soak 테스트에서 메모리/FD/스레드(고루틴) 누수 budget 위반이 0건이어야 한다.
233. 비밀번호 해시는 최소 정책(cost/algorithm)을 충족해야 하며 정책 미달 해시는 로그인 시 즉시 재해시되거나 차단된다.
234. WS 연결별 큐 제한은 메시지 개수뿐 아니라 누적 바이트 기준으로도 강제되어 대형 페이로드 입력에서 메모리 급증이 없다.
235. Kafka trade 이벤트는 크기 상한/스키마 계약을 벗어나면 소비·적용되지 않고 격리되어 다운스트림 오염이 발생하지 않는다.
236. `/v1/markets/*`의 `limit/depth`는 채널별 상한을 넘길 수 없고 과대 입력은 자동 fallback이 아닌 명시적 4xx로 거부된다.
237. 세션은 idle timeout과 absolute lifetime를 동시에 적용해 장시간 무활동·탈취 세션의 재사용 기간을 제한한다.
238. 사용자/인증 캐시(`usersByEmail/usersByID`)는 TTL/용량 정책으로 장기 운용 시 사용자 수 증가에도 메모리 예산을 유지한다.
239. 저장소 정책(branch protection/CODEOWNERS/required checks) 드리프트는 주기 검증되어 누락 시 릴리즈 게이트가 실패한다.
240. Kafka message-size 정책은 broker/topic/producer/consumer 전 계층에서 일치하며 불일치 구성은 배포 전에 차단된다.
241. WS 장시간 soak(혼합 slow/fast 클라이언트)에서 queue p99/drop/slow close/memory SLO를 연속 충족해야 한다.
242. 서명 canonical에는 raw query/content-type/body-digest가 포함되어 쿼리 변조·파라미터 주입 요청이 검증 단계에서 차단된다.
243. trade dedupe 만료 정리는 `markTradeApplied` 요청당 전맵 스캔 없이 수행되어 고체결 구간에서도 소비 p99가 안정적이다.
244. correction 요청은 허용된 mode enum만 수용하며 미지원 mode는 생성 단계에서 거부되어 apply 시점 500 오류가 발생하지 않는다.
245. ledger balance 조회 API는 cursor pagination/limit 상한을 강제해 대량 계정 환경에서 응답 폭주와 DB 풀 고갈을 방지한다.
246. DB deadlock/serialization 같은 재시도 가능 오류는 즉시 DLQ로 버리지 않고 재시도 정책으로 수렴한다.
247. core 명령 `meta.symbol`은 canonical form 검증을 통과한 값만 수용되어 case/format 편차로 인한 오거부가 없다.
248. Ledger API DTO 경계는 `@Valid` 제약으로 필드 길이/형식/범위를 검증해 malformed 입력이 비즈니스 레이어로 유입되지 않는다.
249. 사용자 비밀번호 정책은 최소 길이 외 복잡도·금지목록·재사용 제한을 강제해 약한 자격증명 등록이 차단된다.
250. K8s 워크로드는 non-root/read-only rootfs/capabilities drop/seccomp 표준을 강제하고 예외는 감사 승인으로만 허용된다.
251. core/내부 gRPC 서비스는 표준 health checking API를 제공해 프로브와 서비스 디스커버리가 동일한 상태판정을 사용한다.
252. DB 마이그레이션은 expand/contract 규율을 따르며 구버전·신버전 동시 실행 호환성 테스트를 통과해야 배포된다.
253. 백업 아티팩트는 암호화와 키버전 메타를 포함하며 키회전 후 복구 리허설까지 통과해야 합격한다.
254. 인증 서명검증은 query/body/header 변형 공격 벡터 회귀 테스트를 CI에서 상시 통과한다.
255. 인증/세션 상태맵(`sessions/replay/idempotency/users`)은 장시간 soak에서도 메모리와 tail-latency budget을 초과하지 않는다.
256. core/ledger 시퀀스 카운터는 overflow/rollover 발생 전에 감지·차단되어 잘못된 seq 반영이 없다.
257. `trade_id/settlement_id`는 일자/파티션/재기동과 무관하게 전역 유일하며 중복 삽입은 DB 경계에서 거부된다.
258. symbol mode 전환은 core 상태/이벤트/outbox/admin 조회모델에 동일 seq로 반영되어 불일치가 0건이다.
259. `cancel_all` 실행 중 장애가 발생해도 부분취소 상태가 남지 않고 재시도 후 주문상태가 결정론적으로 수렴한다.
260. open-order와 연결되지 않은 orphan hold는 주기 점검에서 자동 탐지되고 누수 budget 위반 시 즉시 격리된다.
261. 동일 가격/동일 우선순위 주문의 tie-break 결과는 재실행/재기동/리플레이에서 항상 동일하다.
262. 서명 요청은 허용 timestamp window를 벗어나면 거부되고 nonce 재사용 요청은 재전송 공격으로 탐지된다.
263. Postgres PITR 드릴은 임의 시점 복구를 성공시키고 복구 후 invariants/reconciliation을 통과한다.
264. Kafka topic/group ACL은 최소권한 정책을 유지하며 드리프트 검증 실패 시 릴리즈가 차단된다.
265. 메트릭 라벨 카디널리티는 예산을 초과하지 않으며 초과 시 자동 제한/알람으로 스크랩 SLO를 유지한다.
266. P0/P1 경보는 owner/escalation/runbook이 100% 연결되어 온콜이 수동 검색 없이 대응 가능하다.
267. 배포 전 artifact는 provenance/SBOM/서명 검증을 통과한 경우만 승격되며 미검증 빌드는 차단된다.
268. TLS 인증서는 만료 전 자동 갱신·검증되고 폐기/회전 드릴 실패 시 즉시 운영 경보가 발동된다.
269. 시간 동기화 무결성(NTP/PTP)은 step/leap 임계치 초과를 감지해 거래/정산 경로를 보호모드로 전환한다.
270. 감사 로그 hash-chain root는 외부 불변 저장소 앵커와 일치해야 하며 불일치 시 즉시 사고 대응이 시작된다.
271. reconciliation 판정은 event-time/processing-time 드리프트를 분리해 오탐을 줄이고 안전모드 전환 사유가 명확히 기록된다.
272. ledger posting은 별도 hash-chain 검증을 통과해야 하며 체인 검증 실패 시 즉시 읽기제한/사고대응이 시작된다.
273. 공개 API/이벤트 스키마 breaking change는 계약테스트에서 차단되어 하위호환성이 보장된다.
274. cancel-replace 주문은 원자적으로 처리되어 부분취소·중복주문 상태 없이 재시도 시 동일 결과가 보장된다.
275. symbol 모드 전환 사유코드는 WS/API/감사로그에 동일하게 전파되어 운영자와 고객의 관측이 일치한다.
276. DLQ 재처리는 심볼/seq 순서를 보존하며 out-of-order 재적용으로 인한 상태오염이 없다.
277. 조회모델 재빌드 결과 checksum은 원장 기준값과 일치해야 하며 불일치 시 서비스 승격이 차단된다.
278. 수수료 정책은 발효시각 단조 증가 규칙을 지키고 과거시점 소급 적용이 불가능해야 한다.
279. 고위험 admin 액션은 RFC/incident ticket 바인딩 없이는 실행되지 않고 감사로그에서 근거 링크가 추적된다.
280. 대량 admin 액션은 dry-run 영향분석과 checksum 확인을 통과해야만 승인·실행된다.
281. ClickHouse 스키마 드리프트는 배포 전 검증에서 탐지되고 쿼리 호환성 실패 시 차단된다.
282. legal hold 대상 데이터는 TTL/housekeeping에서 제외되어 분쟁 기간 동안 완전 보존된다.
283. chaos는 지연·패킷손실·중복전송을 포함해 실행되며 복구 후 invariants/reconciliation이 모두 통과한다.
284. 동일 소스 빌드는 재현 가능한 artifact 해시를 가져야 하며 재현 실패 artifact는 승격되지 않는다.
285. 보안 예외(CVE/정책)는 만료일·승인·완화근거가 없으면 적용 불가하고 만료 초과 시 자동 차단된다.
286. 키 사용 이상징후(지역/시간대/빈도)는 자동 탐지되어 키 잠금·추가승인으로 즉시 연결된다.
287. 리전 전환 후 core/ledger seq 연속성 및 시계편차 교차검증에 실패하면 트래픽 승격이 차단된다.
288. core 이벤트는 producer 서명/해시 검증을 통과한 경우만 소비되며 위조·변조 메시지는 즉시 격리된다.
289. WAL 내구화와 outbox enqueue는 원자 경계를 가져 한쪽만 반영되는 partial durability 상태가 없어야 한다.
290. settlement 트랜잭션은 동시성 이상을 허용하지 않는 격리수준/충돌검출을 적용해 잔고 일관성을 보장한다.
291. 계정 노출도는 심볼별과 전체 net exposure 규칙을 동시에 만족하며 한도 우회 주문은 거부된다.
292. 재기동 직후 데이터 catch-up 완료 전에는 mutating API가 read-only로 제한되어 불완전 상태 쓰기를 차단한다.
293. 계정해지/삭제요청은 보존의무 분리 규칙을 준수하며 삭제·보존 판단 근거가 감사로그로 추적된다.
294. 출금주소는 체인별 형식/체크섬/태그 검증을 통과해야 하며 whitelist 변경은 승인·타임락을 거친다.
295. admin 키 회전/폐기는 재시도에도 단일 결과를 보장하고 폐기된 키가 재활성화되지 않는다.
296. rate-limit 상태는 재기동/스케일아웃 후에도 유지되어 트래픽 버스트로 제한을 우회할 수 없다.
297. 고위험 admin 액션은 위험등급별 승인 정족수 정책(다중 승인)을 충족해야만 실행된다.
298. 긴급조치(HALT/출금정지)는 표준 사유코드·영향범위·복구계획 입력 없이는 실행되지 않는다.
299. 월간 게임데이는 MTTD/MTTR/SLA 목표를 충족해야 하며 미달 시 릴리즈 승격이 차단된다.
300. 서비스 시작순서/의존 readiness 검증에 실패하면 워크로드가 정상 Ready로 승격되지 않는다.
301. 외부 의존성 위험도(SBOM/CVE/EOL)가 임계치를 넘으면 배포가 자동 차단된다.
302. 백업 복구 후 핵심 데이터 diff/해시 검증이 원본과 일치하지 않으면 복구를 실패로 판정한다.
303. 개인정보 삭제요청은 SLA 내 처리되고 지연/실패는 자동 알람 및 준법 보고로 연결된다.
304. SEV 사고 포스트모템은 기한 내 작성·조치완료가 강제되며 미완료 상태에서 승격이 차단된다.
305. 운영 feature flag 변경은 승인·만료·롤백 정보가 감사로그에 남아야 하며 무승인 변경은 차단된다.
306. evidence bundle은 파일별 해시 manifest와 서명 검증을 통과한 경우만 릴리즈 증거로 인정된다.
307. tenant/account scope는 API부터 ledger 반영까지 누락 없이 전파되어 교차계정 데이터 노출이 0건이어야 한다.
308. DLQ 재처리는 최대 재시도 정책을 넘는 poison 이벤트를 무한 루프 없이 격리 상태로 종료해야 한다.
309. WS snapshot은 checksum/version mismatch를 즉시 탐지하고 자동 재동기화로 상태 불일치를 해소해야 한다.
310. orderbook delta는 depth별 sequence 연속성을 만족해야 하며 누락/역행 delta는 반영되지 않는다.
311. 부분체결/다중수수료 자산 시나리오에서도 수수료 반올림 누계 오차가 불변조건을 깨지 않아야 한다.
312. 멀티노드 시간편차 환경에서도 idempotency TTL 판정이 일관되어 재요청 처리 결과가 흔들리지 않는다.
313. 복구모드에서는 승인된 운영 액션 외 모든 쓰기 경로가 차단되어야 하며 우회 호출이 없어야 한다.
314. safety-case/evidence 번들에는 PII/비밀정보가 포함되지 않아야 하며 검출 시 생성이 실패해야 한다.
315. reversal/correction posting은 원거래 인과관계 링크를 필수로 가져 orphan reversal이 생성되지 않는다.
316. safety latch 해제는 2인 승인과 영향요약 재확인을 모두 통과해야만 실행된다.
317. 고위험 admin 액션 직전 step-up 재인증이 강제되어 장기세션 탈취로는 실행이 불가능해야 한다.
318. Kafka disk 압박(디스크 full/quota 초과) chaos 후에도 데이터 유실 없이 복구되고 정합성 검증을 통과한다.
319. WORM object-lock/retention 정책이 변경·해제되지 않았음을 주기 검증하고 위반 시 즉시 경보가 발생한다.
320. 백업 복구는 격리 계정/망에서만 수행되고 프로덕션 자격증명 재사용이 없어야 한다.
321. 실제 클러스터 설정 drift가 Git 선언과 다르면 자동 경보·배포 차단이 동작해야 한다.
322. synthetic canary 주문 경로가 주기 실행되어 실패 시 즉시 탐지·경보·격리 조치로 연결되어야 한다.
323. 핵심 감사로그는 서명된 타임스탬프를 포함해 사후 시간조작 의혹을 독립적으로 검증할 수 있어야 한다.
324. secret 접근(read/write) 이벤트는 100% 감사기록으로 남고 누락 시 보안게이트가 실패해야 한다.
325. synthetic pager probe는 전달 성공률/지연 SLO를 지속 충족해야 하며 미달 시 온콜 체계가 개선될 때까지 승격이 차단된다.
326. correlation/causation ID는 edge→core→ledger→audit 전 경로에서 누락 없이 전파되어 사건추적 단절이 없어야 한다.
327. replay/rebuild 증거는 archive range·snapshot·commit hash를 고정해 어떤 입력으로 재현했는지 완전 추적 가능해야 한다.
328. 동일 settlement 배치는 노드/재시작과 무관하게 동일 순서·동일 결과를 내고 결과 해시가 일치해야 한다.
329. WAL/snapshot 스키마 버전 변경은 호환성 검증을 통과해야 하며 실패 시 부팅/복구가 차단된다.
330. HALT→AUCTION→CONTINUOUS 전환은 정책 타이머/조건으로만 진행되고 수동개입은 감사증적이 남아야 한다.
331. 자산 precision scale 불일치 입력은 경계에서 거부되어 단위 혼합으로 잔고가 오염되지 않아야 한다.
332. reconciliation history와 safety 상태 변경은 append-only로 보존되고 수정/삭제 시도는 즉시 탐지되어야 한다.
333. 동일 출금 fingerprint 요청은 재시도/중복 제출에도 단일 효과만 발생해야 한다.
334. 상장/거래중지/상장폐지 전환은 발효시각 기준을 준수하며 조기/지연 적용이 없어야 한다.
335. 동일 입력의 risk policy 평가는 노드별로 결정론적으로 일치해야 하며 race 조건으로 결과가 달라지지 않아야 한다.
336. 승인 경합/거절/만료 상태는 UI에 실시간 반영되어 stale 승인으로 실행되는 사고가 없어야 한다.
337. 긴급모드 해제는 필수 체크리스트(invariants/recon/lag/승인) 완료 없이는 불가능해야 한다.
338. consumer rebalance/fencing churn chaos 후에도 중복적용·누락 없이 복구되어 정합성 검증을 통과해야 한다.
339. archive replay 처리량/완료시간은 SLO를 충족해야 하며 미달 시 복구게이트가 실패해야 한다.
340. object storage lifecycle/retention drift는 주기검증으로 탐지되어 조기삭제 사고를 차단해야 한다.
341. controls/assurance 증거는 최신성 기준을 충족해야 하며 오래된 증거로 릴리즈를 통과할 수 없어야 한다.
342. 리전 장애 시 DNS failover 드릴이 전환시간 SLO를 만족해야 하며 미달 시 승격이 차단된다.
343. 다중 시간원 장애 상황에서도 시간동기 경보와 보호모드 전환이 정상 동작해야 한다.
344. 동일 기간 규제 리포트 export는 재실행마다 동일해야 하며 차이는 승인된 변경사유로만 설명 가능해야 한다.
345. 보안/감사 이벤트의 SIEM 전달 누락률은 임계치 이하로 유지되어야 하며 초과 시 배포가 차단된다.
346. 안전모드 전환/해제 액션은 원인 breach/invariant 이벤트와 인과관계 ID로 연결되어 사후 추적이 완전해야 한다.
347. seq hole backfill/replay가 성공하기 전에는 정상모드 복귀가 금지되고 backfill 증거가 보존되어야 한다.
348. 교차통화 체결에서도 기준통화 보존식과 수수료 보존식이 동시에 성립해야 한다.
349. symbol mode 잦은 토글은 cooldown 정책으로 제어되어 운영자 오조작으로 인한 진동 상태가 없어야 한다.
350. 스케줄 지터/랜덤 지연 주입 조건에서도 core replay state hash가 반복적으로 동일해야 한다.
351. market data 지연/정지 시 WS/API는 stale 상태와 마지막 갱신시각을 일관되게 노출해야 한다.
352. KYT/AML 케이스 상태머신 전이는 허용된 경로만 가능해야 하며 불법 전이는 차단되어야 한다.
353. 온체인 reorg 시 입금/출금 상태는 재평가되어 이중 credit 또는 조기 확정이 발생하지 않아야 한다.
354. 외부 의존 장애 시 retry-budget/circuit 정책이 무한 재시도를 막고 시스템 생존성을 유지해야 한다.
355. 주문 거절 사유코드는 표준 taxonomy를 준수해 리포트·감사에서 코드 의미가 일관되어야 한다.
356. 안전모드 타임라인 대시보드는 탐지→격리→복구승인 전체 근거를 단일 화면에서 추적 가능해야 한다.
357. 승인 대기 SLA 초과 건은 자동 에스컬레이션되어 장기 미승인 상태가 방치되지 않아야 한다.
358. push 단계 secret leak 검출은 fail-closed로 동작하고 예외승인은 만료·근거·승인자를 포함해야 한다.
359. 용량 포화 synthetic probe에서 자동 제한/알람 정책이 정상 발동해 장애 확산을 억제해야 한다.
360. 감사조회 결과는 원본 hash-chain 앵커와 일치해야 하며 조회스토어 변조가 탐지되어야 한다.
361. 비용지표 예산 초과 시 경보와 단계적 기능제한 정책이 자동 발동되어 비용폭주를 통제해야 한다.
362. dependency pin 드리프트는 미승인 버전 승격을 차단하고 변경근거를 감사로그로 남겨야 한다.
363. 규제 제출 cut-off 달력 위반(지연/누락)은 자동 탐지되어 제출 전까지 승격이 차단되어야 한다.
364. 사고 커뮤니케이션 훈련은 정기적으로 성공해야 하며 실패 시 온콜/운영 체계 개선 전 승격이 차단된다.
365. 리전 격리(evacuation) 훈련에서 트래픽 우회와 데이터 정합성 유지가 검증되어야 한다.
366. producer/consumer는 허용된 schema hash만 수용해 임의 스키마 변형 이벤트를 처리하지 않아야 한다.
367. 신규/재상장 심볼은 대사 감시 대상 자동등록이 완료되기 전 거래가 시작될 수 없어야 한다.
368. 복구 dry-run은 운영 데이터에 부작용을 남기지 않는 격리 실행으로 검증되어야 한다.
369. correction 적용 전 영향범위가 임계치를 넘으면 자동으로 2차 승인 절차가 강제되어야 한다.
370. settlement 누락 구간은 journal gap marker로 추적되며 해소 전에는 정상복귀/마감이 금지되어야 한다.
371. WS RESUME는 nonce/TTL anti-replay 검증을 통과한 요청만 수용되어야 한다.
372. fanout 샤드 리밸런싱 중에도 이벤트 중복·누락 없이 seq 연속성이 유지되어야 한다.
373. 계정 동결/해제 전파는 주문·출금·세션 경로에 SLA 내 반영되어야 하며 지연 시 자동 경보가 발생해야 한다.
374. 강제청산 주문도 가격밴드/서킷브레이커 정책을 우회할 수 없어야 한다.
375. 재현 실행의 난수 seed는 증거 번들에 고정 기록되어 seed 누락 실행이 허용되지 않아야 한다.
376. AML/KYT 케이스 큐의 대기시간/SLA/에스컬레이션 상태가 운영 UI에서 실시간으로 관리되어야 한다.
377. 릴리즈 증거 번들의 서명/검증상태가 관리 콘솔에서 확인 가능해야 하며 미검증 번들은 승격되지 않아야 한다.
378. kernel fault chaos(I/O 지연·FS 오류·OOM-kill) 후에도 복구 정합성 검증을 통과해야 한다.
379. snapshot checksum은 독립 에스크로 저장소와 교차검증되어 백업 저장소 변조를 탐지해야 한다.
380. 폐기 예정 API는 종료 기한 위반 시 배포가 차단되고 마이그레이션 진행상태가 추적되어야 한다.
381. 백업 카탈로그(세대/키/체크섬/보존기한)의 불일치가 탐지되면 복구게이트가 실패해야 한다.
382. 온콜 교대 시 미해결 사고/알람 인수인계 누락이 있으면 온콜 체계 승격이 차단되어야 한다.
383. 서명키 롤오버는 무중단으로 검증되어야 하며 구키/신키 전환 실패가 없어야 한다.
384. 대사 평가 주기 지연이 SLO를 초과하면 안전모드 판단 신뢰도 저하 경보가 즉시 발동되어야 한다.
385. 사고 공지는 다중 채널 전달 성공률을 지속 충족해야 하며 누락 공지 위험이 있으면 승격이 차단되어야 한다.
386. 주문→체결→정산→리포트 데이터 라인리지 checkpoint가 유지되어 중간 변환 누락/분기를 탐지할 수 있어야 한다.
387. replay/rebuild 입력은 승인된 source allowlist만 허용되고 임의 파일 주입이 차단되어야 한다.
388. HALT 모드에서는 신규 주문 유입 경로가 완전히 차단되고 취소 경로만 허용되어야 한다.
389. 모든 posting/correction은 표준 reason code를 포함해 회계·감사 분류가 일관되어야 한다.
390. 운영 override 권한은 TTL 만료 시 자동 회수되어 만료 권한으로 실행이 불가능해야 한다.
391. 리전간 이벤트 병합은 timestamp monotonic 규칙을 만족해 역행 정렬로 인한 상태오염이 없어야 한다.
392. snapshot 암호화키는 환경/리전/서비스 컨텍스트에 바인딩되어 교차환경 복호화가 불가능해야 한다.
393. 포트폴리오 평가 가격소스는 버전 고정되어 동일 시점 재평가 결과가 변하지 않아야 한다.
394. 신규 risk 정책은 shadow-eval 오탐/누락 기준을 통과한 뒤에만 활성화되어야 한다.
395. 동일 사고/모드전환 공지는 채널별 멱등키로 중복 발송 없이 누락 없이 전달되어야 한다.
396. 정책 변경 diff는 위험도 히트맵으로 시각화되어 승인자가 영향도를 정량 검토할 수 있어야 한다.
397. 사고 evidence bundle은 검토/승인 상태가 추적되어 미검토 상태에서 사고 종결이 불가능해야 한다.
398. 복구 리허설 캘린더 미이행은 자동 경보와 승격 차단으로 연결되어야 한다.
399. KMS 권한 드리프트(과권한/오권한)는 주기검증으로 탐지되어 배포 전에 차단되어야 한다.
400. legal hold·보존정책·삭제요청 충돌은 자동 판정되어 정책 위반 삭제/과보존이 없어야 한다.
401. edge-core-ledger 계약 테스트 매트릭스가 버전 조합별로 통과되어야 릴리즈가 가능해야 한다.
402. flaky 테스트는 자동 격리되더라도 대체 신뢰 게이트 없이는 릴리즈를 통과할 수 없어야 한다.
403. 패닉/크래시 코어덤프는 암호화·접근제어·보존정책을 준수해 보안사고로 확산되지 않아야 한다.
404. 외부 제출 데이터에는 워터마크(발급자/시각/해시)가 포함되어 유출 추적이 가능해야 한다.
405. shadow traffic 비교에서 응답/지연/정산 결과 편차가 임계치를 넘으면 배포가 차단되어야 한다.
406. 안전모드 판정 시 입력 임계치/지표/결과 스냅샷이 저장되어 사후 explainability가 가능해야 한다.
407. processed-events 멱등키 구성 변경은 호환성 검증 없이는 배포되지 않아 중복반영 회귀가 없어야 한다.
408. snapshot/WAL 복구는 바이너리 호환 버전 검증을 통과해야 하며 미지원 버전 복구가 차단되어야 한다.
409. kill-switch는 지정 스코프 외 트래픽에 영향 주지 않아야 하며 경계 오작동이 없어야 한다.
410. 환산(FX) 소스의 버전/시각/서명이 보존되어 정산·회계 재현 시 동일 입력이 보장되어야 한다.
411. 사용자 거래명세서는 동일 기간 재생성 시 결과가 완전히 동일해야 한다.
412. 수수료 리베이트/프로모션 정산은 재처리에도 1회 효과만 반영되어야 한다.
413. 계정 동결과 in-flight 처리 경합에서 동결 이후 신규 체결/출금이 발생하지 않아야 한다.
414. market data replay는 워터마크 기준으로 중복 구간 없이 정확히 이어져야 한다.
415. DLQ 레코드는 원본 offset/hash/error context와 함께 보존되어 포렌식 추적이 완전해야 한다.
416. 준법 override 요청은 전용 리뷰 큐를 거쳐야 하며 일반 운영 승인 플로우로 우회되지 않아야 한다.
417. 승인 대기/타임락 만료 액션은 자동 취소·권한 회수되어 만료 후 실행이 불가능해야 한다.
418. 장애주입 훈련은 난수화된 시점/순서에서도 통과해야 하며 고정 시나리오 최적화에 의존하지 않아야 한다.
419. 경보 오탐/중복률이 예산을 넘으면 규칙 개선 전까지 승격이 차단되어야 한다.
420. 감사 저장소 용량/증가율 예산은 임계치 초과 전에 자동 대응이 동작해야 한다.
421. 백업은 분리 저장소(air-gap) 존재가 주기적으로 검증되어 동시오염 위험이 통제되어야 한다.
422. Incident Commander 순환훈련/백업지정이 유지되지 않으면 온콜 체계 승격이 차단되어야 한다.
423. 키 유출 시뮬레이션에서 폐기·재발급·세션무효화·감사보고가 SLO 내 완료되어야 한다.
424. 공급망 무결성 목표(SLSA)가 충족되지 않은 빌드는 배포 승격이 차단되어야 한다.
425. observability 파이프라인 적체 시 서비스 경로 보호를 위한 backpressure/drop 정책이 검증되어야 한다.
426. 대사 임계치 인근 진동에서도 safety mode는 히스테리시스/최소유지시간 정책으로 flap되지 않아야 한다.
427. outbox cursor 재처리 구간이 발생해도 다운스트림 반영은 멱등하게 1회 효과로 수렴해야 한다.
428. WS 구독은 사용자 권한 스코프를 벗어난 채널/심볼 요청을 수용하지 않아야 한다.
429. 체결 시점 FX rate 기준이 정산 완료까지 고정되어 동일 입력 정산 결과가 변하지 않아야 한다.
430. correction apply 재시도/중복 요청에서도 중복 reversal이 생성되지 않아야 한다.
431. 리스크 허용/거절 결정은 policy version/hash를 포함해 사후 재현 가능해야 한다.
432. 부분체결 누적 수수료는 체결 분할 방식과 무관하게 동일 총액으로 수렴해야 한다.
433. 출금 상태 전이는 단조 규칙을 위반하지 않아야 하며 역행/건너뛰기 전이는 차단되어야 한다.
434. 동일 entity 감사 이벤트 순서는 논리시계 기준으로 단조 증가해야 한다.
435. 서비스 모드별 API 허용/거부와 에러코드 계약은 회귀 없이 일관되어야 한다.
436. 사고 대응 역할(지휘/통신/기술조치) 할당 공석이 발생하면 즉시 보강되도록 운영 UI에서 강제되어야 한다.
437. 외부 제출 증거 번들의 민감정보 마스킹 검수는 2인 승인 없이는 통과될 수 없어야 한다.
438. chaos 실행은 seed/시나리오/결과가 레지스트리에 보존되어 재현 불가능한 결과가 없어야 한다.
439. 시간원 변경/오프셋 이상 이벤트는 tamper-evident 감사로그로 남아야 한다.
440. DR 복구 의존성 인벤토리 누락이 있으면 복구훈련/승격이 차단되어야 한다.
441. 핵심 알람 룰은 synthetic 단위테스트를 통과하지 못하면 활성화되지 않아야 한다.
442. Kafka 토픽 정책 드리프트(retention/cleanup/minISR 등)는 자동 탐지되어 데이터 손실 위험 배포가 차단되어야 한다.
443. OTel 샘플링 정책은 환경별 예산을 초과하지 않아야 하며 초과 시 자동 롤백/경보가 동작해야 한다.
444. 증적/리플레이 아티팩트 보존량 예산 초과 시 계층화/압축/아카이브 정책이 자동 실행되어야 한다.
445. 통제-규제 매핑 문서는 최신성 SLA를 충족해야 하며 만료된 매핑 상태에서 릴리즈가 차단되어야 한다.
446. 대사 판정은 룰/임계치 버전과 함께 기록되어 과거 판정을 동일 조건으로 재현할 수 있어야 한다.
447. ledger applied seq 갱신은 fence 검증된 consumer만 수행해 stale worker의 역행 갱신이 없어야 한다.
448. WS conflation은 최신 상태 정확도를 보장하고 stale 메시지가 최신 상태를 덮어쓰지 않아야 한다.
449. trade resume에서 복구 불가 gap은 명시 어노테이션으로 노출되어 사용자 오인이 없어야 한다.
450. 가격밴드 기준가격 산출 소스/윈도우는 고정되어 기준 변조 및 시점 불일치가 없어야 한다.
451. EOD close 윈도우 동안 비허용 상태변경이 차단되어 마감 스냅샷 일관성이 유지되어야 한다.
452. 출금 요청 재생 허용창 정책으로 오래된 요청 재생 이중출금 위험이 차단되어야 한다.
453. 계정 제한은 세션/API key/하위 권한으로 즉시 전파되어 우회가 불가능해야 한다.
454. 관리자 액션-시스템 반응-알람은 correlation ID로 단일 추적 가능해야 한다.
455. 정상복귀 전 breach 구간 replay 검증을 통과하지 못하면 safety mode 해제가 차단되어야 한다.
456. breach triage 보드에서 미분류/미조치 breach는 종결 처리될 수 없어야 한다.
457. 동시 모드변경 충돌은 우선순위 규칙으로 일관되게 해소되어 모순 상태가 없어야 한다.
458. P0/P1 알람은 티켓 자동생성/연결이 누락되지 않아야 하며 누락 시 게이트가 실패해야 한다.
459. 대용량 replay는 런타임 예산(CPU/메모리/시간)을 초과하면 조기 실패로 판정되어야 한다.
460. DR 훈련 입력 데이터 최신성 기준을 충족하지 못하면 합격 처리되지 않아야 한다.
461. 이미지 취약점 스캔 결과는 유효기간 내 최신 결과만 배포 판정에 사용되어야 한다.
462. p99 악화 시 서비스별 원인분해 리포트가 자동 생성되어야 하며 없으면 게이트가 실패해야 한다.
463. 규제 제출물은 대응 evidence bundle 링크가 필수이며 누락 제출이 차단되어야 한다.
464. 에스컬레이션 채널 헬스체크 실패가 지속되면 온콜/배포 승격이 차단되어야 한다.
465. 관측 데이터 스키마 변경은 계약테스트를 통과해야 하며 미호환 변경 배포가 차단되어야 한다.
466. 대사 입력 소스가 다중화된 경우 quorum 검증을 통과한 값만 안전모드 판정에 사용되어야 한다.
467. settlement watermark/last_settled_seq는 역행 갱신이 불가능해야 하며 단조성을 유지해야 한다.
468. WS replay 가능 범위는 서버-클라이언트 협상으로 명시되고 범위 밖 요청은 표준 재동기화로 처리되어야 한다.
469. orderbook snapshot과 delta는 동일 epoch 검증을 통과해야 하며 epoch 혼합 반영이 없어야 한다.
470. 고위험 admin 요청은 서명된 payload 검증을 통과해야 하며 중간 변조 요청이 실행되지 않아야 한다.
471. 수수료 정책 롤백은 승인된 이전 버전으로만 가능하며 비승인/비연속 롤백이 차단되어야 한다.
472. trade bust는 원체결·정산취소 인과관계가 완전해야만 실행되고 orphan bust가 없어야 한다.
473. 일마감 손익 이월값은 다음 영업일 시작값과 일치해야 하며 경계일 중복반영이 없어야 한다.
474. 노출도 캐시는 상태변경 이벤트 직후 즉시 무효화되어 stale risk 판정이 없어야 한다.
475. safety latch 상태와 승인 이력은 장애/재시작 후에도 보존되어 fail-open 해제가 불가능해야 한다.
476. breach 판정 근거는 운영 UI에서 즉시 조회 가능해야 하며 블랙박스 판정이 없어야 한다.
477. DR 복구 재개 전 승인 체크리스트가 완료되지 않으면 재개 액션이 차단되어야 한다.
478. 소비지연 추세 예측 경보가 임계치 도달 전에 발동되어 선제 대응이 가능해야 한다.
479. 복구 데이터셋은 무작위 checksum challenge를 통과해야 하며 무결성 위양성 합격이 없어야 한다.
480. chaos/DR 훈련 환경은 운영과 동등성 검증을 통과해야만 합격으로 인정되어야 한다.
481. object-lock/retention 변경 이벤트는 주기 export 검증으로 무단 변경이 탐지되어야 한다.
482. 정책 롤백 리허설 실패 상태에서는 운영 배포 승격이 차단되어야 한다.
483. 사고 타임라인은 시간원 보정 규칙으로 정렬되어 채널별 시각 불일치 보고가 없어야 한다.
484. 핵심 준법 증거 번들은 외부 공증/타임스탬프 고정을 거쳐 변조 논란을 차단해야 한다.
485. 운영 대시보드 구성이 기준 템플릿에서 이탈하면 자동 탐지·복구가 동작해야 한다.
486. 대사 규칙 충돌 시 우선순위 규칙으로 단일 판정만 허용되어 모호 판정이 없어야 한다.
487. settlement 재시도는 attempt 인과관계를 유지해 중복적용 없이 동일 결과로 수렴해야 한다.
488. WS resume backfill은 실시간 fanout 예산을 침해하지 않도록 throttle 제어가 동작해야 한다.
489. 캔들 집계 경계 이벤트는 중복/누락 없이 고정 경계 규칙으로 처리되어야 한다.
490. 리스크 정책 드리프트가 감지되면 승인 복구 전 신규 주문 허용이 중지되어야 한다.
491. 과거 기간 손익 재계산은 실행환경과 무관하게 동일 결과를 보장해야 한다.
492. 출금 승인 체인은 요청자/승인자/실행자 분리가 강제되어 self-approve가 불가능해야 한다.
493. 계정 제한 만료 해제는 조건 검증 통과 시에만 수행되고 자동 fail-open 해제가 없어야 한다.
494. 감사로그 backfill은 원본 순서/해시 사슬을 유지해 재기록 변조를 허용하지 않아야 한다.
495. breach 심화 시 안전모드 단계 승격은 정책 순서대로 자동 적용되고 역행 승격이 없어야 한다.
496. 안전모드 단계 승격/완화 내역은 UI에서 승인 이력과 함께 추적 가능해야 한다.
497. 규제 제출 준비 보드는 증거/승인/마감 상태 미완료 제출을 차단해야 한다.
498. 알람 발행→수신 지연은 SLO를 지속 충족해야 하며 초과 시 승격이 차단되어야 한다.
499. 복구 파이프라인 단계 교착은 타임아웃 fail-fast로 감지되어 무한대기가 없어야 한다.
500. DR 전환/복구 승인 체인은 tamper-evident 로그로 보존되고 단일 승인 전환이 차단되어야 한다.
501. 런타임 시크릿 나이/만료 주기는 정책을 넘지 않아야 하며 초과 시 교체 드릴이 강제되어야 한다.
502. latency histogram 수집 무결성(누락/리셋 이상)이 보장되어 성능게이트 위양성이 없어야 한다.
503. 규제 제출 달력 변경은 승인·이력·알림을 거치지 않으면 반영될 수 없어야 한다.
504. 사고 종결 전 필수 아티팩트가 누락되면 종결 승인이 차단되어야 한다.
505. 대시보드 패널과 알람 룰 매핑 누락이 없어 blind spot 없는 관측체계를 유지해야 한다.
506. 대사 메트릭 라벨 cardinality 상한이 유지되어 심볼 폭증 시 관측 시스템 과부하가 없어야 한다.
507. 동일 거래의 다중 source 유입에서도 source fingerprint로 중복 settlement 적용이 차단되어야 한다.
508. WS close 사유코드는 표준 계약을 따르며 클라이언트 복구 로직 혼선이 없어야 한다.
509. 지연 체결 반영 정책이 고정되어 실시간/재생성 캔들 불일치가 없어야 한다.
510. 리스크 한도 충돌 시 우선순위 체계로 허용/거절 결정이 일관되어야 한다.
511. 영업일 cutover 동안 ledger write fence가 동작해 경계시간 이중반영이 없어야 한다.
512. 출금 대기열 공정성 규칙으로 특정 계정/자산 starvation이 발생하지 않아야 한다.
513. 계정 제한/해제 사유코드는 표준 taxonomy를 준수해 보고/감사가 일관되어야 한다.
514. 감사로그 export 결과와 조회 API 결과가 일치해 필터/정렬 차이 누락이 없어야 한다.
515. 안전모드 해제 후 cooldown 정책이 동작해 모드 진동이 완화되어야 한다.
516. 사고 SLA 위반 항목은 조치 완료 전 종결될 수 없어야 한다.
517. 제출물 필수 증거 체크리스트 누락 시 제출 승인 액션이 차단되어야 한다.
518. 알람 suppression 변경은 감사기록으로 남고 만료 초과 suppression이 자동 차단되어야 한다.
519. replay 중 I/O 예산 초과 시 단계적 제한/경보가 발동되어 시스템 안정성이 유지되어야 한다.
520. DR 런북/스크립트는 체크섬 검증을 통과한 승인본으로만 실행되어야 한다.
521. 시크릿 회전은 전후 검증·거부 로그 증적이 있어야 릴리즈 승격이 허용되어야 한다.
522. SLO 계산 윈도우 무결성(누락/중복 집계)이 보장되어 잘못된 합격 판정이 없어야 한다.
523. 규제 제출물 수신 ack 증적이 없으면 제출 완료로 처리되지 않아야 한다.
524. 에스컬레이션 통보 ack timeout 초과 시 자동 상위 에스컬레이션이 동작해야 한다.
525. 운영 대시보드 버전은 릴리즈와 함께 pin되어 임의 변경 배포가 차단되어야 한다.
526. 대사 임계치 변경은 canary 검증 후 단계적 반영만 허용되어 일괄 오적용이 없어야 한다.
527. settlement checkpoint는 서명된 seq/hash/작성주체 증적으로 보존되어 위조 복구가 차단되어야 한다.
528. WS replay 구간 중복 메시지는 dedupe horizon으로 제거되어 클라이언트 중복 반영이 없어야 한다.
529. orderbook depth 계약 위반 데이터는 즉시 재동기화로 전환되어 오염 상태가 유지되지 않아야 한다.
530. 주문 승인 시점 리스크 밴드 스냅샷이 보존되어 승인/거절 근거를 재현할 수 있어야 한다.
531. EOD freeze 예외 수행은 예외코드·승인자·영향범위 감사기록이 필수여야 한다.
532. 출금 대기열 checkpoint로 장애 후 순서/상태 복구가 결정론적으로 이루어져야 한다.
533. 계정 제한 해제 후 cooldown 동안 고위험 액션 제한이 적용되어 재남용이 차단되어야 한다.
534. 감사 표본추출 리포트는 원본 이벤트 집합과 일치해야 하며 표본 왜곡이 없어야 한다.
535. 안전모드 상태와 메트릭 값 불일치가 발생하면 자동 경보/격리가 동작해야 한다.
536. 대사 정책 변경은 diff·영향요약·2인 승인 없이 적용될 수 없어야 한다.
537. 사고 종결 증거 매트릭스가 완성되지 않으면 종결 승인이 차단되어야 한다.
538. 알람 의존 시스템 헬스 실패가 지속되면 알람 신뢰도 경보가 발동되어야 한다.
539. replay 필수 아티팩트 가용성 점검에서 누락이 발견되면 즉시 복구/승격이 차단되어야 한다.
540. DR 대상 DNS TTL/캐시 정책은 전환 SLO를 충족하도록 유지되어야 한다.
541. 폐기된 시크릿/키는 모든 인스턴스에 SLA 내 전파되어 재사용이 불가능해야 한다.
542. SLO burn-rate 윈도우 drift는 탐지되어 경보 민감도 붕괴가 없어야 한다.
543. 규제 제출 실패 시 재전송 전략이 동작해 누락 제출이 발생하지 않아야 한다.
544. 온콜 로스터 최신성 검증 실패 시 온콜/배포 승격이 차단되어야 한다.
545. 대시보드 프로비저닝 코드와 실배포 상태 drift는 자동 탐지되어 수동패치 누락이 없어야 한다.
546. breach 탐지 시점 core seq·ledger seq·mode 상태는 원자 스냅샷으로 보존되어 경합 오판정이 없어야 한다.
547. trade 단위 EXECUTED→SETTLED 지연 예산이 강제되고 초과 체결은 출금/정산 경로에서 차단되어야 한다.
548. WS resume cursor는 stale/future 값을 허용하지 않고 결정론적 오류코드+재동기화로 처리되어야 한다.
549. book snapshot/delta epoch·seq는 단조성을 유지하며 혼합 epoch 반영이 없어야 한다.
550. 리스크 노출 캐시 재계산 receipt가 남아 stale 판정 복구 경로를 추적할 수 있어야 한다.
551. 수수료 반올림 규칙은 core/ledger/리포트에서 단일 규칙으로 동작해 금액 편차가 없어야 한다.
552. 출금 idempotency는 account/asset/request 범위로 고정되고 payload 상이 중복요청은 거부되어야 한다.
553. 계정 제한/해제 이벤트는 모든 주문·출금 경계에 SLA 내 전파되어 fail-open 구간이 없어야 한다.
554. 감사 이벤트에는 시계오프셋/보정정보가 포함되어 다중소스 타임라인 재구성이 가능해야 한다.
555. HALT/READ_ONLY 모드에서 API 우회 내부 write 경로까지 도메인 fence로 차단되어야 한다.
556. safety latch 설정/해제 승인 타임라인과 근거 증거가 누락되면 해제 승인이 차단되어야 한다.
557. 동일 감사 질의의 조회/내보내기 결과 해시가 일치해 재현성 논란이 없어야 한다.
558. core/ledger/ws 노드 시계편차 예산이 유지되어 시간기반 판정 오류가 없어야 한다.
559. Kafka/Core/Ledger/WS 재기동 순서 의존성이 chaos로 검증되어 split-brain성 복구가 없어야 한다.
560. DR 훈련 중 active/passive 동시 writable 상태가 발생하지 않고 탐지 즉시 fence가 동작해야 한다.
561. 실행중 컨테이너 digest는 배포 attestation과 일치해야 하며 drift는 자동 격리되어야 한다.
562. WS resume backfill은 별도 예산으로 제어되어 라이브 fan-out p99를 침해하지 않아야 한다.
563. 규제 제출 cutoff 시각은 timezone/DST 계약을 만족해 마감 오판정이 없어야 한다.
564. 사고 타임라인은 로그·트레이스·감사로그 소스 결합 완전성을 만족해야 종결될 수 있어야 한다.
565. safety-critical 설정 롤아웃은 배치 상한·자동 롤백으로 광역 오적용이 차단되어야 한다.
566. core/ledger seq 비교는 동일 cutoff 시각 기준으로만 수행되어 phantom lag/mismatch 오탐이 없어야 한다.
567. ledger posting 반영과 applied_seq 갱신은 원자 트랜잭션으로 수행되어 부분커밋 불일치가 없어야 한다.
568. WS 채널별 eventVersion allowlist가 강제되어 미지원 버전 메시지 수용이 없어야 한다.
569. snapshot 이후 book delta 체인은 prev_seq/checksum 검증을 통과해야 하며 누락·재정렬 반영이 없어야 한다.
570. 동일 입력(주문/한도/정책버전)은 replica 간 동일 리스크 결정으로 수렴해야 한다.
571. settlement 재시도는 상한·백오프·에스컬레이션 정책으로 제어되어 무한 재시도가 없어야 한다.
572. 출금 상태머신은 유효 전이만 허용되어 skip/backward/중복 전이가 없어야 한다.
573. 계정제한·심볼모드·전사모드 충돌 시 우선순위 규칙이 고정되어 경계별 상이 동작이 없어야 한다.
574. 모든 체결은 SLO 내 settlement 또는 예외사유를 가져야 하며 orphan trade가 없어야 한다.
575. cancel-all 반복 호출/재시도에서도 주문상태·감사로그 결과는 단일 상태로 수렴해야 한다.
576. 안전모드 override 요청은 사유·영향범위·서명 검증 없이는 제출/승인될 수 없어야 한다.
577. 릴리즈 예외(waiver)는 만료·승인·대체통제 증거가 없으면 적용되지 않고 자동 만료되어야 한다.
578. 프로토/이벤트 스키마 변경은 backward/forward 호환성 테스트를 통과해야만 배포될 수 있어야 한다.
579. Kafka partition skew/hot partition은 임계치 초과 시 자동 경보·격리로 소비지연 편중을 완화해야 한다.
580. snapshot 업로드 아티팩트는 object-lock/retention 검증을 통과한 경우에만 복구 입력으로 사용되어야 한다.
581. NTP step/leap-second/clock jump 장애주입에서도 시간기반 판정 오작동이 없어야 한다.
582. safety-critical 설정 canary 중 SLO/lag 악화 시 자동 중단·롤백이 즉시 동작해야 한다.
583. API→Kafka→Ledger→Audit 전 구간 trace/correlation ID 연계가 완전해야 한다.
584. 런타임 설정 해시는 서명된 소스와 일치해야 하며 drift는 즉시 경보·승격 차단되어야 한다.
585. 백업 최신성(RPO)과 실제 복원 성공 증적이 없으면 배포/재개 승인이 차단되어야 한다.
586. core/ledger watermark는 동일 배치 경계 기준으로 산출되어 배치 경계 불일치 오판정이 없어야 한다.
587. consumer resume cursor와 applied_seq 저장은 원자화되어 재기동 후 역행/중복 재처리가 없어야 한다.
588. WS 채널 구독은 계정/심볼 권한 스코프를 강제해 권한외 스트림 수신이 없어야 한다.
589. 캔들 윈도우 경계(UTC/DST/지연입력) 계산은 고정되어 집계 노드 간 편차가 없어야 한다.
590. 주문 판정의 policy_version fence가 강제되어 롤아웃 중 혼합 정책 판정이 없어야 한다.
591. EOD 손익/잔고 이월 작업은 재실행에도 단일 결과로 수렴해 중복 이월이 없어야 한다.
592. 출금 승인 시점 whitelist/risk policy 스냅샷이 보존되어 사후 검증 재현성이 보장되어야 한다.
593. 계정 제한 상태는 replay/재기동 후 동일하게 복원되어 제한 우회 fail-open이 없어야 한다.
594. 감사 이벤트는 actor type/id/source를 필수 포함해 익명·불명확 주체 기록이 없어야 한다.
595. 동일 모드 전환 재시도에서도 승인/감사/상태가 단일 전이로 수렴해야 한다.
596. 2인 승인 quorum 계산은 중복 승인자/역할 충돌을 배제하고 일관된 승인판정을 보장해야 한다.
597. 증거 번들 legal-hold 상태/만료/예외가 추적되어 hold 미적용 종결이 없어야 한다.
598. 알람 룰 변경은 PR/승인/버전 provenance 없이는 운영 배포에 적용될 수 없어야 한다.
599. consumer rebalance 중 중복 처리율은 임계치를 넘지 않아야 하며 초과 시 자동 격리·재조정되어야 한다.
600. DR 승격 단계에서 source/target write freeze 검증 실패 시 승격이 중단되어야 한다.
601. 런타임 시크릿 접근범위는 최소권한 정책을 벗어나지 않아야 한다.
602. p99 초과 시 서비스/구간별 budget attribution 리포트가 자동 생성되어야 한다.
603. 규제 증거 산출물은 보존기간/삭제정책 위반 없이 유지되어 제출 완결성이 보장되어야 한다.
604. 사고 티켓-알람-커밋-배포 링크 무결성이 유지되어야 종결·승격이 가능해야 한다.
605. 복구 리허설은 격리 환경에서만 수행되어 운영 자원 오염 경로가 없어야 한다.
606. core/ledger 수집 지연 차이는 보정된 기준 시각으로 계산되어 lag 오탐이 없어야 한다.
607. kafka offset과 ledger applied_seq 매핑은 무결해야 하며 재처리 범위 누락/중복이 없어야 한다.
608. book/candle conflation key 규칙은 고정되어 인스턴스 간 latest-only 결과 편차가 없어야 한다.
609. trades replay range 응답은 연속 seq 완전성을 보장해 gap/중복 구간 반환이 없어야 한다.
610. 노출도 계산 decimal precision/rounding 규칙은 단일화되어 경계값 오판정이 없어야 한다.
611. EOD freeze/unfreeze 재시도에서도 상태는 단일 결과로 수렴해 이중전환이 없어야 한다.
612. 출금 승인 스냅샷과 실행시점 상태 drift가 검증되어 조건변경 출금이 차단되어야 한다.
613. 계정 제한 만료 스케줄러는 재기동/중복 실행에도 동일 시각·단일 전이로 동작해야 한다.
614. 감사 해시체인 세그먼트 앵커가 유지되어 구간 누락·재배열 변조가 없어야 한다.
615. 안전모드 자동 전환 deadband/hysteresis로 임계치 인접 구간 플래핑이 없어야 한다.
616. DR 승격 체크리스트는 증거/승인/완료상태 누락이 없어야만 승격 가능해야 한다.
617. 정책 변경 diff 영향요약·리스크 acknowledgement 없이는 승인 진행이 없어야 한다.
618. 운영 이벤트 스키마 레지스트리 변경은 승인된 lockfile/버전 해시와 일치해야 한다.
619. consumer commit 지연은 예산을 넘지 않아야 하며 초과 시 원인분해·격리가 자동 동작해야 한다.
620. DR 스냅샷 복제본은 source/destination checksum 동등성이 검증되어야만 사용 가능해야 한다.
621. 시크릿 접근 텔레메트리는 주체/빈도 기반 이상탐지를 지원해야 한다.
622. WS send queue 포화 예측 기반 선제 throttle/close 정책이 동작해야 한다.
623. 규제 일정 캘린더 파일은 서명/체크섬 무결성을 유지해야 한다.
624. 사고 증거 번들의 immutable 저장/검증 결과가 없으면 종결·재개 승인이 차단되어야 한다.
625. 백업 암호화 키 회전 주기 준수와 구키 폐기가 검증되어야 복구·배포 승인이 가능해야 한다.
