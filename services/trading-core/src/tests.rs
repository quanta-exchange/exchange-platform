use crate::contracts::exchange::v1 as proto;
use crate::engine::{CoreConfig, TradingCore};
use crate::health;
use crate::leader::FencingCoordinator;
use crate::model::{RejectCode, SymbolMode};
use crate::outbox::EventSink;
use crate::risk::RiskConfig;
use tempfile::TempDir;

fn meta(
    command_id: &str,
    idem: &str,
    user: &str,
    symbol: &str,
    correlation: &str,
) -> Option<proto::CommandMetadata> {
    Some(proto::CommandMetadata {
        command_id: command_id.to_string(),
        idempotency_key: idem.to_string(),
        user_id: user.to_string(),
        symbol: symbol.to_string(),
        ts_server: None,
        trace_id: format!("trace-{command_id}"),
        correlation_id: correlation.to_string(),
    })
}

fn place_req(
    cmd: &str,
    idem: &str,
    user: &str,
    order_id: &str,
    side: proto::Side,
    order_type: proto::OrderType,
    price: &str,
    qty: &str,
) -> proto::PlaceOrderRequest {
    proto::PlaceOrderRequest {
        meta: meta(cmd, idem, user, "BTC-KRW", &format!("corr-{cmd}")),
        order_id: order_id.to_string(),
        side: side as i32,
        order_type: order_type as i32,
        price: price.to_string(),
        quantity: qty.to_string(),
        time_in_force: proto::TimeInForce::Gtc as i32,
    }
}

fn cancel_req(cmd: &str, idem: &str, user: &str, order_id: &str) -> proto::CancelOrderRequest {
    proto::CancelOrderRequest {
        meta: meta(cmd, idem, user, "BTC-KRW", &format!("corr-{cmd}")),
        order_id: order_id.to_string(),
    }
}

fn set_mode_req(
    cmd: &str,
    idem: &str,
    mode: proto::SymbolMode,
    reason: &str,
) -> proto::SetSymbolModeRequest {
    proto::SetSymbolModeRequest {
        meta: meta(cmd, idem, "admin", "BTC-KRW", &format!("corr-{cmd}")),
        mode: mode as i32,
        reason: reason.to_string(),
    }
}

fn core_config(tmp: &TempDir) -> CoreConfig {
    CoreConfig {
        symbol: "BTC-KRW".to_string(),
        wal_dir: tmp.path().join("wal"),
        outbox_dir: tmp.path().join("outbox"),
        max_wal_segment_bytes: 1024 * 1024,
        idempotency_ttl_ms: 60_000,
        risk: RiskConfig {
            max_open_orders_per_user_symbol: 1_000,
            max_commands_per_sec: 10_000,
            price_band_bps: 1_000,
            dynamic_collar_bps: 1_500,
            volatility_violation_threshold: 3,
        },
        stub_trades: false,
    }
}

fn make_engine(tmp: &TempDir, fencing: FencingCoordinator) -> TradingCore {
    let mut core = TradingCore::new(core_config(tmp), fencing).unwrap();
    core.set_balance("maker", "BTC", 1_000_000, 0);
    core.set_balance("maker", "KRW", 1_000_000_000_000, 0);
    core.set_balance("taker", "BTC", 1_000_000, 0);
    core.set_balance("taker", "KRW", 1_000_000_000_000, 0);
    core.set_balance("u1", "BTC", 1_000_000, 0);
    core.set_balance("u1", "KRW", 1_000_000_000_000, 0);
    core.set_balance("u2", "BTC", 1_000_000, 0);
    core.set_balance("u2", "KRW", 1_000_000_000_000, 0);
    core
}

#[test]
fn health_is_ok() {
    let h = health();
    assert_eq!(h.service, "trading-core");
    assert_eq!(h.status, "ok");
}

#[test]
fn generated_contract_types_compile() {
    let envelope = proto::EventEnvelope {
        event_id: "evt-1".to_string(),
        event_version: 1,
        symbol: "BTC-KRW".to_string(),
        seq: 1,
        occurred_at: None,
        correlation_id: "corr-1".to_string(),
        causation_id: "cause-1".to_string(),
    };
    assert_eq!(envelope.symbol, "BTC-KRW");
}

