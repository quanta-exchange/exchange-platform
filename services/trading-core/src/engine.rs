use crate::contracts::exchange::v1 as proto;
use crate::determinism::state_hash;
use crate::leader::FencingCoordinator;
use crate::model::{
    build_envelope, from_proto_meta, now_timestamp, parse_u64, split_symbol, to_order_type,
    to_side, to_symbol_mode, to_time_in_force, CancelRejectedEvent, CommandMeta, CoreEvent,
    EngineCheckpointEvent, EventEnvelope, Order, OrderAcceptedEvent, OrderCanceledEvent,
    OrderRejectedEvent, OrderType, RejectCode, Side, SymbolMode, TimeInForce, TradeExecutedEvent,
};
use crate::orderbook::OrderBook;
use crate::outbox::{Outbox, OutboxRecord};
use crate::risk::{RiskConfig, RiskManager};
use crate::snapshot::Snapshot;
use crate::wal::{Wal, WalError, WalRecord};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("wal: {0}")]
    Wal(#[from] WalError),
    #[error("outbox: {0}")]
    Outbox(#[from] crate::outbox::OutboxError),
    #[error("snapshot: {0}")]
    Snapshot(#[from] crate::snapshot::SnapshotError),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoreConfig {
    pub symbol: String,
    pub wal_dir: PathBuf,
    pub outbox_dir: PathBuf,
    pub max_wal_segment_bytes: u64,
    pub idempotency_ttl_ms: i64,
    pub risk: RiskConfig,
    pub stub_trades: bool,
}

impl Default for CoreConfig {
    fn default() -> Self {
        Self {
            symbol: "BTC-KRW".to_string(),
            wal_dir: PathBuf::from("/tmp/trading-core/wal"),
            outbox_dir: PathBuf::from("/tmp/trading-core/outbox"),
            max_wal_segment_bytes: 8 * 1024 * 1024,
            idempotency_ttl_ms: 5 * 60 * 1000,
            risk: RiskConfig::default(),
            stub_trades: false,
        }
    }
}

#[derive(Debug, Clone)]
enum IdempotentResponse {
    Place(proto::PlaceOrderResponse),
    Cancel(proto::CancelOrderResponse),
}

#[derive(Debug, Clone)]
struct IdempotencyEntry {
    created_at_ms: i64,
    response: IdempotentResponse,
}

#[derive(Debug)]
pub struct TradingCore {
    cfg: CoreConfig,
    seq: u64,
    symbol_mode: SymbolMode,
    ref_price: Option<u64>,
    order_book: OrderBook,
    risk: RiskManager,
    wal: Wal,
    outbox: Outbox,
    fencing: FencingCoordinator,
    leader_token: u64,
    idempotency: HashMap<(String, String), IdempotencyEntry>,
    seen_order_ids: HashSet<String>,
    last_state_hash: String,
    recent_events: Vec<CoreEvent>,
    mode_transitions: Vec<String>,
}

impl TradingCore {
    pub fn new(cfg: CoreConfig, fencing: FencingCoordinator) -> Result<Self, EngineError> {
        let wal = Wal::open(&cfg.wal_dir, cfg.max_wal_segment_bytes)?;
        let outbox = Outbox::open(&cfg.outbox_dir)?;
        let leader_token = fencing.acquire();

        let mut core = Self {
            cfg: cfg.clone(),
            seq: 0,
            symbol_mode: SymbolMode::Normal,
            ref_price: None,
            order_book: OrderBook::default(),
            risk: RiskManager::new(cfg.risk),
            wal,
            outbox,
            fencing,
            leader_token,
            idempotency: HashMap::new(),
            seen_order_ids: HashSet::new(),
            last_state_hash: String::new(),
            recent_events: Vec::new(),
            mode_transitions: Vec::new(),
        };
        core.recover_from_wal()?;
        Ok(core)
    }

    pub fn set_balance(&mut self, user: &str, currency: &str, available: i128, hold: i128) {
        self.risk.set_balance(user, currency, available, hold);
    }

    pub fn acquire_leadership(&mut self) {
        self.leader_token = self.fencing.acquire();
    }

    pub fn symbol_mode(&self) -> SymbolMode {
        self.symbol_mode
    }

    pub fn last_state_hash(&self) -> &str {
        &self.last_state_hash
    }

    pub fn mode_transitions(&self) -> &[String] {
        &self.mode_transitions
    }

    pub fn recent_events(&self) -> &[CoreEvent] {
        &self.recent_events
    }

    pub fn current_seq(&self) -> u64 {
        self.seq
    }

    pub fn open_order_count(&self) -> usize {
        self.order_book.open_orders()
    }

    pub fn replay_wal(&self) -> Result<Vec<WalRecord>, EngineError> {
        Ok(self.wal.replay_all()?)
    }

    pub fn pending_outbox(&self) -> Result<Vec<OutboxRecord>, EngineError> {
        Ok(self.outbox.pending_records()?)
    }

    pub fn publish_pending<S: crate::outbox::EventSink>(
        &self,
        sink: &mut S,
        retries: usize,
    ) -> Result<(), EngineError> {
        self.outbox.publish_pending(sink, retries)?;
        Ok(())
    }

    pub fn take_snapshot<P: AsRef<Path>>(&self, path: P) -> Result<(), EngineError> {
        Snapshot {
            last_seq: self.seq,
            state_hash: self.last_state_hash.clone(),
            symbol_mode: self.symbol_mode,
            order_book: self.order_book.clone(),
            risk: self.risk.to_snapshot(),
        }
        .save(path)?;
        Ok(())
    }

    pub fn recover_from_snapshot<P: AsRef<Path>>(&mut self, path: P) -> Result<(), EngineError> {
        let snapshot = Snapshot::load(path)?;
        self.seq = snapshot.last_seq;
        self.last_state_hash = snapshot.state_hash;
        self.symbol_mode = snapshot.symbol_mode;
        self.order_book = snapshot.order_book;
        self.risk = RiskManager::from_snapshot(self.cfg.risk.clone(), snapshot.risk);

        let tail = self.wal.replay_from_seq(self.seq + 1)?;
        for record in tail {
            for event in record.events {
                self.apply_replay_event(&event);
            }
            self.seq = record.seq.max(self.seq);
            self.last_state_hash = record.state_hash;
            if let Some(mode) = record.symbol_mode {
                self.symbol_mode = mode;
            }
        }
        Ok(())
    }

    pub fn recover_from_wal(&mut self) -> Result<(), EngineError> {
        let records = self.wal.replay_all()?;
        if records.is_empty() {
            return Ok(());
        }

        self.seq = 0;
        self.symbol_mode = SymbolMode::Normal;
        self.ref_price = None;
        self.order_book = OrderBook::default();
        self.risk = RiskManager::new(self.cfg.risk.clone());
        self.recent_events.clear();
        self.mode_transitions.clear();
        self.idempotency.clear();
        self.seen_order_ids.clear();

        for record in records {
            for event in &record.events {
                self.apply_replay_event(event);
            }
            self.seq = self.seq.max(record.seq);
            self.last_state_hash = record.state_hash;
            if let Some(mode) = record.symbol_mode {
                self.symbol_mode = mode;
            }
        }
        Ok(())
    }

    pub fn replay_hashes(&self) -> Result<Vec<String>, EngineError> {
        let mut hashes = Vec::new();
        for record in self.wal.replay_all()? {
            hashes.push(record.state_hash);
        }
        Ok(hashes)
    }

    pub fn place_order(
        &mut self,
        req: proto::PlaceOrderRequest,
    ) -> Result<proto::PlaceOrderResponse, EngineError> {
        let meta = match from_proto_meta(&req.meta) {
            Ok(v) => v,
            Err(code) => return Ok(self.make_place_reject_response(&req.order_id, "", code)),
        };

        if !self.is_leader_valid() {
            self.symbol_mode = SymbolMode::HardHalt;
            let resp = self.make_place_reject_response(
                &req.order_id,
                &meta.correlation_id,
                RejectCode::FencingToken,
            );
            self.store_idempotent_place(&meta, &resp);
            return Ok(resp);
        }

        if meta.symbol != self.cfg.symbol {
            let resp = self.make_place_reject_response(
                &req.order_id,
                &meta.correlation_id,
                RejectCode::Validation,
            );
            self.store_idempotent_place(&meta, &resp);
            return Ok(resp);
        }

        self.prune_idempotency();
        if let Some(idem) = self
            .idempotency
            .get(&(meta.symbol.clone(), meta.idempotency_key.clone()))
        {
            if let IdempotentResponse::Place(existing) = &idem.response {
                return Ok(existing.clone());
            }
        }

        if self.order_book.get_order(&req.order_id).is_some()
            || self.seen_order_ids.contains(&req.order_id)
        {
            let reject_order = Order {
                order_id: req.order_id.clone(),
                user_id: meta.user_id.clone(),
                symbol: meta.symbol.clone(),
                side: Side::Buy,
                order_type: OrderType::Limit,
                tif: TimeInForce::Gtc,
                price: None,
                original_qty: 0,
                remaining_qty: 0,
                accepted_seq: 0,
            };
            let mut events = vec![self.event_order_rejected(
                &reject_order,
                &meta,
                RejectCode::Validation,
                "duplicate_order_id",
            )];
            self.append_checkpoint(&meta, &mut events);
            self.persist_command(&meta.command_id, events)?;
            let resp = self.make_place_reject_response(
                &req.order_id,
                &meta.correlation_id,
                RejectCode::Validation,
            );
            self.store_idempotent_place(&meta, &resp);
            return Ok(resp);
        }

        let side = match to_side(req.side) {
            Ok(v) => v,
            Err(code) => {
                let resp =
                    self.make_place_reject_response(&req.order_id, &meta.correlation_id, code);
                self.store_idempotent_place(&meta, &resp);
                return Ok(resp);
            }
        };
        let order_type = match to_order_type(req.order_type) {
            Ok(v) => v,
            Err(code) => {
                let resp =
                    self.make_place_reject_response(&req.order_id, &meta.correlation_id, code);
                self.store_idempotent_place(&meta, &resp);
                return Ok(resp);
            }
        };
        let tif = match to_time_in_force(req.time_in_force) {
            Ok(v) => v,
            Err(code) => {
                let resp =
                    self.make_place_reject_response(&req.order_id, &meta.correlation_id, code);
                self.store_idempotent_place(&meta, &resp);
                return Ok(resp);
            }
        };
        let qty = match parse_u64(&req.quantity) {
            Ok(v) if v > 0 => v,
            _ => {
                let resp = self.make_place_reject_response(
                    &req.order_id,
                    &meta.correlation_id,
                    RejectCode::Validation,
                );
                self.store_idempotent_place(&meta, &resp);
                return Ok(resp);
            }
        };
        let price = if order_type == OrderType::Limit {
            match parse_u64(&req.price) {
                Ok(v) if v > 0 => Some(v),
                _ => {
                    let resp = self.make_place_reject_response(
                        &req.order_id,
                        &meta.correlation_id,
                        RejectCode::Validation,
                    );
                    self.store_idempotent_place(&meta, &resp);
                    return Ok(resp);
                }
            }
        } else {
            None
        };

        let mut order = Order {
            order_id: req.order_id.clone(),
            user_id: meta.user_id.clone(),
            symbol: meta.symbol.clone(),
            side,
            order_type,
            tif,
            price,
            original_qty: qty,
            remaining_qty: qty,
            accepted_seq: 0,
        };

        // G1 minimal path: seed deterministic demo balances for unseen users.
        self.bootstrap_user_balances(&meta.user_id);

        let reserve_ref = match order.order_type {
            OrderType::Market => self
                .ref_price
                .or_else(|| self.order_book.best_opposite(order.side)),
            OrderType::Limit => self.ref_price,
        };
        if let Err(code) =
            self.risk
                .validate_and_reserve(&order, reserve_ref, self.symbol_mode, &self.cfg.symbol)
        {
            if self.risk.volatility_violations >= self.risk.cfg.volatility_violation_threshold {
                self.transition_mode(SymbolMode::CancelOnly, "auto-volatility-guard");
            }
            let mut events =
                vec![self.event_order_rejected(&order, &meta, code.clone(), "risk reject")];
            self.append_checkpoint(&meta, &mut events);
            self.persist_command(&meta.command_id, events)?;
            let resp = self.make_place_reject_response(&req.order_id, &meta.correlation_id, code);
            self.store_idempotent_place(&meta, &resp);
            return Ok(resp);
        }

        if self.risk.volatility_violations >= self.risk.cfg.volatility_violation_threshold {
            self.transition_mode(SymbolMode::CancelOnly, "auto-volatility-guard");
        }

        order.accepted_seq = self.next_seq();
        let mut events = vec![self.event_order_accepted(&order, &meta)];

        let fills = self.order_book.match_order(&mut order);
        let had_fill = !fills.is_empty();
        for (idx, fill) in fills.into_iter().enumerate() {
            let maker_side = opposite(order.side);
            let (buyer_user_id, seller_user_id) = match order.side {
                Side::Buy => (order.user_id.clone(), fill.maker_user_id.clone()),
                Side::Sell => (fill.maker_user_id.clone(), order.user_id.clone()),
            };

            let quote_amount = fill.price.saturating_mul(fill.quantity);
            self.risk.on_trade(
                &buyer_user_id,
                &seller_user_id,
                &self.cfg.symbol,
                fill.price,
                fill.quantity,
            );

            let taker_consumed = match order.side {
                Side::Buy => i128::from(quote_amount),
                Side::Sell => i128::from(fill.quantity),
            };
            self.risk
                .settle_reservation_consumed(&order, taker_consumed);

            let maker_order = Order {
                order_id: fill.maker_order_id.clone(),
                user_id: fill.maker_user_id.clone(),
                symbol: self.cfg.symbol.clone(),
                side: maker_side,
                order_type: OrderType::Limit,
                tif: TimeInForce::Gtc,
                price: Some(fill.price),
                original_qty: fill.quantity,
                remaining_qty: fill.maker_remaining_after,
                accepted_seq: 0,
            };
            let maker_consumed = match maker_side {
                Side::Buy => i128::from(quote_amount),
                Side::Sell => i128::from(fill.quantity),
            };
            self.risk
                .settle_reservation_consumed(&maker_order, maker_consumed);
            if fill.maker_remaining_after == 0 {
                self.risk.release_reservation(&maker_order);
            }

            self.ref_price = Some(fill.price);
            events.push(self.event_trade_executed(
                &meta,
                &fill.maker_order_id,
                &order.order_id,
                &buyer_user_id,
                &seller_user_id,
                fill.price,
                fill.quantity,
                idx as u64,
            ));
        }

        let stub_trade = self.cfg.stub_trades
            && events
                .iter()
                .all(|e| !matches!(e, CoreEvent::TradeExecuted(_)));
        if stub_trade {
            let price = order.price.unwrap_or(1);
            let quantity = order.remaining_qty.max(1);
            let (buyer_user_id, seller_user_id) = match order.side {
                Side::Buy => (order.user_id.clone(), "stub-mm".to_string()),
                Side::Sell => ("stub-mm".to_string(), order.user_id.clone()),
            };
            order.remaining_qty = 0;
            events.push(self.event_trade_executed(
                &meta,
                "stub-maker",
                &order.order_id,
                &buyer_user_id,
                &seller_user_id,
                price,
                quantity,
                0,
            ));
            self.risk.on_trade(
                &buyer_user_id,
                &seller_user_id,
                &self.cfg.symbol,
                price,
                quantity,
            );
            let consumed = match order.side {
                Side::Buy => i128::from(price.saturating_mul(quantity)),
                Side::Sell => i128::from(quantity),
            };
            self.risk.settle_reservation_consumed(&order, consumed);
        }

        if order.remaining_qty > 0 {
            let can_rest = order.order_type == OrderType::Limit && order.tif == TimeInForce::Gtc;
            if can_rest {
                self.order_book.insert(order.clone());
            } else {
                events.push(self.event_order_canceled(&order, &meta));
                self.risk.release_reservation(&order);
            }
        } else {
            if !stub_trade {
                self.risk.release_reservation(&order);
            }
        }

        let status = if order.remaining_qty == 0 {
            "FILLED".to_string()
        } else if had_fill {
            "PARTIALLY_FILLED".to_string()
        } else if order.order_type == OrderType::Limit && order.tif == TimeInForce::Gtc {
            "ACCEPTED".to_string()
        } else {
            "CANCELED".to_string()
        };

        let response = proto::PlaceOrderResponse {
            accepted: true,
            order_id: order.order_id.clone(),
            status,
            symbol: self.cfg.symbol.clone(),
            seq: self.seq,
            accepted_at: now_timestamp(),
            reject_code: String::new(),
            correlation_id: meta.correlation_id.clone(),
        };

        self.append_checkpoint(&meta, &mut events);
        self.persist_command(&meta.command_id, events)?;
        self.seen_order_ids.insert(order.order_id.clone());
        self.store_idempotent_place(&meta, &response);
        Ok(response)
    }

    pub fn cancel_order(
        &mut self,
        req: proto::CancelOrderRequest,
    ) -> Result<proto::CancelOrderResponse, EngineError> {
        let meta = match from_proto_meta(&req.meta) {
            Ok(v) => v,
            Err(code) => return Ok(self.make_cancel_reject_response(&req.order_id, "", code)),
        };

        if !self.is_leader_valid() {
            self.transition_mode(SymbolMode::HardHalt, "fencing-token-invalid");
            let resp = self.make_cancel_reject_response(
                &req.order_id,
                &meta.correlation_id,
                RejectCode::FencingToken,
            );
            self.store_idempotent_cancel(&meta, &resp);
            return Ok(resp);
        }

        if meta.symbol != self.cfg.symbol {
            let resp = self.make_cancel_reject_response(
                &req.order_id,
                &meta.correlation_id,
                RejectCode::Validation,
            );
            self.store_idempotent_cancel(&meta, &resp);
            return Ok(resp);
        }

        self.prune_idempotency();
        if let Some(idem) = self
            .idempotency
            .get(&(meta.symbol.clone(), meta.idempotency_key.clone()))
        {
            if let IdempotentResponse::Cancel(existing) = &idem.response {
                return Ok(existing.clone());
            }
        }

        if let Some(order) = self.order_book.get_order(&req.order_id) {
            if order.user_id != meta.user_id {
                let mut events = vec![self.event_cancel_rejected(
                    &req.order_id,
                    &meta,
                    RejectCode::UnknownOrder,
                )];
                self.append_checkpoint(&meta, &mut events);
                self.persist_command(&meta.command_id, events)?;
                let resp = self.make_cancel_reject_response(
                    &req.order_id,
                    &meta.correlation_id,
                    RejectCode::UnknownOrder,
                );
                self.store_idempotent_cancel(&meta, &resp);
                return Ok(resp);
            }
        }

        let mut events = Vec::new();
        let response = match self.order_book.cancel(&req.order_id) {
            Some(order) => {
                self.risk.release_reservation(&order);
                events.push(self.event_order_canceled(&order, &meta));
                proto::CancelOrderResponse {
                    accepted: true,
                    order_id: req.order_id.clone(),
                    status: "CANCELED".to_string(),
                    symbol: self.cfg.symbol.clone(),
                    seq: self.seq,
                    canceled_at: now_timestamp(),
                    reject_code: String::new(),
                    correlation_id: meta.correlation_id.clone(),
                }
            }
            None => {
                events.push(self.event_cancel_rejected(
                    &req.order_id,
                    &meta,
                    RejectCode::UnknownOrder,
                ));
                self.make_cancel_reject_response(
                    &req.order_id,
                    &meta.correlation_id,
                    RejectCode::UnknownOrder,
                )
            }
        };

        self.append_checkpoint(&meta, &mut events);
        self.persist_command(&meta.command_id, events)?;
        self.store_idempotent_cancel(&meta, &response);
        Ok(response)
    }

    pub fn set_symbol_mode(
        &mut self,
        req: proto::SetSymbolModeRequest,
    ) -> Result<proto::SetSymbolModeResponse, EngineError> {
        let meta = match from_proto_meta(&req.meta) {
            Ok(v) => v,
            Err(code) => return Ok(self.make_set_mode_reject_response(code.as_str())),
        };
        if !self.is_leader_valid() {
            self.transition_mode(SymbolMode::HardHalt, "fencing-token-invalid");
            return Ok(self.make_set_mode_reject_response(RejectCode::FencingToken.as_str()));
        }
        if meta.symbol != self.cfg.symbol {
            return Ok(self.make_set_mode_reject_response(RejectCode::Validation.as_str()));
        }
        let mode = match to_symbol_mode(req.mode) {
            Ok(v) => v,
            Err(code) => return Ok(self.make_set_mode_reject_response(code.as_str())),
        };
        self.transition_mode(mode, &req.reason);
        let mut events = Vec::new();
        self.append_checkpoint(&meta, &mut events);
        self.persist_command(&meta.command_id, events)?;

        Ok(proto::SetSymbolModeResponse {
            accepted: true,
            symbol: self.cfg.symbol.clone(),
            seq: self.seq,
            acted_at: now_timestamp(),
            reason: req.reason,
        })
    }

    pub fn cancel_all(
        &mut self,
        req: proto::CancelAllRequest,
    ) -> Result<proto::CancelAllResponse, EngineError> {
        let meta = match from_proto_meta(&req.meta) {
            Ok(v) => v,
            Err(code) => return Ok(self.make_cancel_all_reject_response(code.as_str())),
        };
        if !self.is_leader_valid() {
            self.transition_mode(SymbolMode::HardHalt, "fencing-token-invalid");
            return Ok(self.make_cancel_all_reject_response(RejectCode::FencingToken.as_str()));
        }
        if meta.symbol != self.cfg.symbol {
            return Ok(self.make_cancel_all_reject_response(RejectCode::Validation.as_str()));
        }

        let orders = self.order_book.all_orders();
        let mut events = Vec::new();
        for order in orders {
            if let Some(removed) = self.order_book.cancel(&order.order_id) {
                self.risk.release_reservation(&removed);
                events.push(self.event_order_canceled(&removed, &meta));
            }
        }
        self.append_checkpoint(&meta, &mut events);
        self.persist_command(&meta.command_id, events)?;

        Ok(proto::CancelAllResponse {
            accepted: true,
            symbol: self.cfg.symbol.clone(),
            seq: self.seq,
            acted_at: now_timestamp(),
            reason: req.reason,
        })
    }

    fn persist_command(
        &mut self,
        command_id: &str,
        mut events: Vec<CoreEvent>,
    ) -> Result<(), EngineError> {
        let mut highest_seq = self.seq;
        for event in &events {
            highest_seq = highest_seq.max(event.envelope().seq);
        }

        self.last_state_hash = state_hash(highest_seq, self.mode_label(), &self.order_book);
        let checkpoint_seq = self.next_seq();
        let symbol = self.cfg.symbol.clone();
        let checkpoint_envelope = build_envelope(
            &symbol,
            checkpoint_seq,
            "EngineCheckpoint",
            "system",
            command_id,
        );
        events.push(CoreEvent::EngineCheckpoint(EngineCheckpointEvent {
            envelope: checkpoint_envelope,
            state_hash: self.last_state_hash.clone(),
        }));

        let record = WalRecord {
            seq: self.seq,
            command_id: command_id.to_string(),
            symbol: self.cfg.symbol.clone(),
            events: events.clone(),
            state_hash: self.last_state_hash.clone(),
            symbol_mode: Some(self.symbol_mode),
            fencing_token: self.leader_token,
        };

        self.wal.append(&record)?; // durable write first (commit line)
        self.outbox.enqueue(record.seq, &events)?; // publish path only after durable WAL
        self.recent_events.extend(events);
        Ok(())
    }

    fn append_checkpoint(&mut self, _meta: &CommandMeta, _events: &mut Vec<CoreEvent>) {
        // checkpoint is appended centrally in persist_command
    }

    fn event_order_accepted(&mut self, order: &Order, meta: &CommandMeta) -> CoreEvent {
        let seq = self.next_seq();
        let envelope = build_envelope(
            &self.cfg.symbol,
            seq,
            "OrderAccepted",
            &meta.correlation_id,
            &meta.command_id,
        );
        CoreEvent::OrderAccepted(OrderAcceptedEvent {
            envelope,
            order_id: order.order_id.clone(),
            user_id: order.user_id.clone(),
            side: order.side,
            order_type: order.order_type,
            price: order.price.unwrap_or_default().to_string(),
            quantity: order.original_qty.to_string(),
        })
    }

    fn event_order_rejected(
        &mut self,
        order: &Order,
        meta: &CommandMeta,
        code: RejectCode,
        detail: &str,
    ) -> CoreEvent {
        let seq = self.next_seq();
        let envelope = build_envelope(
            &self.cfg.symbol,
            seq,
            "OrderRejected",
            &meta.correlation_id,
            &meta.command_id,
        );
        CoreEvent::OrderRejected(OrderRejectedEvent {
            envelope,
            order_id: order.order_id.clone(),
            user_id: order.user_id.clone(),
            reject_code: code.as_str().to_string(),
            detail: detail.to_string(),
        })
    }

    fn event_order_canceled(&mut self, order: &Order, meta: &CommandMeta) -> CoreEvent {
        let seq = self.next_seq();
        let envelope = build_envelope(
            &self.cfg.symbol,
            seq,
            "OrderCanceled",
            &meta.correlation_id,
            &meta.command_id,
        );
        CoreEvent::OrderCanceled(OrderCanceledEvent {
            envelope,
            order_id: order.order_id.clone(),
            user_id: order.user_id.clone(),
            remaining_quantity: order.remaining_qty.to_string(),
        })
    }

    fn event_cancel_rejected(
        &mut self,
        order_id: &str,
        meta: &CommandMeta,
        code: RejectCode,
    ) -> CoreEvent {
        let seq = self.next_seq();
        let envelope = build_envelope(
            &self.cfg.symbol,
            seq,
            "CancelRejected",
            &meta.correlation_id,
            &meta.command_id,
        );
        CoreEvent::CancelRejected(CancelRejectedEvent {
            envelope,
            order_id: order_id.to_string(),
            user_id: meta.user_id.clone(),
            reject_code: code.as_str().to_string(),
            detail: "cancel reject".to_string(),
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn event_trade_executed(
        &mut self,
        meta: &CommandMeta,
        maker_order_id: &str,
        taker_order_id: &str,
        buyer_user_id: &str,
        seller_user_id: &str,
        price: u64,
        quantity: u64,
        trade_idx: u64,
    ) -> CoreEvent {
        let seq = self.next_seq();
        let envelope = build_envelope(
            &self.cfg.symbol,
            seq,
            "TradeExecuted",
            &meta.correlation_id,
            &meta.command_id,
        );
        let quote_amount = price.saturating_mul(quantity);
        CoreEvent::TradeExecuted(TradeExecutedEvent {
            envelope,
            trade_id: format!("trd-{seq}-{trade_idx}-{}", meta.command_id),
            maker_order_id: maker_order_id.to_string(),
            taker_order_id: taker_order_id.to_string(),
            buyer_user_id: buyer_user_id.to_string(),
            seller_user_id: seller_user_id.to_string(),
            price: price.to_string(),
            quantity: quantity.to_string(),
            quote_amount: quote_amount.to_string(),
            fee_buyer: "0".to_string(),
            fee_seller: "0".to_string(),
        })
    }

    fn make_place_reject_response(
        &self,
        order_id: &str,
        correlation_id: &str,
        code: RejectCode,
    ) -> proto::PlaceOrderResponse {
        proto::PlaceOrderResponse {
            accepted: false,
            order_id: order_id.to_string(),
            status: "REJECTED".to_string(),
            symbol: self.cfg.symbol.clone(),
            seq: self.seq,
            accepted_at: now_timestamp(),
            reject_code: code.as_str().to_string(),
            correlation_id: correlation_id.to_string(),
        }
    }

    fn make_cancel_reject_response(
        &self,
        order_id: &str,
        correlation_id: &str,
        code: RejectCode,
    ) -> proto::CancelOrderResponse {
        proto::CancelOrderResponse {
            accepted: false,
            order_id: order_id.to_string(),
            status: "REJECTED".to_string(),
            symbol: self.cfg.symbol.clone(),
            seq: self.seq,
            canceled_at: now_timestamp(),
            reject_code: code.as_str().to_string(),
            correlation_id: correlation_id.to_string(),
        }
    }

    fn make_set_mode_reject_response(&self, reason: &str) -> proto::SetSymbolModeResponse {
        proto::SetSymbolModeResponse {
            accepted: false,
            symbol: self.cfg.symbol.clone(),
            seq: self.seq,
            acted_at: now_timestamp(),
            reason: reason.to_string(),
        }
    }

    fn make_cancel_all_reject_response(&self, reason: &str) -> proto::CancelAllResponse {
        proto::CancelAllResponse {
            accepted: false,
            symbol: self.cfg.symbol.clone(),
            seq: self.seq,
            acted_at: now_timestamp(),
            reason: reason.to_string(),
        }
    }

    fn store_idempotent_place(&mut self, meta: &CommandMeta, response: &proto::PlaceOrderResponse) {
        self.idempotency.insert(
            (meta.symbol.clone(), meta.idempotency_key.clone()),
            IdempotencyEntry {
                created_at_ms: meta.ts_server_ms,
                response: IdempotentResponse::Place(response.clone()),
            },
        );
    }

    fn store_idempotent_cancel(
        &mut self,
        meta: &CommandMeta,
        response: &proto::CancelOrderResponse,
    ) {
        self.idempotency.insert(
            (meta.symbol.clone(), meta.idempotency_key.clone()),
            IdempotencyEntry {
                created_at_ms: meta.ts_server_ms,
                response: IdempotentResponse::Cancel(response.clone()),
            },
        );
    }

    fn prune_idempotency(&mut self) {
        let now = crate::model::now_millis();
        self.idempotency
            .retain(|_, v| now.saturating_sub(v.created_at_ms) <= self.cfg.idempotency_ttl_ms);
    }

    fn is_leader_valid(&self) -> bool {
        self.fencing.is_valid(self.leader_token)
    }

    fn transition_mode(&mut self, next: SymbolMode, reason: &str) {
        if self.symbol_mode != next {
            self.mode_transitions
                .push(format!("{:?}->{:?}:{reason}", self.symbol_mode, next));
            self.symbol_mode = next;
        }
    }

    fn next_seq(&mut self) -> u64 {
        self.seq += 1;
        self.seq
    }

    fn mode_label(&self) -> &'static str {
        match self.symbol_mode {
            SymbolMode::Normal => "NORMAL",
            SymbolMode::CancelOnly => "CANCEL_ONLY",
            SymbolMode::SoftHalt => "SOFT_HALT",
            SymbolMode::HardHalt => "HARD_HALT",
        }
    }

    fn apply_replay_event(&mut self, event: &CoreEvent) {
        let env = event.envelope();
        self.seq = self.seq.max(env.seq);
        match event {
            CoreEvent::OrderAccepted(e) => {
                self.seen_order_ids.insert(e.order_id.clone());
                let order = Order {
                    order_id: e.order_id.clone(),
                    user_id: e.user_id.clone(),
                    symbol: self.cfg.symbol.clone(),
                    side: e.side,
                    order_type: e.order_type,
                    tif: TimeInForce::Gtc,
                    price: e.price.parse::<u64>().ok(),
                    original_qty: e.quantity.parse::<u64>().unwrap_or(0),
                    remaining_qty: e.quantity.parse::<u64>().unwrap_or(0),
                    accepted_seq: env.seq,
                };
                if order.order_type == OrderType::Limit {
                    self.order_book.insert(order);
                }
            }
            CoreEvent::TradeExecuted(e) => {
                let qty = e.quantity.parse::<u64>().unwrap_or(0);
                let _ = self.order_book.apply_fill(&e.maker_order_id, qty);
                let _ = self.order_book.apply_fill(&e.taker_order_id, qty);
                self.ref_price = e.price.parse::<u64>().ok();
            }
            CoreEvent::OrderCanceled(e) => {
                let _ = self.order_book.cancel(&e.order_id);
            }
            CoreEvent::EngineCheckpoint(e) => {
                self.last_state_hash = e.state_hash.clone();
            }
            CoreEvent::OrderRejected(_)
            | CoreEvent::CancelRejected(_)
            | CoreEvent::BookDelta(_) => {}
        }
    }
}

impl TradingCore {
    fn bootstrap_user_balances(&mut self, user_id: &str) {
        let (base, quote) = match split_symbol(&self.cfg.symbol) {
            Ok(parts) => parts,
            Err(_) => return,
        };

        let quote_balance = self.risk.get_balance(user_id, &quote);
        if quote_balance.available == 0 && quote_balance.hold == 0 {
            self.risk.set_balance(user_id, &quote, 1_000_000_000_000, 0);
        }
        let base_balance = self.risk.get_balance(user_id, &base);
        if base_balance.available == 0 && base_balance.hold == 0 {
            self.risk.set_balance(user_id, &base, 1_000_000_000, 0);
        }
    }
}

fn opposite(side: Side) -> Side {
    match side {
        Side::Buy => Side::Sell,
        Side::Sell => Side::Buy,
    }
}

pub fn proto_envelope(envelope: &EventEnvelope) -> proto::EventEnvelope {
    proto::EventEnvelope {
        event_id: envelope.event_id.clone(),
        event_version: envelope.event_version,
        symbol: envelope.symbol.clone(),
        seq: envelope.seq,
        occurred_at: Some(prost_types::Timestamp {
            seconds: envelope.occurred_at_ms / 1_000,
            nanos: ((envelope.occurred_at_ms % 1_000) * 1_000_000) as i32,
        }),
        correlation_id: envelope.correlation_id.clone(),
        causation_id: envelope.causation_id.clone(),
    }
}
