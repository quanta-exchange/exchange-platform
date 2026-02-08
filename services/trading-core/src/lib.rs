use serde::{Deserialize, Serialize};

pub mod determinism;
pub mod engine;
pub mod leader;
pub mod model;
pub mod orderbook;
pub mod outbox;
pub mod risk;
pub mod snapshot;
pub mod wal;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoreHealth {
    pub service: String,
    pub status: String,
}

pub fn health() -> CoreHealth {
    CoreHealth {
        service: "trading-core".to_string(),
        status: "ok".to_string(),
    }
}

pub mod contracts {
    pub mod google {
        pub mod protobuf {
            pub type Timestamp = prost_types::Timestamp;
        }
    }

    pub mod exchange {
        pub mod v1 {
            include!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../contracts/gen/rust/exchange/v1/exchange.v1.rs"
            ));
        }
    }
}

#[cfg(test)]
mod tests;
