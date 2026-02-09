package gateway

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	_ "github.com/lib/pq"
	exchangev1 "github.com/quanta-exchange/exchange-platform/contracts/gen/go/exchange/v1"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const slowConsumerCloseCode = 4001

type contextKey string

const apiKeyContextKey contextKey = "api_key"

// Config keeps runtime settings loaded from env.
type Config struct {
	Addr               string
	DBDsn              string
	DisableDB          bool
	WSQueueSize        int
	APISecrets         map[string]string
	TimestampSkew      time.Duration
	ReplayTTL          time.Duration
	RateLimitPerMinute int
	RedisAddr          string
	RedisPassword      string
	RedisDB            int
	OTelEndpoint       string
	OTelServiceName    string
	OTelSampleRatio    float64
	OTelInsecure       bool
	CoreAddr           string
	CoreTimeout        time.Duration
}

type OrderRequest struct {
	Symbol      string `json:"symbol"`
	Side        string `json:"side"`
	Type        string `json:"type"`
	Price       string `json:"price"`
	Qty         string `json:"qty"`
	TimeInForce string `json:"timeInForce"`
}

type OrderResponse struct {
	OrderID     string `json:"orderId"`
	Status      string `json:"status"`
	Symbol      string `json:"symbol"`
	Seq         uint64 `json:"seq"`
	AcceptedAt  int64  `json:"acceptedAt,omitempty"`
	CanceledAt  int64  `json:"canceledAt,omitempty"`
	RejectCode  string `json:"rejectCode,omitempty"`
	Correlation string `json:"correlationId,omitempty"`
}

type OrderRecord struct {
	OrderID    string `json:"orderId"`
	Status     string `json:"status"`
	Symbol     string `json:"symbol"`
	Seq        uint64 `json:"seq"`
	AcceptedAt int64  `json:"acceptedAt"`
	CanceledAt int64  `json:"canceledAt,omitempty"`
}

type SmokeTradeRequest struct {
	TradeID string `json:"tradeId"`
	Symbol  string `json:"symbol"`
	Price   string `json:"price"`
	Qty     string `json:"qty"`
}

type WSMessage struct {
	Type    string      `json:"type"`
	Channel string      `json:"channel,omitempty"`
	Symbol  string      `json:"symbol"`
	Seq     uint64      `json:"seq"`
	Ts      int64       `json:"ts"`
	Data    interface{} `json:"data"`
}

type tradePoint struct {
	tsMs  int64
	price int64
	qty   int64
}

type WSCommand struct {
	Op      string `json:"op"`
	Channel string `json:"channel"`
	Symbol  string `json:"symbol"`
	LastSeq uint64 `json:"lastSeq,omitempty"`
	Depth   int    `json:"depth,omitempty"`
}

type idempotencyRecord struct {
	status int
	body   []byte
	tsMs   int64
}

type state struct {
	mu sync.Mutex

	nextSeq     uint64
	nextOrderID uint64

	orders             map[string]OrderRecord
	idempotencyResults map[string]idempotencyRecord
	replayCache        map[string]int64
	rateWindow         map[string][]int64
	authFailReason     map[string]uint64

	clients map[*client]struct{}

	historyBySymbol map[string][]WSMessage
	tradeTape       map[string][]tradePoint
	cacheMemory     map[string][]byte

	ordersTotal        uint64
	tradesTotal        uint64
	slowConsumerCloses uint64
	replayDetected     uint64
}

type client struct {
	conn        *websocket.Conn
	send        chan []byte
	mu          sync.Mutex
	conflated   map[string][]byte
	subscribers map[string]struct{}
}

func (c *client) subscribeKey(channel, symbol string) string {
	return channel + ":" + symbol
}

type Server struct {
	cfg           Config
	router        *chi.Mux
	db            *sql.DB
	redis         *redis.Client
	coreConn      *grpc.ClientConn
	coreClient    exchangev1.TradingCoreServiceClient
	state         *state
	upgrader      websocket.Upgrader
	tracer        trace.Tracer
	traceShutdown func(context.Context) error
}