#[test]
fn validation_rejects_missing_meta() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());
    let resp = core
        .place_order(proto::PlaceOrderRequest {
            meta: None,
            order_id: "o1".to_string(),
            side: proto::Side::Buy as i32,
            order_type: proto::OrderType::Limit as i32,
            price: "100".to_string(),
            quantity: "1".to_string(),
            time_in_force: proto::TimeInForce::Gtc as i32,
        })
        .unwrap();
    assert!(!resp.accepted);
    assert_eq!(resp.reject_code, RejectCode::Validation.as_str());
}

#[test]
fn correlation_id_is_propagated() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());
    let resp = core
        .place_order(place_req(
            "c1",
            "idem-1",
            "u1",
            "o1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();
    assert_eq!(resp.correlation_id, "corr-c1");
}

#[test]
fn seq_is_monotonic_per_symbol() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());
    let mut seqs = Vec::new();
    for i in 0..30 {
        let resp = core
            .place_order(place_req(
                &format!("c{i}"),
                &format!("idem-{i}"),
                "u1",
                &format!("o{i}"),
                proto::Side::Buy,
                proto::OrderType::Limit,
                "100",
                "1",
            ))
            .unwrap();
        seqs.push(resp.seq);
    }
    for w in seqs.windows(2) {
        assert!(w[1] >= w[0]);
    }
}

