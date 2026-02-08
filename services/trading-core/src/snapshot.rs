use crate::model::SymbolMode;
use crate::orderbook::OrderBook;
use crate::risk::RiskSnapshot;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

#[derive(Debug, thiserror::Error)]
pub enum SnapshotError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialize: {0}")]
    Serialize(#[from] serde_json::Error),
    #[error("hash mismatch")]
    HashMismatch,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub last_seq: u64,
    pub state_hash: String,
    pub symbol_mode: SymbolMode,
    pub order_book: OrderBook,
    pub risk: RiskSnapshot,
}

impl Snapshot {
    pub fn save<P: AsRef<Path>>(&self, path: P) -> Result<(), SnapshotError> {
        let tmp = path.as_ref().with_extension("tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        fs::rename(tmp, path)?;
        Ok(())
    }

    pub fn load<P: AsRef<Path>>(path: P) -> Result<Self, SnapshotError> {
        let raw = fs::read(path)?;
        Ok(serde_json::from_slice(&raw)?)
    }
}