func New(cfg Config) (*Server, error) {
	if cfg.Addr == "" {
		cfg.Addr = ":8080"
	}
	if cfg.DBDsn == "" {
		cfg.DBDsn = "postgres://exchange:exchange@localhost:5432/exchange?sslmode=disable"
	}
	if cfg.WSQueueSize <= 0 {
		cfg.WSQueueSize = 128
	}
	if cfg.TimestampSkew <= 0 {
		cfg.TimestampSkew = 30 * time.Second
	}
	if cfg.ReplayTTL <= 0 {
		cfg.ReplayTTL = 2 * time.Minute
	}
	if cfg.RateLimitPerMinute <= 0 {
		cfg.RateLimitPerMinute = 1_000
	}
	if cfg.OTelServiceName == "" {
		cfg.OTelServiceName = "edge-gateway"
	}
	if cfg.OTelSampleRatio <= 0 {
		cfg.OTelSampleRatio = 1.0
	}
	if cfg.CoreAddr == "" {
		cfg.CoreAddr = "localhost:50051"
	}
	if cfg.CoreTimeout <= 0 {
		cfg.CoreTimeout = 3 * time.Second
	}

	var db *sql.DB
	var err error
	if !cfg.DisableDB {
		db, err = sql.Open("postgres", cfg.DBDsn)
		if err != nil {
			return nil, fmt.Errorf("open db: %w", err)
		}
	}

	var rdb *redis.Client
	if cfg.RedisAddr != "" {
		rdb = redis.NewClient(&redis.Options{
			Addr:     cfg.RedisAddr,
			Password: cfg.RedisPassword,
			DB:       cfg.RedisDB,
		})
	}

	otelTracer, otelShutdown, err := initTracer(cfg)
	if err != nil {
		return nil, err
	}

	coreCtx, cancel := context.WithTimeout(context.Background(), cfg.CoreTimeout)
	defer cancel()
	coreConn, err := grpc.DialContext(
		coreCtx,
		cfg.CoreAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
	)
	if err != nil {
		return nil, fmt.Errorf("dial core: %w", err)
	}

	s := &Server{
		cfg:        cfg,
		db:         db,
		redis:      rdb,
		coreConn:   coreConn,
		coreClient: exchangev1.NewTradingCoreServiceClient(coreConn),
		state: &state{
			nextSeq:            1,
			nextOrderID:        1,
			orders:             map[string]OrderRecord{},
			idempotencyResults: map[string]idempotencyRecord{},
			replayCache:        map[string]int64{},
			rateWindow:         map[string][]int64{},
			authFailReason:     map[string]uint64{},
			clients:            map[*client]struct{}{},
			historyBySymbol:    map[string][]WSMessage{},
			tradeTape:          map[string][]tradePoint{},
			cacheMemory:        map[string][]byte{},
		},
		upgrader:      websocket.Upgrader{CheckOrigin: func(_ *http.Request) bool { return true }},
		tracer:        otelTracer,
		traceShutdown: otelShutdown,
	}

	if s.db != nil {
		if err := s.initSchema(context.Background()); err != nil {
			return nil, err
		}
	}

	r := chi.NewRouter()
	r.Use(s.traceMiddleware)
	r.Get("/healthz", s.handleHealth)
	r.Get("/readyz", s.handleReady)
	r.Get("/metrics", s.handleMetrics)

	r.Get("/v1/markets/{symbol}/trades", s.handleGetTrades)
	r.Get("/v1/markets/{symbol}/orderbook", s.handleGetOrderbook)
	r.Get("/v1/markets/{symbol}/candles", s.handleGetCandles)
	r.Get("/v1/markets/{symbol}/ticker", s.handleGetTicker)

	r.Group(func(protected chi.Router) {
		protected.Use(s.authMiddleware)
		protected.Post("/v1/orders", s.handleCreateOrder)
		protected.Delete("/v1/orders/{orderId}", s.handleCancelOrder)
		protected.Get("/v1/orders/{orderId}", s.handleGetOrder)
		protected.Post("/v1/smoke/trades", s.handleSmokeTrade)
	})

	r.Get("/ws", s.handleWS)
	s.router = r

	return s, nil
}

func (s *Server) Router() http.Handler { return s.router }

func (s *Server) Close() error {
	if s.db != nil {
		_ = s.db.Close()
	}
	if s.redis != nil {
		_ = s.redis.Close()
	}
	if s.coreConn != nil {
		_ = s.coreConn.Close()
	}
	if s.traceShutdown != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = s.traceShutdown(ctx)
	}
	return nil
}

func (s *Server) ListenAndServe() error {
	log.Printf("service=edge-gateway msg=starting addr=%s", s.cfg.Addr)
	return http.ListenAndServe(s.cfg.Addr, s.router)
}

