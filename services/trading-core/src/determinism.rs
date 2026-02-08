use crate::model::Order;
use crate::orderbook::OrderBook;
use serde::Serialize;
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Serialize)]
struct HashInput {
    seq: u64,
    mode: String,
    orders: Vec<Order>,
    best_bid: Option<u64>,
    best_ask: Option<u64>,
}

pub fn state_hash(seq: u64, mode: &str, order_book: &OrderBook) -> String {
    let input = HashInput {
        seq,
        mode: mode.to_string(),
        orders: order_book.all_orders(),
        best_bid: order_book.best_bid(),
        best_ask: order_book.best_ask(),
    };
    let bytes = serde_json::to_vec(&input).unwrap_or_default();
    let hash = Sha256::digest(bytes);
    format!("{hash:x}")
}
