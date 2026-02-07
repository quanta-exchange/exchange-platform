use serde::{Deserialize, Serialize};

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
mod tests {
    use super::*;

    #[test]
    fn health_is_ok() {
        let result = health();
        assert_eq!(result.service, "trading-core");
        assert_eq!(result.status, "ok");
    }

    #[test]
    fn generated_contract_types_compile() {
        let envelope = contracts::exchange::v1::EventEnvelope {
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
}