func (s *Server) initSchema(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS smoke_ledger_entries (
			id BIGSERIAL PRIMARY KEY,
			trade_id TEXT NOT NULL UNIQUE,
			symbol TEXT NOT NULL,
			price TEXT NOT NULL,
			qty TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)
	`)
	if err != nil {
		return fmt.Errorf("init schema: %w", err)
	}
	return nil
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"service": "edge-gateway", "status": "ok"})
}

func (s *Server) handleReady(w http.ResponseWriter, _ *http.Request) {
	if s.db != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if err := s.db.PingContext(ctx); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db_unready"})
			return
		}
	}
	if s.redis != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if err := s.redis.Ping(ctx).Err(); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "redis_unready"})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	s.state.mu.Lock()
	orders := s.state.ordersTotal
	trades := s.state.tradesTotal
	clients := len(s.state.clients)
	slowClose := s.state.slowConsumerCloses
	replayDetected := s.state.replayDetected
	authFail := uint64(0)
	for _, c := range s.state.authFailReason {
		authFail += c
	}
	s.state.mu.Unlock()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte("edge_orders_total " + strconv.FormatUint(orders, 10) + "\n"))
	_, _ = w.Write([]byte("edge_trades_total " + strconv.FormatUint(trades, 10) + "\n"))
	_, _ = w.Write([]byte("edge_ws_connections " + strconv.Itoa(clients) + "\n"))
	_, _ = w.Write([]byte("edge_ws_close_slow_consumer_total " + strconv.FormatUint(slowClose, 10) + "\n"))
	_, _ = w.Write([]byte("edge_auth_fail_total " + strconv.FormatUint(authFail, 10) + "\n"))
	_, _ = w.Write([]byte("edge_replay_detect_total " + strconv.FormatUint(replayDetected, 10) + "\n"))
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Local development: if no secrets configured, allow requests.
		if len(s.cfg.APISecrets) == 0 {
			next.ServeHTTP(w, r)
			return
		}

		body, err := readBodyAndRestore(r)
		if err != nil {
			s.authFail("body_read")
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
			return
		}

		apiKey := r.Header.Get("X-API-KEY")
		tsHeader := r.Header.Get("X-TS")
		sig := r.Header.Get("X-SIGNATURE")
		if apiKey == "" || tsHeader == "" || sig == "" {
			s.authFail("missing_header")
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing auth headers"})
			return
		}
		secret, ok := s.cfg.APISecrets[apiKey]
		if !ok {
			s.authFail("unknown_key")
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid api key"})
			return
		}

		tsMs, err := strconv.ParseInt(tsHeader, 10, 64)
		if err != nil {
			s.authFail("invalid_ts")
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid timestamp"})
			return
		}
		now := time.Now().UnixMilli()
		if abs64(now-tsMs) > s.cfg.TimestampSkew.Milliseconds() {
			s.authFail("ts_skew")
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "timestamp skew"})
			return
		}

		if !s.allowRate(apiKey, now) {
			s.authFail("rate_limit")
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "TOO_MANY_REQUESTS"})
			return
		}

		canonical := strings.Join([]string{r.Method, r.URL.Path, tsHeader, string(body)}, "\n")
		expected := sign(secret, canonical)
		if !hmac.Equal([]byte(expected), []byte(sig)) {
			s.authFail("bad_signature")
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid signature"})
			return
		}

		if s.isReplay(apiKey, sig, tsMs, now) {
			s.authFail("replay")
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "replay detected"})
			return
		}

		ctx := context.WithValue(r.Context(), apiKeyContextKey, apiKey)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (s *Server) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	apiKey := s.apiKeyFromContext(r.Context())
	idemKey := r.Header.Get("Idempotency-Key")
	if idemKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Idempotency-Key required"})
		return
	}

	if status, body, ok := s.idempotencyGet(apiKey, idemKey, r.Method, r.URL.Path); ok {
		writeRaw(w, status, body)
		return
	}

	var req OrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if req.Symbol == "" || req.Side == "" || req.Type == "" || req.Qty == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "symbol/side/type/qty required"})
		return
	}
	orderID := fmt.Sprintf("ord_%s", idemKey)
	commandID := uuid.NewString()
	correlationID := uuid.NewString()
	traceID := trace.SpanFromContext(r.Context()).SpanContext().TraceID().String()
	if traceID == "" || traceID == "00000000000000000000000000000000" {
		traceID = uuid.NewString()
	}
	side, ok := mapSide(req.Side)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid side"})
		return
	}
	orderType, ok := mapOrderType(req.Type)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid type"})
		return
	}
	tif, ok := mapTimeInForce(req.TimeInForce)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid timeInForce"})
		return
	}

	coreReq := &exchangev1.PlaceOrderRequest{
		Meta: &exchangev1.CommandMetadata{
			CommandId:      commandID,
			IdempotencyKey: idemKey,
			UserId:         apiKey,
			Symbol:         req.Symbol,
			TsServer:       timestamppb.Now(),
			TraceId:        traceID,
			CorrelationId:  correlationID,
		},
		OrderId:     orderID,
		Side:        side,
		OrderType:   orderType,
		Price:       req.Price,
		Quantity:    req.Qty,
		TimeInForce: tif,
	}

	coreCtx, cancel := context.WithTimeout(r.Context(), s.cfg.CoreTimeout)
	defer cancel()
	coreResp, err := s.coreClient.PlaceOrder(coreCtx, coreReq)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "core_unavailable"})
		return
	}

	acceptedAt := int64(0)
	if coreResp.GetAcceptedAt() != nil {
		acceptedAt = coreResp.AcceptedAt.AsTime().UnixMilli()
	}

	record := OrderRecord{
		OrderID:    coreResp.OrderId,
		Status:     coreResp.Status,
		Symbol:     coreResp.Symbol,
		Seq:        coreResp.Seq,
		AcceptedAt: acceptedAt,
	}
	s.state.mu.Lock()
	s.state.orders[coreResp.OrderId] = record
	s.state.ordersTotal++
	s.state.mu.Unlock()

	resp := OrderResponse{
		OrderID:     coreResp.OrderId,
		Status:      coreResp.Status,
		Symbol:      coreResp.Symbol,
		Seq:         coreResp.Seq,
		AcceptedAt:  acceptedAt,
		RejectCode:  coreResp.RejectCode,
		Correlation: coreResp.CorrelationId,
	}
	status, body := marshalResponse(http.StatusOK, resp)
	s.idempotencySet(apiKey, idemKey, r.Method, r.URL.Path, status, body)
	writeRaw(w, status, body)
}

func (s *Server) handleCancelOrder(w http.ResponseWriter, r *http.Request) {
	apiKey := s.apiKeyFromContext(r.Context())
	idemKey := r.Header.Get("Idempotency-Key")
	if idemKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Idempotency-Key required"})
		return
	}
	orderID := chi.URLParam(r, "orderId")
	pathKey := "/v1/orders/" + orderID

	if status, body, ok := s.idempotencyGet(apiKey, idemKey, r.Method, pathKey); ok {
		writeRaw(w, status, body)
		return
	}

	s.state.mu.Lock()
	record, ok := s.state.orders[orderID]
	if !ok {
		s.state.mu.Unlock()
		status, body := marshalResponse(http.StatusNotFound, map[string]string{"error": "UNKNOWN_ORDER"})
		s.idempotencySet(apiKey, idemKey, r.Method, pathKey, status, body)
		writeRaw(w, status, body)
		return
	}
	seq := s.state.nextSeq
	s.state.nextSeq++
	record.Status = "CANCELED"
	record.Seq = seq
	record.CanceledAt = time.Now().UnixMilli()
	s.state.orders[orderID] = record
	s.state.mu.Unlock()

	resp := OrderResponse{
		OrderID:    record.OrderID,
		Status:     record.Status,
		Symbol:     record.Symbol,
		Seq:        record.Seq,
		CanceledAt: record.CanceledAt,
	}
	status, body := marshalResponse(http.StatusOK, resp)
	s.idempotencySet(apiKey, idemKey, r.Method, pathKey, status, body)
	writeRaw(w, status, body)
}

func (s *Server) handleGetOrder(w http.ResponseWriter, r *http.Request) {
	orderID := chi.URLParam(r, "orderId")
	s.state.mu.Lock()
	record, ok := s.state.orders[orderID]
	s.state.mu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "UNKNOWN_ORDER"})
		return
	}
	writeJSON(w, http.StatusOK, record)
}

func (s *Server) handleSmokeTrade(w http.ResponseWriter, r *http.Request) {
	var req SmokeTradeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if req.TradeID == "" || req.Symbol == "" || req.Price == "" || req.Qty == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "tradeId/symbol/price/qty required"})
		return
	}

	if err := s.appendSettlement(r.Context(), req); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "duplicate trade"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	s.state.mu.Lock()
	seq := s.state.nextSeq
	s.state.nextSeq++
	s.state.tradesTotal++
	s.state.mu.Unlock()

	ts := time.Now().UnixMilli()
	tradeMsg := WSMessage{
		Type:    "TradeExecuted",
		Channel: "trades",
		Symbol:  req.Symbol,
		Seq:     seq,
		Ts:      ts,
		Data: map[string]string{
			"tradeId": req.TradeID,
			"price":   req.Price,
			"qty":     req.Qty,
		},
	}
	candleMsg := WSMessage{
		Type:    "CandleUpdated",
		Channel: "candles",
		Symbol:  req.Symbol,
		Seq:     seq,
		Ts:      ts,
		Data: map[string]interface{}{
			"interval":   "1m",
			"open":       req.Price,
			"high":       req.Price,
			"low":        req.Price,
			"close":      req.Price,
			"volume":     req.Qty,
			"tradeCount": 1,
			"isFinal":    false,
		},
	}
	tickerData := s.recordTicker(req.Symbol, req.Price, req.Qty, ts)
	tickerMsg := WSMessage{
		Type:    "TickerUpdated",
		Channel: "ticker",
		Symbol:  req.Symbol,
		Seq:     seq,
		Ts:      ts,
		Data:    tickerData,
	}

	s.appendHistory(req.Symbol, tradeMsg)
	s.appendHistory(req.Symbol, candleMsg)
	s.appendHistory(req.Symbol, tickerMsg)
	_ = s.cacheSet(r.Context(), cacheKey("trades", req.Symbol), tradeMsg)
	_ = s.cacheSet(r.Context(), cacheKey("candles", req.Symbol), candleMsg)
	_ = s.cacheSet(r.Context(), cacheKey("ticker", req.Symbol), tickerMsg)

	s.broadcast(tradeMsg)
	s.broadcast(candleMsg)
	s.broadcast(tickerMsg)
	writeJSON(w, http.StatusOK, map[string]interface{}{"status": "settled", "seq": seq})
}

func mapSide(value string) (exchangev1.Side, bool) {
	switch strings.ToUpper(value) {
	case "BUY":
		return exchangev1.Side_SIDE_BUY, true
	case "SELL":
		return exchangev1.Side_SIDE_SELL, true
	default:
		return exchangev1.Side_SIDE_UNSPECIFIED, false
	}
}

func mapOrderType(value string) (exchangev1.OrderType, bool) {
	switch strings.ToUpper(value) {
	case "LIMIT":
		return exchangev1.OrderType_ORDER_TYPE_LIMIT, true
	case "MARKET":
		return exchangev1.OrderType_ORDER_TYPE_MARKET, true
	default:
		return exchangev1.OrderType_ORDER_TYPE_UNSPECIFIED, false
	}
}

func mapTimeInForce(value string) (exchangev1.TimeInForce, bool) {
	switch strings.ToUpper(value) {
	case "GTC", "":
		return exchangev1.TimeInForce_TIME_IN_FORCE_GTC, true
	case "IOC":
		return exchangev1.TimeInForce_TIME_IN_FORCE_IOC, true
	case "FOK":
		return exchangev1.TimeInForce_TIME_IN_FORCE_FOK, true
	default:
		return exchangev1.TimeInForce_TIME_IN_FORCE_UNSPECIFIED, false
	}
}

func (s *Server) appendSettlement(ctx context.Context, req SmokeTradeRequest) error {
	if s.db == nil {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO smoke_ledger_entries (trade_id, symbol, price, qty)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (trade_id) DO NOTHING
	`, req.TradeID, req.Symbol, req.Price, req.Qty)
	if err != nil {
		return fmt.Errorf("append settlement: %w", err)
	}
	return nil
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	client := &client{
		conn:        conn,
		send:        make(chan []byte, s.cfg.WSQueueSize),
		conflated:   map[string][]byte{},
		subscribers: map[string]struct{}{},
	}

	s.state.mu.Lock()
	s.state.clients[client] = struct{}{}
	s.state.mu.Unlock()

	go s.wsWriter(client)
	s.wsReader(client)
}

