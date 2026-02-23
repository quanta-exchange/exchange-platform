use std::env;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tonic::{transport::Server, Request, Response, Status};

use trading_core::engine::{CoreConfig, TradingCore};
use trading_core::kafka::KafkaTradePublisher;
use trading_core::leader::FencingCoordinator;
use trading_core::outbox::EventSink;

use trading_core::contracts::exchange::v1::trading_core_service_server::{
    TradingCoreService, TradingCoreServiceServer,
};
use trading_core::contracts::exchange::v1::{
    CancelAllRequest, CancelAllResponse, CancelOrderRequest, CancelOrderResponse,
    PlaceOrderRequest, PlaceOrderResponse, SetSymbolModeRequest, SetSymbolModeResponse,
};

struct CoreGrpcService {
    core: Arc<Mutex<TradingCore>>,
    publisher: Arc<Mutex<Box<dyn EventSink + Send>>>,
    publish_retries: usize,
}

impl CoreGrpcService {
    fn flush_pending(&self) -> Result<(), Status> {
        let core = self
            .core
            .lock()
            .map_err(|_| Status::internal("core lock poisoned"))?;
        let mut publisher = self
            .publisher
            .lock()
            .map_err(|_| Status::internal("publisher lock poisoned"))?;
        core.publish_pending(&mut **publisher, self.publish_retries)
            .map_err(|e| Status::internal(format!("publish pending: {e}")))?;
        Ok(())
    }
}

#[tonic::async_trait]
impl TradingCoreService for CoreGrpcService {
    async fn place_order(
        &self,
        request: Request<PlaceOrderRequest>,
    ) -> Result<Response<PlaceOrderResponse>, Status> {
        let req = request.into_inner();
        eprintln!(
            "service=trading-core msg=place_order order_id={} symbol={} user_id={}",
            req.order_id,
            req.meta.as_ref().map(|m| m.symbol.as_str()).unwrap_or(""),
            req.meta.as_ref().map(|m| m.user_id.as_str()).unwrap_or("")
        );
        let response = {
            let mut core = self
                .core
                .lock()
                .map_err(|_| Status::internal("core lock poisoned"))?;
            core.place_order(req)
                .map_err(|e| Status::internal(format!("place order: {e}")))?
        };
        self.flush_pending()?;

        Ok(Response::new(response))
    }

    async fn cancel_order(
        &self,
        request: Request<CancelOrderRequest>,
    ) -> Result<Response<CancelOrderResponse>, Status> {
        let response = {
            let mut core = self
                .core
                .lock()
                .map_err(|_| Status::internal("core lock poisoned"))?;
            core.cancel_order(request.into_inner())
                .map_err(|e| Status::internal(format!("cancel order: {e}")))?
        };
        self.flush_pending()?;
        Ok(Response::new(response))
    }

    async fn set_symbol_mode(
        &self,
        request: Request<SetSymbolModeRequest>,
    ) -> Result<Response<SetSymbolModeResponse>, Status> {
        let response = {
            let mut core = self
                .core
                .lock()
                .map_err(|_| Status::internal("core lock poisoned"))?;
            core.set_symbol_mode(request.into_inner())
                .map_err(|e| Status::internal(format!("set symbol mode: {e}")))?
        };
        self.flush_pending()?;
        Ok(Response::new(response))
    }

