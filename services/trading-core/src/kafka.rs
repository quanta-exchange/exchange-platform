use crate::model::{CoreEvent, EventEnvelope, TradeExecutedEvent};
use crate::outbox::EventSink;
use rdkafka::config::ClientConfig;
use rdkafka::producer::{BaseProducer, BaseRecord, Producer};
use rdkafka::util::Timeout;
use serde::Serialize;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

pub struct KafkaTradePublisher {
    producer: BaseProducer,
    topic: String,
    flush_timeout: std::time::Duration,
}

impl KafkaTradePublisher {
    pub fn new(
        brokers: &str,
        topic: &str,
        flush_timeout: std::time::Duration,
    ) -> Result<Self, String> {
        let producer = ClientConfig::new()
            .set("bootstrap.servers", brokers)
            .set("message.timeout.ms", "5000")
            .create::<BaseProducer>()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            producer,
            topic: topic.to_string(),
            flush_timeout,
        })
    }
}

impl EventSink for KafkaTradePublisher {
    fn publish(&mut self, event: &CoreEvent) -> Result<(), String> {
        let trade = match event {
            CoreEvent::TradeExecuted(e) => e,
            _ => return Ok(()),
        };

        let payload = TradeExecutedPayload::from(trade)?;
        let json = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
        self.producer
            .send(
                BaseRecord::to(&self.topic)
                    .payload(&json)
                    .key(&payload.trade_id),
            )
            .map_err(|(e, _)| e.to_string())?;
        self.producer
            .flush(Timeout::After(self.flush_timeout))
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TradeExecutedPayload {
    envelope: EventEnvelopePayload,
    symbol: String,
    seq: u64,
    ts: i64,
    trade_id: String,
    maker_order_id: String,
    taker_order_id: String,
    buyer_user_id: String,
    seller_user_id: String,
    price: i64,
    quantity: i64,
    quote_amount: i64,
    fee_buyer: i64,
    fee_seller: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EventEnvelopePayload {
    event_id: String,
    event_version: u32,
    symbol: String,
    seq: u64,
    occurred_at: String,
    correlation_id: String,
    causation_id: String,
}

impl TradeExecutedPayload {
    fn from(event: &TradeExecutedEvent) -> Result<Self, String> {
        let envelope = EventEnvelopePayload::from(&event.envelope)?;
        Ok(Self {
            symbol: event.envelope.symbol.clone(),
            seq: event.envelope.seq,
            ts: event.envelope.occurred_at_ms,
            envelope,
            trade_id: event.trade_id.clone(),
            maker_order_id: event.maker_order_id.clone(),
            taker_order_id: event.taker_order_id.clone(),
            buyer_user_id: event.buyer_user_id.clone(),
            seller_user_id: event.seller_user_id.clone(),
            price: parse_i64("price", &event.price)?,
            quantity: parse_i64("quantity", &event.quantity)?,
            quote_amount: parse_i64("quote_amount", &event.quote_amount)?,
            fee_buyer: parse_i64("fee_buyer", &event.fee_buyer)?,
            fee_seller: parse_i64("fee_seller", &event.fee_seller)?,
        })
    }
}

impl EventEnvelopePayload {
    fn from(event: &EventEnvelope) -> Result<Self, String> {
        let occurred_at =
            OffsetDateTime::from_unix_timestamp_nanos(i128::from(event.occurred_at_ms) * 1_000_000)
                .map_err(|e| e.to_string())?
                .format(&Rfc3339)
                .map_err(|e| e.to_string())?;
        Ok(Self {
            event_id: event.event_id.clone(),
            event_version: event.event_version,
            symbol: event.symbol.clone(),
            seq: event.seq,
            occurred_at,
            correlation_id: event.correlation_id.clone(),
            causation_id: event.causation_id.clone(),
        })
    }
}

fn parse_i64(field: &str, value: &str) -> Result<i64, String> {
    value
        .parse::<i64>()
        .map_err(|e| format!("invalid {field} value '{value}': {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_i64_rejects_invalid_payload_numbers() {
        let err = parse_i64("price", "not-a-number").unwrap_err();
        assert!(err.contains("invalid price value"));
    }

    #[test]
    fn parse_i64_accepts_valid_payload_numbers() {
        assert_eq!(parse_i64("quantity", "42").unwrap(), 42);
    }
}