func (s *Server) wsWriter(c *client) {
	defer func() {
		s.state.mu.Lock()
		delete(s.state.clients, c)
		s.state.mu.Unlock()
		_ = c.conn.Close()
	}()

	flushTicker := time.NewTicker(100 * time.Millisecond)
	defer flushTicker.Stop()

	for {
		select {
		case msg, ok := <-c.send:
			if !ok {
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		case <-flushTicker.C:
			var pending [][]byte
			c.mu.Lock()
			for key, payload := range c.conflated {
				pending = append(pending, payload)
				delete(c.conflated, key)
			}
			c.mu.Unlock()
			for _, payload := range pending {
				if err := c.conn.WriteMessage(websocket.TextMessage, payload); err != nil {
					return
				}
			}
		}
	}
}

func (s *Server) wsReader(c *client) {
	defer func() {
		close(c.send)
		_ = c.conn.Close()
	}()

	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		var cmd WSCommand
		if err := json.Unmarshal(raw, &cmd); err != nil {
			s.sendToClient(c, WSMessage{Type: "Error", Symbol: "", Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]string{"error": "invalid command"}}, false)
			continue
		}

		switch strings.ToUpper(cmd.Op) {
		case "SUB":
			if cmd.Channel == "" || cmd.Symbol == "" {
				s.sendToClient(c, WSMessage{Type: "Error", Symbol: "", Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]string{"error": "channel/symbol required"}}, false)
				continue
			}
			c.mu.Lock()
			c.subscribers[c.subscribeKey(cmd.Channel, cmd.Symbol)] = struct{}{}
			c.mu.Unlock()
			s.sendSnapshot(c, cmd.Channel, cmd.Symbol)
		case "UNSUB":
			c.mu.Lock()
			delete(c.subscribers, c.subscribeKey(cmd.Channel, cmd.Symbol))
			c.mu.Unlock()
		case "RESUME":
			s.handleResume(c, cmd.Symbol, cmd.LastSeq)
		default:
			s.sendToClient(c, WSMessage{Type: "Error", Symbol: "", Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]string{"error": "unknown op"}}, false)
		}
	}
}