    async fn cancel_all(
        &self,
        request: Request<CancelAllRequest>,
    ) -> Result<Response<CancelAllResponse>, Status> {
        let response = {
            let mut core = self
                .core
                .lock()
                .map_err(|_| Status::internal("core lock poisoned"))?;
            core.cancel_all(request.into_inner())
                .map_err(|e| Status::internal(format!("cancel all: {e}")))?
        };
        self.flush_pending()?;
        Ok(Response::new(response))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let core_env = getenv("CORE_ENV", "local");
    let addr: SocketAddr = getenv("CORE_GRPC_ADDR", "0.0.0.0:50051").parse()?;
    let symbol = getenv("CORE_SYMBOL", "BTC-KRW");
    let wal_dir = getenv("CORE_WAL_DIR", "/tmp/trading-core/wal");
    let outbox_dir = getenv("CORE_OUTBOX_DIR", "/tmp/trading-core/outbox");
    let kafka_brokers = getenv("CORE_KAFKA_BROKERS", "localhost:29092");
    let kafka_topic = getenv("CORE_KAFKA_TRADE_TOPIC", "core.trade-events.v1");
    let publish_retries = getenv_usize("CORE_PUBLISH_RETRIES", 3);
    let recent_events_limit = getenv_usize("CORE_RECENT_EVENTS_LIMIT", 4096);
    let stub_trades = getenv_bool("CORE_STUB_TRADES", false);
    if let Err(reason) = validate_runtime_guardrails(
        &core_env,
        &wal_dir,
        &outbox_dir,
        stub_trades,
        &kafka_brokers,
    ) {
        return Err(std::io::Error::new(std::io::ErrorKind::Other, reason).into());
    }

    let mut cfg = CoreConfig::default();
    cfg.symbol = symbol;
    cfg.wal_dir = wal_dir.into();
    cfg.outbox_dir = outbox_dir.into();
    cfg.recent_events_limit = recent_events_limit;
    cfg.stub_trades = stub_trades;

    let core = TradingCore::new(cfg, FencingCoordinator::default())?;
    eprintln!(
        "service=trading-core msg=recovered_from_wal seq={} state_hash={} mode={:?}",
        core.current_seq(),
        core.last_state_hash(),
        core.symbol_mode(),
    );
    let publisher = KafkaTradePublisher::new(&kafka_brokers, &kafka_topic, Duration::from_secs(2))?;

    let service = CoreGrpcService {
        core: Arc::new(Mutex::new(core)),
        publisher: Arc::new(Mutex::new(Box::new(publisher))),
        publish_retries,
    };

    Server::builder()
        .add_service(TradingCoreServiceServer::new(service))
        .serve(addr)
        .await?;
    Ok(())
}

fn getenv(key: &str, fallback: &str) -> String {
    env::var(key).unwrap_or_else(|_| fallback.to_string())
}

fn getenv_usize(key: &str, fallback: usize) -> usize {
    env::var(key)
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(fallback)
}

fn getenv_bool(key: &str, fallback: bool) -> bool {
    env::var(key)
        .ok()
        .and_then(|v| v.parse::<bool>().ok())
        .unwrap_or(fallback)
}

fn is_production_environment(env: &str) -> bool {
    matches!(
        env.trim().to_ascii_lowercase().as_str(),
        "prod" | "production" | "live"
    )
}

fn is_tmp_path(path: &str) -> bool {
    let normalized = path.trim().to_ascii_lowercase();
    normalized == "/tmp" || normalized.starts_with("/tmp/")
}

fn has_localhost_broker(brokers: &str) -> bool {
    brokers
        .split(',')
        .map(str::trim)
        .any(|b| b.starts_with("localhost:") || b.starts_with("127.0.0.1:"))
}

fn validate_runtime_guardrails(
    core_env: &str,
    wal_dir: &str,
    outbox_dir: &str,
    stub_trades: bool,
    kafka_brokers: &str,
) -> Result<(), String> {
    if !is_production_environment(core_env) {
        return Ok(());
    }
    if stub_trades {
        return Err("production guardrail: CORE_STUB_TRADES must be false".to_string());
    }
    if is_tmp_path(wal_dir) {
        return Err("production guardrail: CORE_WAL_DIR must not point to /tmp".to_string());
    }
    if is_tmp_path(outbox_dir) {
        return Err("production guardrail: CORE_OUTBOX_DIR must not point to /tmp".to_string());
    }
    if has_localhost_broker(kafka_brokers) {
        return Err(
            "production guardrail: CORE_KAFKA_BROKERS must not use localhost/127.0.0.1".to_string(),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tempfile::TempDir;
    use tonic::Request;
    use trading_core::contracts::exchange::v1::trading_core_service_server::TradingCoreService;
    use trading_core::contracts::exchange::v1::{
        CancelAllRequest, CancelOrderRequest, CommandMetadata, OrderType, PlaceOrderRequest,
        SetSymbolModeRequest, Side, SymbolMode, TimeInForce,
    };

    struct CountingSink {
        published: Arc<AtomicUsize>,
    }

    impl EventSink for CountingSink {
        fn publish(&mut self, _event: &trading_core::model::CoreEvent) -> Result<(), String> {
            self.published.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    fn meta(command_id: &str, idem: &str, user_id: &str) -> Option<CommandMetadata> {
        Some(CommandMetadata {
            command_id: command_id.to_string(),
            idempotency_key: idem.to_string(),
            user_id: user_id.to_string(),
            symbol: "BTC-KRW".to_string(),
            ts_server: None,
            trace_id: format!("trace-{command_id}"),
            correlation_id: format!("corr-{command_id}"),
        })
    }

    fn test_service(tmp: &TempDir, published: Arc<AtomicUsize>) -> CoreGrpcService {
        let mut cfg = CoreConfig::default();
        cfg.symbol = "BTC-KRW".to_string();
        cfg.wal_dir = tmp.path().join("wal");
        cfg.outbox_dir = tmp.path().join("outbox");
        let mut core = TradingCore::new(cfg, FencingCoordinator::new()).unwrap();
        core.set_balance("u1", "BTC", 1_000_000, 0);
        core.set_balance("u1", "KRW", 1_000_000_000_000, 0);
        CoreGrpcService {
            core: Arc::new(Mutex::new(core)),
            publisher: Arc::new(Mutex::new(Box::new(CountingSink { published }))),
            publish_retries: 0,
        }
    }

    #[tokio::test]
    async fn cancel_order_flushes_pending_outbox_events() {
        let tmp = TempDir::new().unwrap();
        let published = Arc::new(AtomicUsize::new(0));
        let service = test_service(&tmp, Arc::clone(&published));

        let _ = TradingCoreService::place_order(
            &service,
            Request::new(PlaceOrderRequest {
                meta: meta("place-1", "idem-place-1", "u1"),
                order_id: "ord-1".to_string(),
                side: Side::Buy as i32,
                order_type: OrderType::Limit as i32,
                price: "100".to_string(),
                quantity: "1".to_string(),
                time_in_force: TimeInForce::Gtc as i32,
            }),
        )
        .await
        .unwrap();
        let baseline = published.load(Ordering::SeqCst);

        let _ = TradingCoreService::cancel_order(
            &service,
            Request::new(CancelOrderRequest {
                meta: meta("cancel-1", "idem-cancel-1", "u1"),
                order_id: "ord-1".to_string(),
            }),
        )
        .await
        .unwrap();

        assert!(published.load(Ordering::SeqCst) > baseline);
    }

    #[tokio::test]
    async fn set_symbol_mode_flushes_pending_outbox_events() {
        let tmp = TempDir::new().unwrap();
        let published = Arc::new(AtomicUsize::new(0));
        let service = test_service(&tmp, Arc::clone(&published));
        let baseline = published.load(Ordering::SeqCst);

        let _ = TradingCoreService::set_symbol_mode(
            &service,
            Request::new(SetSymbolModeRequest {
                meta: meta("mode-1", "idem-mode-1", "admin"),
                mode: SymbolMode::CancelOnly as i32,
                reason: "test".to_string(),
            }),
        )
        .await
        .unwrap();

        assert!(published.load(Ordering::SeqCst) > baseline);
    }

    #[tokio::test]
    async fn cancel_all_flushes_pending_outbox_events() {
        let tmp = TempDir::new().unwrap();
        let published = Arc::new(AtomicUsize::new(0));
        let service = test_service(&tmp, Arc::clone(&published));
        let baseline = published.load(Ordering::SeqCst);

        let _ = TradingCoreService::cancel_all(
            &service,
            Request::new(CancelAllRequest {
                meta: meta("cancel-all-1", "idem-cancel-all-1", "admin"),
                reason: "test".to_string(),
            }),
        )
        .await
        .unwrap();

        assert!(published.load(Ordering::SeqCst) > baseline);
    }

    #[test]
    fn runtime_guardrails_allow_local_defaults() {
        let res = validate_runtime_guardrails(
            "local",
            "/tmp/trading-core/wal",
            "/tmp/trading-core/outbox",
            true,
            "localhost:29092",
        );
        assert!(res.is_ok(), "local mode should allow development defaults");
    }

    #[test]
    fn runtime_guardrails_reject_prod_stub_trades() {
        let err = validate_runtime_guardrails(
            "prod",
            "/var/lib/trading-core/wal",
            "/var/lib/trading-core/outbox",
            true,
            "kafka:9092",
        )
        .unwrap_err();
        assert!(err.contains("CORE_STUB_TRADES"));
    }

    #[test]
    fn runtime_guardrails_reject_prod_tmp_dirs() {
        let err = validate_runtime_guardrails(
            "production",
            "/tmp/trading-core/wal",
            "/var/lib/trading-core/outbox",
            false,
            "kafka:9092",
        )
        .unwrap_err();
        assert!(err.contains("CORE_WAL_DIR"));
    }

    #[test]
    fn runtime_guardrails_reject_prod_localhost_kafka() {
        let err = validate_runtime_guardrails(
            "prod",
            "/var/lib/trading-core/wal",
            "/var/lib/trading-core/outbox",
            false,
            "localhost:29092,redpanda:9092",
        )
        .unwrap_err();
        assert!(err.contains("CORE_KAFKA_BROKERS"));
    }

    #[test]
    fn runtime_guardrails_accept_valid_prod_configuration() {
        let res = validate_runtime_guardrails(
            "prod",
            "/var/lib/trading-core/wal",
            "/var/lib/trading-core/outbox",
            false,
            "redpanda-0:9092,redpanda-1:9092",
        );
        assert!(
            res.is_ok(),
            "valid production settings should pass guardrails"
        );
    }
}