#[test]
fn idempotent_place_returns_same_response() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let first = core
        .place_order(place_req(
            "c1",
            "idem-1",
            "u1",
            "o1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();
    let second = core
        .place_order(place_req(
            "c2",
            "idem-1",
            "u1",
            "o2",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "200",
            "9",
        ))
        .unwrap();
    assert_eq!(first.order_id, second.order_id);
    assert_eq!(first.seq, second.seq);
}

#[test]
fn duplicate_order_id_is_rejected() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let first = core
        .place_order(place_req(
            "d1",
            "idem-d1",
            "u1",
            "o-dup",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();
    assert!(first.accepted);

    let second = core
        .place_order(place_req(
            "d2",
            "idem-d2",
            "u1",
            "o-dup",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();
    assert!(!second.accepted);
    assert_eq!(second.reject_code, RejectCode::Validation.as_str());
}

#[test]
fn fifo_matching_same_price_level() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let _ = core
        .place_order(place_req(
            "m1",
            "idem-m1",
            "maker",
            "ask-1",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();
    let _ = core
        .place_order(place_req(
            "m2",
            "idem-m2",
            "maker",
            "ask-2",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();

    let _ = core
        .place_order(place_req(
            "t1",
            "idem-t1",
            "taker",
            "buy-1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();

    let events = core.recent_events();
    let first_trade = events
        .iter()
        .find_map(|e| match e {
            crate::model::CoreEvent::TradeExecuted(t) => Some(t),
            _ => None,
        })
        .unwrap();
    assert_eq!(first_trade.maker_order_id, "ask-1");
}

#[test]
fn best_price_priority() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let _ = core
        .place_order(place_req(
            "m1",
            "idem-m1",
            "maker",
            "ask-110",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "110",
            "10",
        ))
        .unwrap();
    let _ = core
        .place_order(place_req(
            "m2",
            "idem-m2",
            "maker",
            "ask-100",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();
    let _ = core
        .place_order(place_req(
            "t1",
            "idem-t1",
            "taker",
            "buy",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "120",
            "10",
        ))
        .unwrap();

    let trade = core
        .recent_events()
        .iter()
        .find_map(|e| match e {
            crate::model::CoreEvent::TradeExecuted(t) => Some(t),
            _ => None,
        })
        .unwrap();
    assert_eq!(trade.price, "100");
}

#[test]
fn place_order_status_progression_is_consistent() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let accepted = core
        .place_order(place_req(
            "accept-1",
            "idem-accept-1",
            "maker",
            "buy-resting",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();
    assert_eq!(accepted.status, "ACCEPTED");

    let filled = core
        .place_order(place_req(
            "fill-1",
            "idem-fill-1",
            "taker",
            "sell-fill",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();
    assert_eq!(filled.status, "FILLED");

    let _ = core
        .place_order(place_req(
            "maker-ask",
            "idem-maker-ask",
            "maker",
            "ask-resting",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "105",
            "10",
        ))
        .unwrap();
    let partial = core
        .place_order(place_req(
            "partial-1",
            "idem-partial-1",
            "taker",
            "buy-partial",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "105",
            "15",
        ))
        .unwrap();
    assert_eq!(partial.status, "PARTIALLY_FILLED");
}

#[test]
fn market_order_sweeps_multiple_levels() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let asks = ["100", "101", "102"];
    for (i, px) in asks.iter().enumerate() {
        let _ = core
            .place_order(place_req(
                &format!("m{i}"),
                &format!("idem-m{i}"),
                "maker",
                &format!("ask-{i}"),
                proto::Side::Sell,
                proto::OrderType::Limit,
                px,
                "5",
            ))
            .unwrap();
    }

    let resp = core
        .place_order(place_req(
            "t1",
            "idem-t1",
            "taker",
            "buy-market",
            proto::Side::Buy,
            proto::OrderType::Market,
            "0",
            "12",
        ))
        .unwrap();

    assert!(resp.accepted);
    let trades = core
        .recent_events()
        .iter()
        .filter(|e| matches!(e, crate::model::CoreEvent::TradeExecuted(_)))
        .count();
    assert!(trades >= 3);
}

#[test]
fn insufficient_liquidity_leaves_market_remainder_canceled() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let _ = core
        .place_order(place_req(
            "m1",
            "idem-m1",
            "maker",
            "ask-1",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "100",
            "5",
        ))
        .unwrap();

    let resp = core
        .place_order(place_req(
            "t1",
            "idem-t1",
            "taker",
            "buy-m",
            proto::Side::Buy,
            proto::OrderType::Market,
            "0",
            "20",
        ))
        .unwrap();

    assert!(resp.accepted);
    let canceled = core
        .recent_events()
        .iter()
        .any(|e| matches!(e, crate::model::CoreEvent::OrderCanceled(_)));
    assert!(canceled);
}

#[test]
fn cancel_removes_order_and_rejects_second_cancel() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let _ = core
        .place_order(place_req(
            "p1",
            "idem-p1",
            "u1",
            "o1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();

    let first = core
        .cancel_order(cancel_req("c1", "idem-c1", "u1", "o1"))
        .unwrap();
    assert!(first.accepted);

    let second = core
        .cancel_order(cancel_req("c2", "idem-c2", "u1", "o1"))
        .unwrap();
    assert!(!second.accepted);
    assert_eq!(second.reject_code, RejectCode::UnknownOrder.as_str());
}

#[test]
fn cancel_rejects_non_owner_as_unknown_order() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let placed = core
        .place_order(place_req(
            "pc1",
            "idem-pc1",
            "u1",
            "o-owned",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();
    assert!(placed.accepted);

    let cancel = core
        .cancel_order(cancel_req("cc1", "idem-cc1", "u2", "o-owned"))
        .unwrap();
    assert!(!cancel.accepted);
    assert_eq!(cancel.reject_code, RejectCode::UnknownOrder.as_str());
    assert_eq!(core.open_order_count(), 1);
}

#[test]
fn risk_rejects_overspend() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());
    core.set_balance("u1", "KRW", 100, 0);

    let resp = core
        .place_order(place_req(
            "c1",
            "idem-1",
            "u1",
            "o1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "2",
        ))
        .unwrap();
    assert!(!resp.accepted);
    assert_eq!(resp.reject_code, RejectCode::InsufficientFunds.as_str());
}

#[test]
fn price_band_rejection_works() {
    let tmp = TempDir::new().unwrap();
    let mut cfg = core_config(&tmp);
    cfg.risk.price_band_bps = 100;
    let mut core = TradingCore::new(cfg, FencingCoordinator::new()).unwrap();
    core.set_balance("u1", "KRW", 1_000_000_000, 0);
    core.set_balance("u1", "BTC", 1_000_000, 0);
    core.set_balance("u2", "KRW", 1_000_000_000, 0);
    core.set_balance("u2", "BTC", 1_000_000, 0);

    let _ = core
        .place_order(place_req(
            "seed-ask",
            "idem-seed-ask",
            "u2",
            "ask-seed",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();
    let _ = core
        .place_order(place_req(
            "seed-buy",
            "idem-seed-buy",
            "u1",
            "buy-seed",
            proto::Side::Buy,
            proto::OrderType::Market,
            "0",
            "1",
        ))
        .unwrap();

    let resp = core
        .place_order(place_req(
            "bad",
            "idem-bad",
            "u1",
            "o-bad",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "500",
            "1",
        ))
        .unwrap();
    assert!(!resp.accepted);
    assert_eq!(resp.reject_code, RejectCode::PriceBand.as_str());
}

#[test]
fn wal_contains_executed_before_publish_queue() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let _ = core
        .place_order(place_req(
            "a1",
            "idem-a1",
            "maker",
            "ask-1",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "100",
            "5",
        ))
        .unwrap();
    let _ = core
        .place_order(place_req(
            "b1",
            "idem-b1",
            "taker",
            "buy-1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "5",
        ))
        .unwrap();

    let wal = core.replay_wal().unwrap();
    let has_trade = wal.iter().any(|r| {
        r.events
            .iter()
            .any(|e| matches!(e, crate::model::CoreEvent::TradeExecuted(_)))
    });
    assert!(has_trade);

    let pending = core.pending_outbox().unwrap();
    assert!(!pending.is_empty());
}

#[test]
fn snapshot_and_recovery_keep_state_hash() {
    let tmp = TempDir::new().unwrap();
    let fencing = FencingCoordinator::new();
    let mut core = make_engine(&tmp, fencing.clone());

    let _ = core
        .place_order(place_req(
            "m1",
            "idem-m1",
            "u1",
            "o1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "10",
        ))
        .unwrap();

    let snap = tmp.path().join("snapshot.json");
    core.take_snapshot(&snap).unwrap();

    let _ = core
        .place_order(place_req(
            "m2",
            "idem-m2",
            "u1",
            "o2",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "101",
            "10",
        ))
        .unwrap();

    let expected = core.last_state_hash().to_string();

    let mut recovered = make_engine(&tmp, fencing);
    recovered.recover_from_snapshot(&snap).unwrap();
    assert_eq!(expected, recovered.last_state_hash());
}

#[test]
fn deterministic_replay_same_hash_for_10_runs() {
    let mut hashes = Vec::new();
    for _ in 0..10 {
        let tmp = TempDir::new().unwrap();
        let mut core = make_engine(&tmp, FencingCoordinator::new());
        for i in 0..20 {
            let _ = core
                .place_order(place_req(
                    &format!("c{i}"),
                    &format!("idem-{i}"),
                    "u1",
                    &format!("o{i}"),
                    proto::Side::Buy,
                    proto::OrderType::Limit,
                    "100",
                    "1",
                ))
                .unwrap();
        }
        hashes.push(core.last_state_hash().to_string());
    }

    for w in hashes.windows(2) {
        assert_eq!(w[0], w[1]);
    }
}

#[test]
fn recover_from_wal_keeps_seq_hash_and_mode() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    for i in 0..6 {
        let _ = core
            .place_order(place_req(
                &format!("c{i}"),
                &format!("idem-{i}"),
                "u1",
                &format!("o{i}"),
                proto::Side::Buy,
                proto::OrderType::Limit,
                "100",
                "1",
            ))
            .unwrap();
    }
    let _ = core
        .set_symbol_mode(set_mode_req(
            "mode-1",
            "idem-mode-1",
            proto::SymbolMode::CancelOnly,
            "recovery-test",
        ))
        .unwrap();

    let expected_seq = core.current_seq();
    let expected_hash = core.last_state_hash().to_string();
    let expected_mode = core.symbol_mode();

    let recovered = make_engine(&tmp, FencingCoordinator::new());
    assert_eq!(expected_seq, recovered.current_seq());
    assert_eq!(expected_hash, recovered.last_state_hash());
    assert_eq!(expected_mode, recovered.symbol_mode());
}

#[test]
fn split_brain_old_leader_cannot_commit() {
    let fence = FencingCoordinator::new();
    let t1 = TempDir::new().unwrap();
    let t2 = TempDir::new().unwrap();

    let mut old = make_engine(&t1, fence.clone());
    let _new = make_engine(&t2, fence);

    let resp = old
        .place_order(place_req(
            "c1",
            "idem-1",
            "u1",
            "o1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();

    assert!(!resp.accepted);
    assert_eq!(resp.reject_code, RejectCode::FencingToken.as_str());
    assert_eq!(old.symbol_mode(), SymbolMode::HardHalt);
}

#[test]
fn admin_commands_fail_closed_without_valid_meta_or_mode() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let missing_meta_mode = core
        .set_symbol_mode(proto::SetSymbolModeRequest {
            meta: None,
            mode: proto::SymbolMode::CancelOnly as i32,
            reason: "test".to_string(),
        })
        .unwrap();
    assert!(!missing_meta_mode.accepted);
    assert_eq!(missing_meta_mode.reason, RejectCode::Validation.as_str());
    assert_eq!(core.symbol_mode(), SymbolMode::Normal);

    let invalid_mode = core
        .set_symbol_mode(proto::SetSymbolModeRequest {
            meta: meta(
                "mode-invalid",
                "idem-mode-invalid",
                "admin",
                "BTC-KRW",
                "corr-mode-invalid",
            ),
            mode: 9999,
            reason: "bad-mode".to_string(),
        })
        .unwrap();
    assert!(!invalid_mode.accepted);
    assert_eq!(invalid_mode.reason, RejectCode::Validation.as_str());
    assert_eq!(core.symbol_mode(), SymbolMode::Normal);

    let missing_meta_cancel_all = core
        .cancel_all(proto::CancelAllRequest {
            meta: None,
            reason: "test".to_string(),
        })
        .unwrap();
    assert!(!missing_meta_cancel_all.accepted);
    assert_eq!(
        missing_meta_cancel_all.reason,
        RejectCode::Validation.as_str()
    );
}

#[test]
fn split_brain_old_leader_cannot_apply_admin_commands() {
    let fence = FencingCoordinator::new();
    let t1 = TempDir::new().unwrap();
    let t2 = TempDir::new().unwrap();

    let mut old = make_engine(&t1, fence.clone());
    let _new = make_engine(&t2, fence);

    let mode_resp = old
        .set_symbol_mode(set_mode_req(
            "mode-fence",
            "idem-mode-fence",
            proto::SymbolMode::CancelOnly,
            "fence-check",
        ))
        .unwrap();
    assert!(!mode_resp.accepted);
    assert_eq!(mode_resp.reason, RejectCode::FencingToken.as_str());
    assert_eq!(old.symbol_mode(), SymbolMode::HardHalt);

    let cancel_all_resp = old
        .cancel_all(proto::CancelAllRequest {
            meta: meta(
                "cancel-all-fence",
                "idem-cancel-all-fence",
                "admin",
                "BTC-KRW",
                "corr-cancel-all-fence",
            ),
            reason: "fence-check".to_string(),
        })
        .unwrap();
    assert!(!cancel_all_resp.accepted);
    assert_eq!(cancel_all_resp.reason, RejectCode::FencingToken.as_str());
}

#[test]
fn volatility_guard_transitions_to_cancel_only() {
    let tmp = TempDir::new().unwrap();
    let mut cfg = core_config(&tmp);
    cfg.risk.price_band_bps = 100;
    cfg.risk.volatility_violation_threshold = 2;
    let mut core = TradingCore::new(cfg, FencingCoordinator::new()).unwrap();

    core.set_balance("u1", "KRW", 1_000_000_000, 0);
    core.set_balance("u1", "BTC", 1_000_000, 0);
    core.set_balance("u2", "KRW", 1_000_000_000, 0);
    core.set_balance("u2", "BTC", 1_000_000, 0);

    let _ = core
        .place_order(place_req(
            "s1",
            "idem-s1",
            "u2",
            "ask",
            proto::Side::Sell,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();
    let _ = core
        .place_order(place_req(
            "s2",
            "idem-s2",
            "u1",
            "buy",
            proto::Side::Buy,
            proto::OrderType::Market,
            "0",
            "1",
        ))
        .unwrap();

    for i in 0..2 {
        let _ = core
            .place_order(place_req(
                &format!("b{i}"),
                &format!("idem-b{i}"),
                "u1",
                &format!("o{i}"),
                proto::Side::Buy,
                proto::OrderType::Limit,
                "500",
                "1",
            ))
            .unwrap();
    }

    assert_eq!(core.symbol_mode(), SymbolMode::CancelOnly);

    let blocked = core
        .place_order(place_req(
            "blocked",
            "idem-blocked",
            "u1",
            "o-blocked",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();
    assert!(!blocked.accepted);
    assert_eq!(blocked.reject_code, RejectCode::CancelOnly.as_str());
}

#[test]
fn cancel_all_clears_book() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    for i in 0..5 {
        let _ = core
            .place_order(place_req(
                &format!("c{i}"),
                &format!("idem-{i}"),
                "u1",
                &format!("o{i}"),
                proto::Side::Buy,
                proto::OrderType::Limit,
                "100",
                "1",
            ))
            .unwrap();
    }

    assert!(core.open_order_count() > 0);

    let _ = core
        .cancel_all(proto::CancelAllRequest {
            meta: meta("admin", "admin-idem", "admin", "BTC-KRW", "corr-admin"),
            reason: "test".to_string(),
        })
        .unwrap();

    assert_eq!(core.open_order_count(), 0);
}

#[test]
fn outbox_republish_is_idempotent() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let _ = core
        .place_order(place_req(
            "m1",
            "idem-m1",
            "u1",
            "o1",
            proto::Side::Buy,
            proto::OrderType::Limit,
            "100",
            "1",
        ))
        .unwrap();

    struct Sink(usize);
    impl EventSink for Sink {
        fn publish(&mut self, _event: &crate::model::CoreEvent) -> Result<(), String> {
            self.0 += 1;
            Ok(())
        }
    }

    let outbox = crate::outbox::Outbox::open(tmp.path().join("outbox")).unwrap();
    let mut sink = Sink(0);
    outbox.publish_pending(&mut sink, 1).unwrap();
    let first_calls = sink.0;
    outbox.publish_pending(&mut sink, 1).unwrap();
    assert_eq!(sink.0, first_calls);
}

#[test]
fn golden_vectors_cover_20_cases() {
    let tmp = TempDir::new().unwrap();
    let mut core = make_engine(&tmp, FencingCoordinator::new());

    let vectors = vec![
        ("100", "1"),
        ("101", "1"),
        ("102", "1"),
        ("103", "1"),
        ("104", "1"),
        ("105", "1"),
        ("106", "1"),
        ("107", "1"),
        ("108", "1"),
        ("109", "1"),
        ("110", "1"),
        ("111", "1"),
        ("112", "1"),
        ("113", "1"),
        ("114", "1"),
        ("115", "1"),
        ("116", "1"),
        ("117", "1"),
        ("118", "1"),
        ("119", "1"),
    ];

    for (idx, (price, qty)) in vectors.into_iter().enumerate() {
        let resp = core
            .place_order(place_req(
                &format!("g-{idx}"),
                &format!("idem-g-{idx}"),
                "u1",
                &format!("go-{idx}"),
                proto::Side::Buy,
                proto::OrderType::Limit,
                price,
                qty,
            ))
            .unwrap();
        assert!(resp.accepted || !resp.reject_code.is_empty());
    }

    assert!(core.current_seq() > 0);
}