func (s *Server) handleResume(c *client, symbol string, lastSeq uint64) {
	history := s.history(symbol)
	if len(history) == 0 {
		s.sendSnapshot(c, "trades", symbol)
		s.sendSnapshot(c, "candles", symbol)
		return
	}

	oldest := history[0].Seq
	if lastSeq+1 < oldest {
		s.sendSnapshot(c, "trades", symbol)
		s.sendSnapshot(c, "candles", symbol)
		return
	}
	for _, evt := range history {
		if evt.Seq > lastSeq {
			s.sendToClient(c, evt, conflatable(evt.Channel))
		}
	}
}

func (s *Server) sendSnapshot(c *client, channel, symbol string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	key := cacheKey(channel, symbol)
	if payload, ok := s.cacheGet(ctx, key); ok {
		var msg WSMessage
		if err := json.Unmarshal(payload, &msg); err == nil {
			msg.Type = "Snapshot"
			s.sendToClient(c, msg, conflatable(channel))
			return
		}
	}

	s.sendToClient(c, WSMessage{Type: "Snapshot", Channel: channel, Symbol: symbol, Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]interface{}{}}, conflatable(channel))
}

func (s *Server) broadcast(msg WSMessage) {
	s.state.mu.Lock()
	clients := make([]*client, 0, len(s.state.clients))
	for c := range s.state.clients {
		clients = append(clients, c)
	}
	s.state.mu.Unlock()

	for _, c := range clients {
		key := c.subscribeKey(msg.Channel, msg.Symbol)
		c.mu.Lock()
		_, subscribed := c.subscribers[key]
		c.mu.Unlock()
		if !subscribed {
			continue
		}
		s.sendToClient(c, msg, conflatable(msg.Channel))
	}
}

