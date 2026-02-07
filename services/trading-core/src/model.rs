use crate::contracts::exchange::v1 as proto;
use prost_types::Timestamp;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Hash)]
pub enum Side {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Hash)]
pub enum OrderType {
    Limit,
    Market,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Hash)]
pub enum SymbolMode {
    Normal,
    CancelOnly,
    SoftHalt,
    HardHalt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Hash)]
pub enum TimeInForce {
    Gtc,
    Ioc,
    Fok,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RejectCode {
    Validation,
    PriceBand,
    InsufficientFunds,
    MarketHalted,
    TooManyRequests,
    UnknownOrder,
    CancelOnly,
    NoLiquidity,
    FencingToken,
}

impl RejectCode {
    pub fn as_str(&self) -> &'static str {
        match self {
            RejectCode::Validation => "VALIDATION",
            RejectCode::PriceBand => "PRICE_BAND",
            RejectCode::InsufficientFunds => "INSUFFICIENT_FUNDS",
            RejectCode::MarketHalted => "MARKET_HALTED",
            RejectCode::TooManyRequests => "TOO_MANY_REQUESTS",
            RejectCode::UnknownOrder => "UNKNOWN_ORDER",
            RejectCode::CancelOnly => "CANCEL_ONLY",
            RejectCode::NoLiquidity => "NO_LIQUIDITY",
            RejectCode::FencingToken => "FENCING_TOKEN",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandMeta {
    pub command_id: String,
    pub idempotency_key: String,
    pub user_id: String,
    pub symbol: String,
    pub trace_id: String,
    pub correlation_id: String,
    pub ts_server_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Order {
    pub order_id: String,
    pub user_id: String,
    pub symbol: String,
    pub side: Side,
    pub order_type: OrderType,
    pub tif: TimeInForce,
    pub price: Option<u64>,
    pub original_qty: u64,
    pub remaining_qty: u64,
    pub accepted_seq: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventEnvelope {
    pub event_id: String,
    pub event_version: u32,
    pub symbol: String,
    pub seq: u64,
    pub occurred_at_ms: i64,
    pub correlation_id: String,
    pub causation_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrderAcceptedEvent {
    pub envelope: EventEnvelope,
    pub order_id: String,
    pub user_id: String,
    pub side: Side,
    pub order_type: OrderType,
    pub price: String,
    pub quantity: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrderRejectedEvent {
    pub envelope: EventEnvelope,
    pub order_id: String,
    pub user_id: String,
    pub reject_code: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrderCanceledEvent {
    pub envelope: EventEnvelope,
    pub order_id: String,
    pub user_id: String,
    pub remaining_quantity: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CancelRejectedEvent {
    pub envelope: EventEnvelope,
    pub order_id: String,
    pub user_id: String,
    pub reject_code: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TradeExecutedEvent {
    pub envelope: EventEnvelope,
    pub trade_id: String,
    pub maker_order_id: String,
    pub taker_order_id: String,
    pub buyer_user_id: String,
    pub seller_user_id: String,
    pub price: String,
    pub quantity: String,
    pub quote_amount: String,
    pub fee_buyer: String,
    pub fee_seller: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BookDeltaEvent {
    pub envelope: EventEnvelope,
    pub depth: u32,
    pub is_snapshot: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EngineCheckpointEvent {
    pub envelope: EventEnvelope,
    pub state_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum CoreEvent {
    OrderAccepted(OrderAcceptedEvent),
    OrderRejected(OrderRejectedEvent),
    OrderCanceled(OrderCanceledEvent),
    CancelRejected(CancelRejectedEvent),
    TradeExecuted(TradeExecutedEvent),
    BookDelta(BookDeltaEvent),
    EngineCheckpoint(EngineCheckpointEvent),
}

impl CoreEvent {
    pub fn envelope(&self) -> &EventEnvelope {
        match self {
            CoreEvent::OrderAccepted(e) => &e.envelope,
            CoreEvent::OrderRejected(e) => &e.envelope,
            CoreEvent::OrderCanceled(e) => &e.envelope,
            CoreEvent::CancelRejected(e) => &e.envelope,
            CoreEvent::TradeExecuted(e) => &e.envelope,
            CoreEvent::BookDelta(e) => &e.envelope,
            CoreEvent::EngineCheckpoint(e) => &e.envelope,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            CoreEvent::OrderAccepted(_) => "OrderAccepted",
            CoreEvent::OrderRejected(_) => "OrderRejected",
            CoreEvent::OrderCanceled(_) => "OrderCanceled",
            CoreEvent::CancelRejected(_) => "CancelRejected",
            CoreEvent::TradeExecuted(_) => "TradeExecuted",
            CoreEvent::BookDelta(_) => "BookDelta",
            CoreEvent::EngineCheckpoint(_) => "EngineCheckpoint",
        }
    }
}

pub fn now_millis() -> i64 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    i64::try_from(now.as_millis()).unwrap_or(i64::MAX)
}

pub fn now_timestamp() -> Option<Timestamp> {
    Some(Timestamp {
        seconds: now_millis() / 1_000,
        nanos: ((now_millis() % 1_000) * 1_000_000) as i32,
    })
}

pub fn parse_u64(value: &str) -> Result<u64, RejectCode> {
    value.parse::<u64>().map_err(|_| RejectCode::Validation)
}

pub fn split_symbol(symbol: &str) -> Result<(String, String), RejectCode> {
    let mut parts = symbol.split('-');
    let base = parts.next().unwrap_or_default();
    let quote = parts.next().unwrap_or_default();
    if base.is_empty() || quote.is_empty() || parts.next().is_some() {
        return Err(RejectCode::Validation);
    }
    Ok((base.to_string(), quote.to_string()))
}

pub fn to_side(value: i32) -> Result<Side, RejectCode> {
    match proto::Side::try_from(value).ok() {
        Some(proto::Side::Buy) => Ok(Side::Buy),
        Some(proto::Side::Sell) => Ok(Side::Sell),
        _ => Err(RejectCode::Validation),
    }
}

pub fn to_order_type(value: i32) -> Result<OrderType, RejectCode> {
    match proto::OrderType::try_from(value).ok() {
        Some(proto::OrderType::Limit) => Ok(OrderType::Limit),
        Some(proto::OrderType::Market) => Ok(OrderType::Market),
        _ => Err(RejectCode::Validation),
    }
}

pub fn to_time_in_force(value: i32) -> Result<TimeInForce, RejectCode> {
    match proto::TimeInForce::try_from(value).ok() {
        Some(proto::TimeInForce::Gtc) => Ok(TimeInForce::Gtc),
        Some(proto::TimeInForce::Ioc) => Ok(TimeInForce::Ioc),
        Some(proto::TimeInForce::Fok) => Ok(TimeInForce::Fok),
        _ => Err(RejectCode::Validation),
    }
}

pub fn to_symbol_mode(value: i32) -> Result<SymbolMode, RejectCode> {
    match proto::SymbolMode::try_from(value).ok() {
        Some(proto::SymbolMode::Normal) => Ok(SymbolMode::Normal),
        Some(proto::SymbolMode::CancelOnly) => Ok(SymbolMode::CancelOnly),
        Some(proto::SymbolMode::SoftHalt) => Ok(SymbolMode::SoftHalt),
        Some(proto::SymbolMode::HardHalt) => Ok(SymbolMode::HardHalt),
        _ => Err(RejectCode::Validation),
    }
}

pub fn from_proto_meta(meta: &Option<proto::CommandMetadata>) -> Result<CommandMeta, RejectCode> {
    let m = meta.as_ref().ok_or(RejectCode::Validation)?;
    if m.command_id.is_empty()
        || m.idempotency_key.is_empty()
        || m.user_id.is_empty()
        || m.symbol.is_empty()
        || m.trace_id.is_empty()
        || m.correlation_id.is_empty()
    {
        return Err(RejectCode::Validation);
    }

    let ts_server_ms = m
        .ts_server
        .as_ref()
        .map(|t| t.seconds.saturating_mul(1000) + i64::from(t.nanos / 1_000_000))
        .unwrap_or_else(now_millis);

    Ok(CommandMeta {
        command_id: m.command_id.clone(),
        idempotency_key: m.idempotency_key.clone(),
        user_id: m.user_id.clone(),
        symbol: m.symbol.clone(),
        trace_id: m.trace_id.clone(),
        correlation_id: m.correlation_id.clone(),
        ts_server_ms,
    })
}

pub fn build_envelope(
    symbol: &str,
    seq: u64,
    kind: &str,
    correlation_id: &str,
    causation_id: &str,
) -> EventEnvelope {
    EventEnvelope {
        event_id: format!("{symbol}-{seq}-{kind}"),
        event_version: 1,
        symbol: symbol.to_string(),
        seq,
        occurred_at_ms: now_millis(),
        correlation_id: correlation_id.to_string(),
        causation_id: causation_id.to_string(),
    }
}

pub fn apply_symbol_mode_rules(mode: SymbolMode) -> Result<(), RejectCode> {
    match mode {
        SymbolMode::HardHalt | SymbolMode::SoftHalt | SymbolMode::CancelOnly | SymbolMode::Normal => Ok(()),
    }
}
