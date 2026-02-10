use std::env;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tonic::{transport::Server, Request, Response, Status};

use trading_core::engine::{CoreConfig, TradingCore};
use trading_core::kafka::KafkaTradePublisher;
use trading_core::leader::FencingCoordinator;

use trading_core::contracts::exchange::v1::trading_core_service_server::{
    TradingCoreService, TradingCoreServiceServer,
};
use trading_core::contracts::exchange::v1::{
    CancelAllRequest, CancelAllResponse, CancelOrderRequest, CancelOrderResponse,
    PlaceOrderRequest, PlaceOrderResponse, SetSymbolModeRequest, SetSymbolModeResponse,
};

struct CoreGrpcService {
    core: Arc<Mutex<TradingCore>>,
    publisher: Arc<Mutex<KafkaTradePublisher>>,
    publish_retries: usize,
}

#[tonic::async_trait]
impl TradingCoreService for CoreGrpcService {
    async fn place_order(
        &self,
        request: Request<PlaceOrderRequest>,
    ) -> Result<Response<PlaceOrderResponse>, Status> {
        let response = {
            let mut core = self
                .core
                .lock()
                .map_err(|_| Status::internal("core lock poisoned"))?;
            core.place_order(request.into_inner())
                .map_err(|e| Status::internal(format!("place order: {e}")))?
        };

        {
            let core = self
                .core
                .lock()
                .map_err(|_| Status::internal("core lock poisoned"))?;
            let mut publisher = self
                .publisher
                .lock()
                .map_err(|_| Status::internal("publisher lock poisoned"))?;
            core.publish_pending(&mut *publisher, self.publish_retries)
                .map_err(|e| Status::internal(format!("publish pending: {e}")))?;
        }

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
        Ok(Response::new(response))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let addr: SocketAddr = getenv("CORE_GRPC_ADDR", "0.0.0.0:50051").parse()?;
    let symbol = getenv("CORE_SYMBOL", "BTC-KRW");
    let wal_dir = getenv("CORE_WAL_DIR", "/tmp/trading-core/wal");
    let outbox_dir = getenv("CORE_OUTBOX_DIR", "/tmp/trading-core/outbox");
    let kafka_brokers = getenv("CORE_KAFKA_BROKERS", "localhost:29092");
    let kafka_topic = getenv("CORE_KAFKA_TRADE_TOPIC", "core.trade-events.v1");
    let publish_retries = getenv_usize("CORE_PUBLISH_RETRIES", 3);
    let stub_trades = getenv_bool("CORE_STUB_TRADES", false);

    let mut cfg = CoreConfig::default();
    cfg.symbol = symbol;
    cfg.wal_dir = wal_dir.into();
    cfg.outbox_dir = outbox_dir.into();
    cfg.stub_trades = stub_trades;

    let core = TradingCore::new(cfg, FencingCoordinator::default())?;
    let publisher = KafkaTradePublisher::new(&kafka_brokers, &kafka_topic, Duration::from_secs(2))?;

    let service = CoreGrpcService {
        core: Arc::new(Mutex::new(core)),
        publisher: Arc::new(Mutex::new(publisher)),
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