func (s *Server) sendToClient(c *client, msg WSMessage, conflatableMessage bool) {
	payload, _ := json.Marshal(msg)
	if conflatableMessage {
		c.mu.Lock()
		c.conflated[c.subscribeKey(msg.Channel, msg.Symbol)] = payload
		c.mu.Unlock()
		return
	}

	select {
	case c.send <- payload:
	default:
		s.state.mu.Lock()
		s.state.slowConsumerCloses++
		s.state.mu.Unlock()
		_ = c.conn.WriteControl(websocket.CloseMessage,
			websocket.FormatCloseMessage(slowConsumerCloseCode, "SLOW_CONSUMER"),
			time.Now().Add(1*time.Second),
		)
		close(c.send)
	}
}

func (s *Server) appendHistory(symbol string, msg WSMessage) {
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	const maxHistory = 1024
	h := append(s.state.historyBySymbol[symbol], msg)
	if len(h) > maxHistory {
		h = h[len(h)-maxHistory:]
	}
	s.state.historyBySymbol[symbol] = h
}

func (s *Server) history(symbol string) []WSMessage {
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	h := s.state.historyBySymbol[symbol]
	out := make([]WSMessage, len(h))
	copy(out, h)
	return out
}

func (s *Server) handleGetTrades(w http.ResponseWriter, r *http.Request) {
	symbol := chi.URLParam(r, "symbol")
	limit := parseLimit(r.URL.Query().Get("limit"), 50)
	history := s.history(symbol)
	trades := make([]WSMessage, 0, len(history))
	for _, evt := range history {
		if evt.Channel == "trades" {
			trades = append(trades, evt)
		}
	}
	if len(trades) > limit {
		trades = trades[len(trades)-limit:]
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"symbol": symbol, "trades": trades})
}

func (s *Server) handleGetOrderbook(w http.ResponseWriter, r *http.Request) {
	symbol := chi.URLParam(r, "symbol")
	depth := parseLimit(r.URL.Query().Get("depth"), 20)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"symbol": symbol,
		"depth":  depth,
		"bids":   []interface{}{},
		"asks":   []interface{}{},
	})
}

func (s *Server) handleGetCandles(w http.ResponseWriter, r *http.Request) {
	symbol := chi.URLParam(r, "symbol")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	payload, ok := s.cacheGet(ctx, cacheKey("candles", symbol))
	if !ok {
		writeJSON(w, http.StatusOK, map[string]interface{}{"symbol": symbol, "candles": []interface{}{}})
		return
	}
	var msg WSMessage
	if err := json.Unmarshal(payload, &msg); err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{"symbol": symbol, "candles": []interface{}{}})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"symbol": symbol, "candles": []WSMessage{msg}})
}

func (s *Server) handleGetTicker(w http.ResponseWriter, r *http.Request) {
	symbol := chi.URLParam(r, "symbol")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	payload, ok := s.cacheGet(ctx, cacheKey("ticker", symbol))
	if !ok {
		writeJSON(w, http.StatusOK, map[string]interface{}{"symbol": symbol, "ticker": map[string]interface{}{}})
		return
	}
	var msg WSMessage
	if err := json.Unmarshal(payload, &msg); err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{"symbol": symbol, "ticker": map[string]interface{}{}})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"symbol": symbol, "ticker": msg})
}

func (s *Server) cacheSet(ctx context.Context, key string, value interface{}) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if s.redis != nil {
		if err := s.redis.Set(ctx, key, payload, 10*time.Minute).Err(); err == nil {
			return nil
		}
	}
	s.state.mu.Lock()
	s.state.cacheMemory[key] = payload
	s.state.mu.Unlock()
	return nil
}

func (s *Server) cacheGet(ctx context.Context, key string) ([]byte, bool) {
	if s.redis != nil {
		if v, err := s.redis.Get(ctx, key).Bytes(); err == nil {
			return v, true
		}
	}
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	v, ok := s.state.cacheMemory[key]
	if !ok {
		return nil, false
	}
	cp := make([]byte, len(v))
	copy(cp, v)
	return cp, true
}

func cacheKey(channel, symbol string) string {
	return "snapshot:" + channel + ":" + symbol
}

func conflatable(channel string) bool {
	return channel == "book" || channel == "candles" || channel == "ticker"
}

func (s *Server) idempotencyGet(apiKey, idemKey, method, path string) (int, []byte, bool) {
	k := apiKey + "|" + method + "|" + path + "|" + idemKey
	now := time.Now().UnixMilli()
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	for key, rec := range s.state.idempotencyResults {
		if now-rec.tsMs > 10*60*1000 {
			delete(s.state.idempotencyResults, key)
		}
	}
	rec, ok := s.state.idempotencyResults[k]
	if !ok {
		return 0, nil, false
	}
	cp := make([]byte, len(rec.body))
	copy(cp, rec.body)
	return rec.status, cp, true
}

func (s *Server) idempotencySet(apiKey, idemKey, method, path string, status int, body []byte) {
	k := apiKey + "|" + method + "|" + path + "|" + idemKey
	s.state.mu.Lock()
	s.state.idempotencyResults[k] = idempotencyRecord{status: status, body: body, tsMs: time.Now().UnixMilli()}
	s.state.mu.Unlock()
}

func (s *Server) allowRate(apiKey string, nowMs int64) bool {
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	window := nowMs - 60_000
	series := s.state.rateWindow[apiKey]
	keep := series[:0]
	for _, ts := range series {
		if ts >= window {
			keep = append(keep, ts)
		}
	}
	if len(keep) >= s.cfg.RateLimitPerMinute {
		s.state.rateWindow[apiKey] = keep
		return false
	}
	keep = append(keep, nowMs)
	s.state.rateWindow[apiKey] = keep
	return true
}

func (s *Server) isReplay(apiKey, sig string, tsMs, nowMs int64) bool {
	key := fmt.Sprintf("%s|%s|%d", apiKey, sig, tsMs)
	expireAt := nowMs + s.cfg.ReplayTTL.Milliseconds()

	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	for k, exp := range s.state.replayCache {
		if exp < nowMs {
			delete(s.state.replayCache, k)
		}
	}
	if _, ok := s.state.replayCache[key]; ok {
		s.state.replayDetected++
		return true
	}
	s.state.replayCache[key] = expireAt
	return false
}

func (s *Server) authFail(reason string) {
	s.state.mu.Lock()
	s.state.authFailReason[reason]++
	s.state.mu.Unlock()
}

func (s *Server) apiKeyFromContext(ctx context.Context) string {
	v, _ := ctx.Value(apiKeyContextKey).(string)
	return v
}

func sign(secret, canonical string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(canonical))
	return hex.EncodeToString(mac.Sum(nil))
}

func parseLimit(raw string, fallback int) int {
	if raw == "" {
		return fallback
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return fallback
	}
	if n > 1_000 {
		return 1_000
	}
	return n
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

func (s *Server) recordTicker(symbol, priceRaw, qtyRaw string, tsMs int64) map[string]string {
	price, err := strconv.ParseInt(priceRaw, 10, 64)
	if err != nil {
		price = 0
	}
	qty, err := strconv.ParseInt(qtyRaw, 10, 64)
	if err != nil {
		qty = 0
	}

	const dayMs = int64(24 * 60 * 60 * 1000)
	cutoff := tsMs - dayMs

	s.state.mu.Lock()
	defer s.state.mu.Unlock()

	tape := append(s.state.tradeTape[symbol], tradePoint{
		tsMs:  tsMs,
		price: price,
		qty:   qty,
	})
	filtered := tape[:0]
	for _, item := range tape {
		if item.tsMs >= cutoff {
			filtered = append(filtered, item)
		}
	}
	s.state.tradeTape[symbol] = filtered

	high := int64(0)
	low := int64(0)
	volume := int64(0)
	quoteVolume := int64(0)
	for i, item := range filtered {
		if i == 0 {
			high = item.price
			low = item.price
		} else {
			if item.price > high {
				high = item.price
			}
			if item.price < low {
				low = item.price
			}
		}
		volume += item.qty
		quoteVolume += item.price * item.qty
	}

	return map[string]string{
		"lastPrice":      strconv.FormatInt(price, 10),
		"high24h":        strconv.FormatInt(high, 10),
		"low24h":         strconv.FormatInt(low, 10),
		"volume24h":      strconv.FormatInt(volume, 10),
		"quoteVolume24h": strconv.FormatInt(quoteVolume, 10),
	}
}

func readBodyAndRestore(r *http.Request) ([]byte, error) {
	if r.Body == nil {
		return []byte{}, nil
	}
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, err
	}
	r.Body = io.NopCloser(strings.NewReader(string(raw)))
	return raw, nil
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (w *statusRecorder) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (s *Server) traceMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
		spanName := r.Method + " " + r.URL.Path
		ctx, span := s.tracer.Start(ctx, spanName, trace.WithSpanKind(trace.SpanKindServer))
		defer span.End()

		traceID := span.SpanContext().TraceID().String()
		if r.URL.Path == "/ws" {
			next.ServeHTTP(w, r.WithContext(ctx))
			return
		}

		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		if traceID != "" && traceID != "00000000000000000000000000000000" {
			recorder.Header().Set("X-Trace-Id", traceID)
		}
		next.ServeHTTP(recorder, r.WithContext(ctx))
		span.SetAttributes(
			attribute.String("http.method", r.Method),
			attribute.String("http.target", r.URL.Path),
			attribute.Int("http.status_code", recorder.status),
		)
		if recorder.status >= 500 {
			span.RecordError(fmt.Errorf("http_status_%d", recorder.status))
		}
	})
}

func initTracer(cfg Config) (trace.Tracer, func(context.Context) error, error) {
	if cfg.OTelEndpoint == "" {
		noop := otel.Tracer("exchange/edge-gateway")
		return noop, func(context.Context) error { return nil }, nil
	}

	opts := []otlptracegrpc.Option{
		otlptracegrpc.WithEndpoint(cfg.OTelEndpoint),
	}
	if cfg.OTelInsecure {
		opts = append(opts, otlptracegrpc.WithTLSCredentials(insecure.NewCredentials()))
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	exporter, err := otlptracegrpc.New(ctx, opts...)
	if err != nil {
		return nil, nil, fmt.Errorf("init otel exporter: %w", err)
	}

	res, err := resource.New(
		ctx,
		resource.WithAttributes(
			semconv.ServiceName(cfg.OTelServiceName),
			semconv.DeploymentEnvironment("local"),
		),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("init otel resource: %w", err)
	}

	provider := sdktrace.NewTracerProvider(
		sdktrace.WithSampler(sdktrace.TraceIDRatioBased(cfg.OTelSampleRatio)),
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	return provider.Tracer("exchange/edge-gateway"), provider.Shutdown, nil
}

func marshalResponse(status int, v interface{}) (int, []byte) {
	body, _ := json.Marshal(v)
	return status, body
}

func writeRaw(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	status, body := marshalResponse(status, v)
	writeRaw(w, status, body)
}
