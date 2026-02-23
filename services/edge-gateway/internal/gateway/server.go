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
	"math"
	"net"
	"net/http"
	"regexp"
	"sort"
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
	"github.com/segmentio/kafka-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
	"golang.org/x/crypto/bcrypt"
	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const (
	slowConsumerCloseCode = 4001
	defaultBookDepth      = 20
	defaultCandleInterval = "1m"
	consumerErrorGraceMs  = int64(10_000)
)

var wsSymbolPattern = regexp.MustCompile("^[A-Z0-9]{2,16}-[A-Z0-9]{2,16}$")

type contextKey string

const apiKeyContextKey contextKey = "api_key"

// Config keeps runtime settings loaded from env.
type Config struct {
	Addr                     string
	DBDsn                    string
	DisableDB                bool
	DisableCore              bool
	SeedMarketData           bool
	EnableSmokeRoutes        bool
	AllowInsecureNoAuth      bool
	SessionTTL               time.Duration
	SessionMaxPerUser        int
	WSQueueSize              int
	WSWriteDelay             time.Duration
	WSMaxSubscriptions       int
	WSCommandRateLimit       int
	WSCommandWindow          time.Duration
	WSPingInterval           time.Duration
	WSPongTimeout            time.Duration
	WSReadLimitBytes         int64
	WSAllowedOrigins         []string
	WSMaxConns               int
	WSMaxConnsPerIP          int
	APISecrets               map[string]string
	TimestampSkew            time.Duration
	ReplayTTL                time.Duration
	RateLimitPerMinute       int
	PublicRateLimitPerMinute int
	RedisAddr                string
	RedisPassword            string
	RedisDB                  int
	OTelEndpoint             string
	OTelServiceName          string
	OTelEnvironment          string
	OTelSampleRatio          float64
	OTelInsecure             bool
	CoreAddr                 string
	CoreTimeout              time.Duration
	KafkaBrokers             string
	KafkaTradeTopic          string
	KafkaGroupID             string
	KafkaStartOffset         string
	OrderRetention           time.Duration
	OrderMaxRecords          int
	OrderGCInterval          time.Duration
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

type AuthCredentialsRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type AuthUserResponse struct {
	UserID string `json:"userId"`
	Email  string `json:"email"`
}

type AuthSessionResponse struct {
	User         AuthUserResponse `json:"user"`
	SessionToken string           `json:"sessionToken"`
	ExpiresAt    int64            `json:"expiresAt"`
}

type BalanceView struct {
	Currency  string  `json:"currency"`
	Available float64 `json:"available"`
	Hold      float64 `json:"hold"`
	Total     float64 `json:"total"`
	PriceKRW  float64 `json:"priceKrw,omitempty"`
	ValueKRW  float64 `json:"valueKrw,omitempty"`
}

type OrderRecord struct {
	OrderID    string `json:"orderId"`
	Status     string `json:"status"`
	Symbol     string `json:"symbol"`
	Seq        uint64 `json:"seq"`
	AcceptedAt int64  `json:"acceptedAt"`
	CanceledAt int64  `json:"canceledAt,omitempty"`

	OwnerUserID     string  `json:"-"`
	ReserveCurrency string  `json:"-"`
	ReserveAmount   float64 `json:"-"`
	ReserveConsumed float64 `json:"-"`
	Side            string  `json:"-"`
	Qty             float64 `json:"-"`
	FilledQty       float64 `json:"filledQty,omitempty"`
	TerminalAt      int64   `json:"-"`
}

type tradeEventEnvelope struct {
	EventID       string `json:"eventId"`
	EventVersion  int    `json:"eventVersion"`
	Symbol        string `json:"symbol"`
	Seq           uint64 `json:"seq"`
	OccurredAtRaw string `json:"occurredAt"`
	CorrelationID string `json:"correlationId"`
	CausationID   string `json:"causationId"`
}

type tradeEventPayload struct {
	Envelope     tradeEventEnvelope `json:"envelope"`
	TradeID      string             `json:"tradeId"`
	MakerOrderID string             `json:"makerOrderId"`
	TakerOrderID string             `json:"takerOrderId"`
	BuyerUserID  string             `json:"buyerUserId"`
	SellerUserID string             `json:"sellerUserId"`
	Price        interface{}        `json:"price"`
	Quantity     interface{}        `json:"quantity"`
	QuoteAmount  interface{}        `json:"quoteAmount"`
	Symbol       string             `json:"symbol"`
	Seq          uint64             `json:"seq"`
	TsMs         int64              `json:"ts"`
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
	Op       string `json:"op"`
	Channel  string `json:"channel"`
	Symbol   string `json:"symbol"`
	LastSeq  uint64 `json:"lastSeq,omitempty"`
	Depth    int    `json:"depth,omitempty"`
	Interval string `json:"interval,omitempty"`
}

type idempotencyRecord struct {
	status      int
	body        []byte
	requestHash string
	tsMs        int64
}

type userRecord struct {
	UserID       string
	Email        string
	PasswordHash string
	CreatedAtMs  int64
}

type sessionRecord struct {
	Token       string `json:"token"`
	UserID      string `json:"userId"`
	ExpiresAtMs int64  `json:"expiresAt"`
	IssuedAtMs  int64  `json:"issuedAt,omitempty"`
}

type walletBalance struct {
	Available float64 `json:"available"`
	Hold      float64 `json:"hold"`
}

type state struct {
	mu sync.Mutex

	nextSeq     uint64
	nextOrderID uint64

	orders             map[string]OrderRecord
	idempotencyResults map[string]idempotencyRecord
	replayCache        map[string]int64
	rateWindow         map[string][]int64
	publicRateWindow   map[string][]int64
	authFailReason     map[string]uint64

	clients map[*client]struct{}

	historyBySymbol map[string][]WSMessage
	tradeTape       map[string][]tradePoint
	cacheMemory     map[string][]byte
	usersByEmail    map[string]userRecord
	usersByID       map[string]userRecord
	sessionsMemory  map[string]sessionRecord
	sessionsByUser  map[string][]string
	wallets         map[string]map[string]walletBalance
	appliedTrades   map[string]int64
	applyingTrades  map[string]int64

	ordersTotal             uint64
	tradesTotal             uint64
	slowConsumerCloses      uint64
	wsDroppedMsgs           uint64
	replayDetected          uint64
	publicRateLimited       uint64
	wsPolicyCloses          uint64
	wsRateLimitCloses       uint64
	nextOrderGcAtMs         int64
	wsConnRejects           uint64
	wsConnsByIP             map[string]int
	settlementAnomalies     uint64
	sessionEvictions        uint64
	walletPersistErrors     uint64
	tradeConsumerExpected   bool
	tradeConsumerRunning    bool
	tradeConsumerErrorMs    int64
	tradeConsumerReadErrors uint64
}

type wsSubscription struct {
	channel  string
	symbol   string
	depth    int
	interval string
}

func (s wsSubscription) key() string {
	switch s.channel {
	case "book":
		return fmt.Sprintf("%s:%s:depth=%d", s.channel, s.symbol, s.depth)
	case "candles":
		return fmt.Sprintf("%s:%s:interval=%s", s.channel, s.symbol, s.interval)
	default:
		return s.channel + ":" + s.symbol
	}
}

type client struct {
	conn        *websocket.Conn
	send        chan []byte
	mu          sync.Mutex
	closed      bool
	closeOnce   sync.Once
	conflated   map[string][]byte
	subscribers map[string]wsSubscription
	commandTs   []int64
}

func (c *client) closeSend() {
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closed = true
		c.mu.Unlock()
		close(c.send)
	})
}

func (c *client) enqueue(payload []byte) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return false
	}
	select {
	case c.send <- payload:
		return true
	default:
		return false
	}
}

func (c *client) queueLen() int {
	return len(c.send)
}

func (c *client) setConflated(key string, payload []byte) (replaced bool, accepted bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return false, false
	}
	_, replaced = c.conflated[key]
	c.conflated[key] = payload
	return replaced, true
}

func (c *client) drainConflated() [][]byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	pending := make([][]byte, 0, len(c.conflated))
	for key, payload := range c.conflated {
		pending = append(pending, payload)
		delete(c.conflated, key)
	}
	return pending
}

func (c *client) upsertSubscription(sub wsSubscription, maxSubscriptions int) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return false
	}
	key := sub.key()
	if _, exists := c.subscribers[key]; exists {
		c.subscribers[key] = sub
		return true
	}
	if maxSubscriptions > 0 && len(c.subscribers) >= maxSubscriptions {
		return false
	}
	c.subscribers[key] = sub
	return true
}

func (c *client) removeSubscription(sub wsSubscription) {
	c.mu.Lock()
	delete(c.subscribers, sub.key())
	c.mu.Unlock()
}

func (c *client) matchingSubscriptions(channel, symbol string) []wsSubscription {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]wsSubscription, 0, len(c.subscribers))
	for _, sub := range c.subscribers {
		if sub.channel == channel && sub.symbol == symbol {
			out = append(out, sub)
		}
	}
	return out
}

func (c *client) allowCommand(nowMs int64, maxInWindow int, windowMs int64) bool {
	if maxInWindow <= 0 || windowMs <= 0 {
		return true
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	cutoff := nowMs - windowMs
	filtered := c.commandTs[:0]
	for _, ts := range c.commandTs {
		if ts >= cutoff {
			filtered = append(filtered, ts)
		}
	}
	c.commandTs = filtered
	if len(c.commandTs) >= maxInWindow {
		return false
	}
	c.commandTs = append(c.commandTs, nowMs)
	return true
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
	tradeConsumer *kafka.Reader
	tradeCancel   context.CancelFunc
	tradeWG       sync.WaitGroup
}

func New(cfg Config) (*Server, error) {
	if cfg.Addr == "" {
		cfg.Addr = ":8080"
	}
	if cfg.DBDsn == "" {
		cfg.DBDsn = "postgres://exchange:exchange@localhost:25432/exchange?sslmode=disable"
	}
	if cfg.WSQueueSize <= 0 {
		cfg.WSQueueSize = 128
	}
	if cfg.WSWriteDelay < 0 {
		cfg.WSWriteDelay = 0
	}
	if cfg.WSMaxSubscriptions <= 0 {
		cfg.WSMaxSubscriptions = 64
	}
	if cfg.WSCommandRateLimit <= 0 {
		cfg.WSCommandRateLimit = 240
	}
	if cfg.WSCommandWindow <= 0 {
		cfg.WSCommandWindow = time.Minute
	}
	if cfg.WSPingInterval <= 0 {
		cfg.WSPingInterval = 20 * time.Second
	}
	if cfg.WSPongTimeout <= 0 {
		cfg.WSPongTimeout = 60 * time.Second
	}
	if cfg.WSReadLimitBytes <= 0 {
		cfg.WSReadLimitBytes = 1 << 20
	}
	if cfg.WSMaxConns <= 0 {
		cfg.WSMaxConns = 20_000
	}
	if cfg.WSMaxConnsPerIP <= 0 {
		cfg.WSMaxConnsPerIP = 500
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
	if cfg.PublicRateLimitPerMinute <= 0 {
		cfg.PublicRateLimitPerMinute = 2_000
	}
	if cfg.OTelServiceName == "" {
		cfg.OTelServiceName = "edge-gateway"
	}
	if cfg.OTelSampleRatio <= 0 {
		cfg.OTelSampleRatio = 1.0
	}
	if cfg.SessionTTL <= 0 {
		cfg.SessionTTL = 24 * time.Hour
	}
	if cfg.SessionMaxPerUser <= 0 {
		cfg.SessionMaxPerUser = 8
	}
	if cfg.CoreAddr == "" {
		cfg.CoreAddr = "localhost:50051"
	}
	if cfg.CoreTimeout <= 0 {
		cfg.CoreTimeout = 3 * time.Second
	}
	if cfg.KafkaTradeTopic == "" {
		cfg.KafkaTradeTopic = "core.trade-events.v1"
	}
	if cfg.KafkaGroupID == "" {
		cfg.KafkaGroupID = "edge-trades-v1"
	}
	for key, secret := range cfg.APISecrets {
		if len(strings.TrimSpace(secret)) < 16 {
			return nil, fmt.Errorf("api secret for key %q must be at least 16 characters", key)
		}
	}
	if strings.TrimSpace(cfg.KafkaStartOffset) == "" {
		cfg.KafkaStartOffset = "first"
	}
	if cfg.OrderRetention <= 0 {
		cfg.OrderRetention = 24 * time.Hour
	}
	if cfg.OrderMaxRecords <= 0 {
		cfg.OrderMaxRecords = 100_000
	}
	if cfg.OrderGCInterval <= 0 {
		cfg.OrderGCInterval = 30 * time.Second
	}

	wsAllowedOrigins := map[string]struct{}{}
	for _, origin := range cfg.WSAllowedOrigins {
		normalized := strings.ToLower(strings.TrimSpace(origin))
		if normalized != "" {
			wsAllowedOrigins[normalized] = struct{}{}
		}
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

	var coreConn *grpc.ClientConn
	var coreClient exchangev1.TradingCoreServiceClient
	if !cfg.DisableCore {
		coreCtx, cancel := context.WithTimeout(context.Background(), cfg.CoreTimeout)
		defer cancel()
		coreConn, err = grpc.DialContext(
			coreCtx,
			cfg.CoreAddr,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithBlock(),
		)
		if err != nil {
			return nil, fmt.Errorf("dial core: %w", err)
		}
		coreClient = exchangev1.NewTradingCoreServiceClient(coreConn)
	}

	s := &Server{
		cfg:        cfg,
		db:         db,
		redis:      rdb,
		coreConn:   coreConn,
		coreClient: coreClient,
		state: &state{
			nextSeq:            1,
			nextOrderID:        1,
			orders:             map[string]OrderRecord{},
			idempotencyResults: map[string]idempotencyRecord{},
			replayCache:        map[string]int64{},
			rateWindow:         map[string][]int64{},
			publicRateWindow:   map[string][]int64{},
			authFailReason:     map[string]uint64{},
			clients:            map[*client]struct{}{},
			wsConnsByIP:        map[string]int{},
			historyBySymbol:    map[string][]WSMessage{},
			tradeTape:          map[string][]tradePoint{},
			cacheMemory:        map[string][]byte{},
			usersByEmail:       map[string]userRecord{},
			usersByID:          map[string]userRecord{},
			sessionsMemory:     map[string]sessionRecord{},
			sessionsByUser:     map[string][]string{},
			wallets:            map[string]map[string]walletBalance{},
			appliedTrades:      map[string]int64{},
			applyingTrades:     map[string]int64{},
		},
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool {
				return originAllowed(wsAllowedOrigins, r.Header.Get("Origin"))
			},
		},
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

	r.Group(func(market chi.Router) {
		market.Use(s.publicRateMiddleware)
		market.Get("/v1/markets/{symbol}/trades", s.handleGetTrades)
		market.Get("/v1/markets/{symbol}/orderbook", s.handleGetOrderbook)
		market.Get("/v1/markets/{symbol}/candles", s.handleGetCandles)
		market.Get("/v1/markets/{symbol}/ticker", s.handleGetTicker)
	})
	r.Post("/v1/auth/signup", s.handleSignUp)
	r.Post("/v1/auth/login", s.handleLogin)

	r.Group(func(session chi.Router) {
		session.Use(s.sessionMiddleware)
		session.Get("/v1/auth/me", s.handleMe)
		session.Post("/v1/auth/logout", s.handleLogout)
		session.Get("/v1/account/balances", s.handleGetBalances)
		session.Get("/v1/account/portfolio", s.handleGetPortfolio)
	})

	r.Group(func(protected chi.Router) {
		protected.Use(s.authMiddleware)
		protected.Post("/v1/orders", s.handleCreateOrder)
		protected.Delete("/v1/orders/{orderId}", s.handleCancelOrder)
		protected.Get("/v1/orders/{orderId}", s.handleGetOrder)
		protected.Post("/v1/smoke/trades", s.handleSmokeTrade)
	})

	r.Get("/ws", s.handleWS)
	s.router = r

	if cfg.SeedMarketData {
		if err := s.seedSampleMarketData(context.Background()); err != nil {
			return nil, fmt.Errorf("seed sample market data: %w", err)
		}
	}

	s.startTradeConsumer()

	return s, nil
}

func (s *Server) Router() http.Handler { return s.router }

func (s *Server) Close() error {
	if s.tradeCancel != nil {
		s.tradeCancel()
	}
	if s.tradeConsumer != nil {
		_ = s.tradeConsumer.Close()
	}
	s.tradeWG.Wait()
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
	return s.httpServer().ListenAndServe()
}

func (s *Server) httpServer() *http.Server {
	return &http.Server{
		Addr:              s.cfg.Addr,
		Handler:           s.router,
		ReadTimeout:       10 * time.Second,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
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

	_, err = s.db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS web_users (
			user_id TEXT PRIMARY KEY,
			email TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)
	`)
	if err != nil {
		return fmt.Errorf("init users schema: %w", err)
	}

	_, err = s.db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS web_wallet_balances (
			user_id TEXT NOT NULL,
			currency TEXT NOT NULL,
			available DOUBLE PRECISION NOT NULL DEFAULT 0,
			hold DOUBLE PRECISION NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
			PRIMARY KEY (user_id, currency)
		)
	`)
	if err != nil {
		return fmt.Errorf("init wallet schema: %w", err)
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
	if !s.coreReady() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "core_unready"})
		return
	}
	if !s.tradeConsumerReady() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "trade_consumer_unready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) coreReady() bool {
	if s.cfg.DisableCore {
		return true
	}
	if s.coreConn == nil {
		return false
	}
	s.coreConn.Connect()
	state := s.coreConn.GetState()
	if state == connectivity.Ready {
		return true
	}
	if state == connectivity.Shutdown || state == connectivity.TransientFailure {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	if !s.coreConn.WaitForStateChange(ctx, state) {
		return s.coreConn.GetState() == connectivity.Ready
	}
	state = s.coreConn.GetState()
	return state == connectivity.Ready || state == connectivity.Idle
}

func (s *Server) tradeConsumerReady() bool {
	if strings.TrimSpace(s.cfg.KafkaBrokers) == "" {
		return true
	}
	now := time.Now().UnixMilli()
	s.state.mu.Lock()
	expected := s.state.tradeConsumerExpected
	running := s.state.tradeConsumerRunning
	lastErrorMs := s.state.tradeConsumerErrorMs
	s.state.mu.Unlock()
	if !expected {
		return false
	}
	if !running {
		return false
	}
	if lastErrorMs > 0 && now-lastErrorMs <= consumerErrorGraceMs {
		return false
	}
	return true
}

func (s *Server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	s.state.mu.Lock()
	orders := s.state.ordersTotal
	trades := s.state.tradesTotal
	clients := len(s.state.clients)
	slowClose := s.state.slowConsumerCloses
	policyClose := s.state.wsPolicyCloses
	wsRateLimitCloses := s.state.wsRateLimitCloses
	wsConnRejects := s.state.wsConnRejects
	droppedMsgs := s.state.wsDroppedMsgs
	replayDetected := s.state.replayDetected
	publicRateLimited := s.state.publicRateLimited
	settlementAnomalies := s.state.settlementAnomalies
	sessionEvictions := s.state.sessionEvictions
	walletPersistErrors := s.state.walletPersistErrors
	tradeConsumerRunning := s.state.tradeConsumerRunning
	tradeConsumerErrors := s.state.tradeConsumerReadErrors
	queueLens := make([]int, 0, len(s.state.clients))
	for c := range s.state.clients {
		queueLens = append(queueLens, c.queueLen())
	}
	authFail := uint64(0)
	authFailByReason := make(map[string]uint64, len(s.state.authFailReason))
	for _, c := range s.state.authFailReason {
		authFail += c
	}
	for reason, count := range s.state.authFailReason {
		authFailByReason[reason] = count
	}
	s.state.mu.Unlock()
	queueP99 := p99(queueLens)
	reasons := make([]string, 0, len(authFailByReason))
	for reason := range authFailByReason {
		reasons = append(reasons, reason)
	}
	sort.Strings(reasons)

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte("edge_orders_total " + strconv.FormatUint(orders, 10) + "\n"))
	_, _ = w.Write([]byte("edge_trades_total " + strconv.FormatUint(trades, 10) + "\n"))
	_, _ = w.Write([]byte("edge_ws_connections " + strconv.Itoa(clients) + "\n"))
	_, _ = w.Write([]byte("edge_ws_close_slow_consumer_total " + strconv.FormatUint(slowClose, 10) + "\n"))
	_, _ = w.Write([]byte("edge_ws_close_policy_total " + strconv.FormatUint(policyClose, 10) + "\n"))
	_, _ = w.Write([]byte("edge_ws_close_ratelimit_total " + strconv.FormatUint(wsRateLimitCloses, 10) + "\n"))
	_, _ = w.Write([]byte("edge_ws_connection_reject_total " + strconv.FormatUint(wsConnRejects, 10) + "\n"))
	_, _ = w.Write([]byte("edge_public_rate_limited_total " + strconv.FormatUint(publicRateLimited, 10) + "\n"))
	_, _ = w.Write([]byte("edge_settlement_anomaly_total " + strconv.FormatUint(settlementAnomalies, 10) + "\n"))
	_, _ = w.Write([]byte("edge_session_eviction_total " + strconv.FormatUint(sessionEvictions, 10) + "\n"))
	_, _ = w.Write([]byte("edge_wallet_persist_error_total " + strconv.FormatUint(walletPersistErrors, 10) + "\n"))
	if tradeConsumerRunning {
		_, _ = w.Write([]byte("edge_trade_consumer_running 1\n"))
	} else {
		_, _ = w.Write([]byte("edge_trade_consumer_running 0\n"))
	}
	_, _ = w.Write([]byte("edge_trade_consumer_read_error_total " + strconv.FormatUint(tradeConsumerErrors, 10) + "\n"))
	_, _ = w.Write([]byte("edge_auth_fail_total " + strconv.FormatUint(authFail, 10) + "\n"))
	for _, reason := range reasons {
		line := fmt.Sprintf(
			"edge_auth_fail_reason_total{reason=\"%s\"} %d\n",
			prometheusLabelEscape(reason),
			authFailByReason[reason],
		)
		_, _ = w.Write([]byte(line))
	}
	_, _ = w.Write([]byte("edge_replay_detect_total " + strconv.FormatUint(replayDetected, 10) + "\n"))
	_, _ = w.Write([]byte("ws_active_conns " + strconv.Itoa(clients) + "\n"))
	_, _ = w.Write([]byte("ws_send_queue_p99 " + strconv.Itoa(queueP99) + "\n"))
	_, _ = w.Write([]byte("ws_dropped_msgs " + strconv.FormatUint(droppedMsgs, 10) + "\n"))
	_, _ = w.Write([]byte("ws_slow_closes " + strconv.FormatUint(slowClose, 10) + "\n"))
	_, _ = w.Write([]byte("ws_policy_closes " + strconv.FormatUint(policyClose, 10) + "\n"))
	_, _ = w.Write([]byte("ws_command_rate_limit_closes " + strconv.FormatUint(wsRateLimitCloses, 10) + "\n"))
	_, _ = w.Write([]byte("ws_connection_rejects " + strconv.FormatUint(wsConnRejects, 10) + "\n"))
	_, _ = w.Write([]byte("public_rate_limited " + strconv.FormatUint(publicRateLimited, 10) + "\n"))
	_, _ = w.Write([]byte("settlement_anomalies " + strconv.FormatUint(settlementAnomalies, 10) + "\n"))
	_, _ = w.Write([]byte("session_evictions " + strconv.FormatUint(sessionEvictions, 10) + "\n"))
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if token, ok := bearerToken(r); ok {
			session, valid := s.getSession(r.Context(), token)
			if !valid {
				s.authFail("invalid_session")
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid session"})
				return
			}
			ctx := context.WithValue(r.Context(), apiKeyContextKey, session.UserID)
			next.ServeHTTP(w, r.WithContext(ctx))
			return
		}

		// Local testing-only mode: explicitly allow unsigned requests when configured.
		if len(s.cfg.APISecrets) == 0 {
			if s.cfg.AllowInsecureNoAuth {
				next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), apiKeyContextKey, "")))
				return
			}
			s.authFail("auth_not_configured")
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "auth_not_configured"})
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
			unknownKeyRateBucket := "unknown_key:" + wsClientIP(r.RemoteAddr)
			nowMs := time.Now().UnixMilli()
			if !s.allowRate(unknownKeyRateBucket, nowMs) {
				s.authFail("unknown_key_rate_limit")
				writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "TOO_MANY_REQUESTS"})
				return
			}
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

func (s *Server) publicRateMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		client := wsClientIP(r.RemoteAddr)
		if !s.allowPublicRate(client, time.Now().UnixMilli()) {
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "TOO_MANY_REQUESTS"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) sessionMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Authorization Bearer token required"})
			return
		}
		session, valid := s.getSession(r.Context(), token)
		if !valid {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid session"})
			return
		}
		ctx := context.WithValue(r.Context(), apiKeyContextKey, session.UserID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (s *Server) handleSignUp(w http.ResponseWriter, r *http.Request) {
	var req AuthCredentialsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	email := normalizeEmail(req.Email)
	if !isValidEmail(email) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid email"})
		return
	}
	if len(strings.TrimSpace(req.Password)) < 8 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "password must be at least 8 characters"})
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to hash password"})
		return
	}

	user, err := s.createUser(r.Context(), email, string(hash))
	if err != nil {
		if strings.Contains(err.Error(), "already_exists") {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "email already exists"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	session, err := s.createSession(r.Context(), user)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, AuthSessionResponse{
		User: AuthUserResponse{
			UserID: user.UserID,
			Email:  user.Email,
		},
		SessionToken: session.Token,
		ExpiresAt:    session.ExpiresAtMs,
	})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req AuthCredentialsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	email := normalizeEmail(req.Email)
	if !isValidEmail(email) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid email"})
		return
	}

	user, ok, err := s.getUserByEmail(r.Context(), email)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "auth_store_unavailable"})
		return
	}
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}

	session, err := s.createSession(r.Context(), user)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, AuthSessionResponse{
		User: AuthUserResponse{
			UserID: user.UserID,
			Email:  user.Email,
		},
		SessionToken: session.Token,
		ExpiresAt:    session.ExpiresAtMs,
	})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	userID := s.apiKeyFromContext(r.Context())
	if userID == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	user, ok, err := s.getUserByID(r.Context(), userID)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "profile_unavailable"})
		return
	}
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "user_not_found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"user": AuthUserResponse{
			UserID: user.UserID,
			Email:  user.Email,
		},
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	token, ok := bearerToken(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Authorization Bearer token required"})
		return
	}
	s.deleteSession(r.Context(), token)
	writeJSON(w, http.StatusOK, map[string]string{"status": "logged_out"})
}

func (s *Server) handleGetBalances(w http.ResponseWriter, r *http.Request) {
	userID := s.apiKeyFromContext(r.Context())
	if userID == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	balances := s.snapshotWallet(userID)
	out := make([]BalanceView, 0, len(balances))
	for currency, bal := range balances {
		total := bal.Available + bal.Hold
		out = append(out, BalanceView{
			Currency:  currency,
			Available: bal.Available,
			Hold:      bal.Hold,
			Total:     total,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Currency < out[j].Currency })
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"userId":   userID,
		"balances": out,
	})
}

func (s *Server) handleGetPortfolio(w http.ResponseWriter, r *http.Request) {
	userID := s.apiKeyFromContext(r.Context())
	if userID == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	balances := s.snapshotWallet(userID)
	assets := make([]BalanceView, 0, len(balances))
	totalValue := 0.0
	for currency, bal := range balances {
		total := bal.Available + bal.Hold
		price := 1.0
		if currency != "KRW" {
			if latest, ok := s.latestPriceKRW(currency); ok && latest > 0 {
				price = latest
			} else {
				price = 0
			}
		}
		value := total * price
		totalValue += value
		assets = append(assets, BalanceView{
			Currency:  currency,
			Available: bal.Available,
			Hold:      bal.Hold,
			Total:     total,
			PriceKRW:  price,
			ValueKRW:  value,
		})
	}
	sort.Slice(assets, func(i, j int) bool { return assets[i].ValueKRW > assets[j].ValueKRW })
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"userId":          userID,
		"assets":          assets,
		"totalAssetValue": totalValue,
		"updatedAt":       time.Now().UnixMilli(),
	})
}

func (s *Server) createUser(ctx context.Context, email, passwordHash string) (userRecord, error) {
	if existing, ok, err := s.getUserByEmail(ctx, email); err != nil {
		return userRecord{}, fmt.Errorf("lookup user: %w", err)
	} else if ok {
		return existing, fmt.Errorf("already_exists")
	}

	user := userRecord{
		UserID:       "usr_" + uuid.NewString(),
		Email:        email,
		PasswordHash: passwordHash,
		CreatedAtMs:  time.Now().UnixMilli(),
	}
	defaults := defaultWalletBalances()

	if s.db != nil {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return userRecord{}, fmt.Errorf("begin tx: %w", err)
		}
		committed := false
		defer func() {
			if !committed {
				_ = tx.Rollback()
			}
		}()

		_, err = tx.ExecContext(
			ctx,
			`INSERT INTO web_users(user_id, email, password_hash, created_at) VALUES ($1, $2, $3, to_timestamp($4 / 1000.0))`,
			user.UserID,
			user.Email,
			user.PasswordHash,
			user.CreatedAtMs,
		)
		if err != nil {
			if strings.Contains(strings.ToLower(err.Error()), "duplicate") {
				return userRecord{}, fmt.Errorf("already_exists")
			}
			return userRecord{}, fmt.Errorf("insert user: %w", err)
		}

		for currency, bal := range defaults {
			_, err = tx.ExecContext(
				ctx,
				`INSERT INTO web_wallet_balances(user_id, currency, available, hold) VALUES ($1, $2, $3, $4)
				 ON CONFLICT (user_id, currency) DO UPDATE SET
				 available = EXCLUDED.available,
				 hold = EXCLUDED.hold,
				 updated_at = now()`,
				user.UserID,
				currency,
				bal.Available,
				bal.Hold,
			)
			if err != nil {
				return userRecord{}, fmt.Errorf("insert wallet: %w", err)
			}
		}

		if err := tx.Commit(); err != nil {
			return userRecord{}, fmt.Errorf("commit tx: %w", err)
		}
		committed = true
	}

	s.state.mu.Lock()
	s.state.usersByEmail[user.Email] = user
	s.state.usersByID[user.UserID] = user
	s.state.wallets[user.UserID] = defaults
	s.state.mu.Unlock()

	return user, nil
}

func (s *Server) getUserByEmail(ctx context.Context, email string) (userRecord, bool, error) {
	s.state.mu.Lock()
	if user, ok := s.state.usersByEmail[email]; ok {
		s.state.mu.Unlock()
		return user, true, nil
	}
	s.state.mu.Unlock()

	if s.db == nil {
		return userRecord{}, false, nil
	}

	var user userRecord
	var createdAt time.Time
	err := s.db.QueryRowContext(
		ctx,
		`SELECT user_id, email, password_hash, created_at FROM web_users WHERE email = $1`,
		email,
	).Scan(&user.UserID, &user.Email, &user.PasswordHash, &createdAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return userRecord{}, false, nil
		}
		return userRecord{}, false, fmt.Errorf("query user by email: %w", err)
	}
	user.CreatedAtMs = createdAt.UnixMilli()

	wallet := s.loadWalletFromDB(ctx, user.UserID)

	s.state.mu.Lock()
	s.state.usersByEmail[user.Email] = user
	s.state.usersByID[user.UserID] = user
	if _, ok := s.state.wallets[user.UserID]; !ok {
		s.state.wallets[user.UserID] = wallet
	}
	s.state.mu.Unlock()
	return user, true, nil
}

func (s *Server) getUserByID(ctx context.Context, userID string) (userRecord, bool, error) {
	s.state.mu.Lock()
	if user, ok := s.state.usersByID[userID]; ok {
		s.state.mu.Unlock()
		return user, true, nil
	}
	s.state.mu.Unlock()

	if s.db == nil {
		return userRecord{}, false, nil
	}

	var user userRecord
	var createdAt time.Time
	err := s.db.QueryRowContext(
		ctx,
		`SELECT user_id, email, password_hash, created_at FROM web_users WHERE user_id = $1`,
		userID,
	).Scan(&user.UserID, &user.Email, &user.PasswordHash, &createdAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return userRecord{}, false, nil
		}
		return userRecord{}, false, fmt.Errorf("query user by id: %w", err)
	}
	user.CreatedAtMs = createdAt.UnixMilli()

	wallet := s.loadWalletFromDB(ctx, user.UserID)

	s.state.mu.Lock()
	s.state.usersByEmail[user.Email] = user
	s.state.usersByID[user.UserID] = user
	if _, ok := s.state.wallets[user.UserID]; !ok {
		s.state.wallets[user.UserID] = wallet
	}
	s.state.mu.Unlock()
	return user, true, nil
}

func (s *Server) createSession(ctx context.Context, user userRecord) (sessionRecord, error) {
	nowMs := time.Now().UnixMilli()
	token := uuid.NewString() + uuid.NewString()
	session := sessionRecord{
		Token:       token,
		UserID:      user.UserID,
		ExpiresAtMs: nowMs + s.cfg.SessionTTL.Milliseconds(),
		IssuedAtMs:  nowMs,
	}

	if s.redis != nil {
		raw, err := json.Marshal(session)
		if err != nil {
			return sessionRecord{}, fmt.Errorf("marshal session: %w", err)
		}
		if err := s.redis.Set(ctx, sessionKey(token), raw, s.cfg.SessionTTL).Err(); err != nil {
			return sessionRecord{}, fmt.Errorf("persist session: %w", err)
		}
	}

	evicted := make([]string, 0)
	s.state.mu.Lock()
	s.state.sessionsMemory[token] = session
	userSessions := append(s.state.sessionsByUser[user.UserID], token)
	if s.cfg.SessionMaxPerUser > 0 && len(userSessions) > s.cfg.SessionMaxPerUser {
		overflow := len(userSessions) - s.cfg.SessionMaxPerUser
		evicted = append(evicted, userSessions[:overflow]...)
		userSessions = append([]string(nil), userSessions[overflow:]...)
		for _, oldToken := range evicted {
			delete(s.state.sessionsMemory, oldToken)
			s.state.sessionEvictions++
		}
	}
	s.state.sessionsByUser[user.UserID] = userSessions
	s.state.mu.Unlock()

	if s.redis != nil {
		for _, oldToken := range evicted {
			_ = s.redis.Del(ctx, sessionKey(oldToken)).Err()
		}
	}
	return session, nil
}

func (s *Server) getSession(ctx context.Context, token string) (sessionRecord, bool) {
	now := time.Now().UnixMilli()
	if s.redis != nil {
		raw, err := s.redis.Get(ctx, sessionKey(token)).Bytes()
		if err == nil {
			var session sessionRecord
			if err := json.Unmarshal(raw, &session); err == nil && session.ExpiresAtMs > now {
				return session, true
			}
			_ = s.redis.Del(ctx, sessionKey(token)).Err()
		}
	}

	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	session, ok := s.state.sessionsMemory[token]
	if !ok {
		return sessionRecord{}, false
	}
	if session.ExpiresAtMs <= now {
		delete(s.state.sessionsMemory, token)
		s.removeUserSessionTokenLocked(session.UserID, token)
		return sessionRecord{}, false
	}
	return session, true
}

func (s *Server) deleteSession(ctx context.Context, token string) {
	userID := ""
	s.state.mu.Lock()
	if session, ok := s.state.sessionsMemory[token]; ok {
		userID = session.UserID
	}
	delete(s.state.sessionsMemory, token)
	if userID != "" {
		s.removeUserSessionTokenLocked(userID, token)
	}
	s.state.mu.Unlock()

	if s.redis != nil {
		_ = s.redis.Del(ctx, sessionKey(token)).Err()
	}
}

func (s *Server) removeUserSessionTokenLocked(userID, token string) {
	if strings.TrimSpace(userID) == "" {
		return
	}
	sessions := s.state.sessionsByUser[userID]
	if len(sessions) == 0 {
		return
	}
	filtered := sessions[:0]
	for _, existing := range sessions {
		if existing != token {
			filtered = append(filtered, existing)
		}
	}
	if len(filtered) == 0 {
		delete(s.state.sessionsByUser, userID)
		return
	}
	s.state.sessionsByUser[userID] = append([]string(nil), filtered...)
}

func (s *Server) snapshotWallet(userID string) map[string]walletBalance {
	s.state.mu.Lock()
	wallet, ok := s.state.wallets[userID]
	s.state.mu.Unlock()
	if !ok {
		if s.db != nil {
			wallet = s.loadWalletFromDB(context.Background(), userID)
		}
		if len(wallet) == 0 {
			wallet = defaultWalletBalances()
		}
		s.state.mu.Lock()
		s.state.wallets[userID] = cloneWallet(wallet)
		s.state.mu.Unlock()
	}
	return cloneWallet(wallet)
}

func (s *Server) applyReserve(userID string, currency string, amount float64) (walletBalance, error) {
	if amount <= 0 {
		return walletBalance{}, fmt.Errorf("amount must be > 0")
	}
	if math.IsNaN(amount) || math.IsInf(amount, 0) {
		return walletBalance{}, fmt.Errorf("amount must be finite")
	}
	currency = strings.ToUpper(strings.TrimSpace(currency))

	s.state.mu.Lock()
	originalWallet, existed := s.state.wallets[userID]
	var previous map[string]walletBalance
	var wallet map[string]walletBalance
	if existed {
		previous = cloneWallet(originalWallet)
		wallet = cloneWallet(originalWallet)
	} else {
		wallet = defaultWalletBalances()
	}
	current := wallet[currency]
	if current.Available+1e-9 < amount {
		s.state.mu.Unlock()
		return walletBalance{}, fmt.Errorf("insufficient_balance")
	}
	current.Available -= amount
	current.Hold += amount
	wallet[currency] = current
	s.state.wallets[userID] = wallet
	s.state.mu.Unlock()

	if err := s.persistWalletBalance(context.Background(), userID, currency, current); err != nil {
		s.state.mu.Lock()
		if existed {
			s.state.wallets[userID] = previous
		} else {
			delete(s.state.wallets, userID)
		}
		s.state.walletPersistErrors++
		s.state.mu.Unlock()
		return walletBalance{}, err
	}
	return current, nil
}

func (s *Server) releaseReserve(userID, currency string, amount float64) (walletBalance, error) {
	if amount <= 0 {
		return walletBalance{}, nil
	}
	if math.IsNaN(amount) || math.IsInf(amount, 0) {
		return walletBalance{}, fmt.Errorf("amount must be finite")
	}
	currency = strings.ToUpper(strings.TrimSpace(currency))
	s.state.mu.Lock()
	originalWallet, existed := s.state.wallets[userID]
	var previous map[string]walletBalance
	var wallet map[string]walletBalance
	if existed {
		previous = cloneWallet(originalWallet)
		wallet = cloneWallet(originalWallet)
	} else {
		wallet = defaultWalletBalances()
	}
	current := wallet[currency]
	if current.Hold >= amount {
		current.Hold -= amount
		current.Available += amount
	} else {
		current.Available += current.Hold
		current.Hold = 0
	}
	wallet[currency] = current
	s.state.wallets[userID] = wallet
	s.state.mu.Unlock()

	if err := s.persistWalletBalance(context.Background(), userID, currency, current); err != nil {
		s.state.mu.Lock()
		if existed {
			s.state.wallets[userID] = previous
		} else {
			delete(s.state.wallets, userID)
		}
		s.state.walletPersistErrors++
		s.state.mu.Unlock()
		return walletBalance{}, err
	}
	return current, nil
}

func (s *Server) tryReserveForOrder(userID string, req OrderRequest) (string, float64, error) {
	base, quote, ok := parseSymbol(req.Symbol)
	if !ok {
		return "", 0, fmt.Errorf("invalid symbol")
	}

	qty, err := strconv.ParseFloat(strings.TrimSpace(req.Qty), 64)
	if err != nil || qty <= 0 || math.IsNaN(qty) || math.IsInf(qty, 0) {
		return "", 0, fmt.Errorf("invalid qty")
	}

	switch strings.ToUpper(req.Side) {
	case "BUY":
		price := 0.0
		if strings.ToUpper(req.Type) == "MARKET" {
			if latest, found := s.latestPriceKRW(base); found {
				price = latest
			}
		} else {
			price, err = strconv.ParseFloat(strings.TrimSpace(req.Price), 64)
			if err != nil || price <= 0 || math.IsNaN(price) || math.IsInf(price, 0) {
				return "", 0, fmt.Errorf("invalid price")
			}
		}
		if price <= 0 {
			return "", 0, fmt.Errorf("price_unavailable")
		}
		amount := qty * price
		if _, err := s.applyReserve(userID, quote, amount); err != nil {
			return "", 0, err
		}
		return quote, amount, nil
	case "SELL":
		if _, err := s.applyReserve(userID, base, qty); err != nil {
			return "", 0, err
		}
		return base, qty, nil
	default:
		return "", 0, fmt.Errorf("invalid side")
	}
}

func (s *Server) latestPriceKRW(base string) (float64, bool) {
	symbol := strings.ToUpper(strings.TrimSpace(base)) + "-KRW"
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	tape := s.state.tradeTape[symbol]
	if len(tape) == 0 {
		return 0, false
	}
	return float64(tape[len(tape)-1].price), true
}

func (s *Server) loadWalletFromDB(ctx context.Context, userID string) map[string]walletBalance {
	if s.db == nil {
		return map[string]walletBalance{}
	}
	rows, err := s.db.QueryContext(
		ctx,
		`SELECT currency, available, hold FROM web_wallet_balances WHERE user_id = $1`,
		userID,
	)
	if err != nil {
		return map[string]walletBalance{}
	}
	defer rows.Close()

	out := map[string]walletBalance{}
	for rows.Next() {
		var currency string
		var available float64
		var hold float64
		if err := rows.Scan(&currency, &available, &hold); err != nil {
			continue
		}
		out[strings.ToUpper(currency)] = walletBalance{
			Available: available,
			Hold:      hold,
		}
	}
	if len(out) == 0 {
		return defaultWalletBalances()
	}
	return out
}

func (s *Server) persistWalletBalance(ctx context.Context, userID, currency string, bal walletBalance) error {
	if s.db == nil {
		return nil
	}
	_, err := s.db.ExecContext(
		ctx,
		`INSERT INTO web_wallet_balances(user_id, currency, available, hold) VALUES ($1, $2, $3, $4)
		 ON CONFLICT (user_id, currency) DO UPDATE SET
		 available = EXCLUDED.available,
		 hold = EXCLUDED.hold,
		 updated_at = now()`,
		userID,
		strings.ToUpper(currency),
		bal.Available,
		bal.Hold,
	)
	if err != nil {
		return fmt.Errorf("persist wallet balance: %w", err)
	}
	return nil
}

func defaultWalletBalances() map[string]walletBalance {
	return map[string]walletBalance{
		"KRW": {Available: 50_000_000, Hold: 0},
		"BTC": {Available: 2, Hold: 0},
		"ETH": {Available: 8, Hold: 0},
		"SOL": {Available: 240, Hold: 0},
		"XRP": {Available: 15000, Hold: 0},
		"BNB": {Available: 34, Hold: 0},
	}
}

func cloneWallet(in map[string]walletBalance) map[string]walletBalance {
	out := make(map[string]walletBalance, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func parseSymbol(symbol string) (string, string, bool) {
	parts := strings.Split(strings.TrimSpace(symbol), "-")
	if len(parts) != 2 {
		return "", "", false
	}
	base := strings.ToUpper(strings.TrimSpace(parts[0]))
	quote := strings.ToUpper(strings.TrimSpace(parts[1]))
	if base == "" || quote == "" {
		return "", "", false
	}
	return base, quote, true
}

func normalizeEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

func isValidEmail(email string) bool {
	if len(email) < 5 {
		return false
	}
	at := strings.Index(email, "@")
	dot := strings.LastIndex(email, ".")
	return at > 0 && dot > at+1 && dot < len(email)-1
}

func bearerToken(r *http.Request) (string, bool) {
	raw := strings.TrimSpace(r.Header.Get("Authorization"))
	if raw == "" {
		return "", false
	}
	parts := strings.SplitN(raw, " ", 2)
	if len(parts) != 2 {
		return "", false
	}
	if !strings.EqualFold(parts[0], "Bearer") {
		return "", false
	}
	token := strings.TrimSpace(parts[1])
	if token == "" {
		return "", false
	}
	return token, true
}

func sessionKey(token string) string {
	return "session:" + token
}

func (s *Server) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	apiKey := s.apiKeyFromContext(r.Context())
	if apiKey == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "login required"})
		return
	}
	idemKey := r.Header.Get("Idempotency-Key")
	if idemKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Idempotency-Key required"})
		return
	}
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	requestHash := idempotencyRequestHash(r.Method, r.URL.Path, rawBody)
	if status, body, ok, conflict := s.idempotencyGet(apiKey, idemKey, r.Method, r.URL.Path, requestHash); conflict {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "IDEMPOTENCY_CONFLICT"})
		return
	} else if ok {
		writeRaw(w, status, body)
		return
	}

	var req OrderRequest
	if err := json.Unmarshal(rawBody, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if req.Symbol == "" || req.Side == "" || req.Type == "" || req.Qty == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "symbol/side/type/qty required"})
		return
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

	if s.coreClient == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "core_unavailable"})
		return
	}
	reserveCurrency, reserveAmount, reserveErr := s.tryReserveForOrder(apiKey, req)
	if reserveErr != nil {
		if reserveErr.Error() == "insufficient_balance" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "insufficient_balance"})
			return
		}
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": reserveErr.Error()})
		return
	}

	orderID := "ord_" + uuid.NewString()
	commandID := uuid.NewString()
	correlationID := uuid.NewString()
	traceID := trace.SpanFromContext(r.Context()).SpanContext().TraceID().String()
	if traceID == "" || traceID == "00000000000000000000000000000000" {
		traceID = uuid.NewString()
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
		if reserveCurrency != "" && reserveAmount > 0 {
			if _, releaseErr := s.releaseReserve(apiKey, reserveCurrency, reserveAmount); releaseErr != nil {
				writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "reserve_rollback_failed"})
				return
			}
		}
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "core_unavailable"})
		return
	}

	acceptedAt := int64(0)
	if coreResp.GetAcceptedAt() != nil {
		acceptedAt = coreResp.AcceptedAt.AsTime().UnixMilli()
	}
	statusUpper := strings.ToUpper(coreResp.Status)
	if statusUpper == "PARTIAL" {
		statusUpper = "PARTIALLY_FILLED"
	}
	terminalAt := int64(0)
	if isTerminalOrderStatus(statusUpper) {
		terminalAt = time.Now().UnixMilli()
	}
	if (!coreResp.Accepted || statusUpper == "REJECTED" || statusUpper == "CANCELED") && reserveCurrency != "" && reserveAmount > 0 {
		if _, releaseErr := s.releaseReserve(apiKey, reserveCurrency, reserveAmount); releaseErr != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "reserve_rollback_failed"})
			return
		}
		reserveCurrency = ""
		reserveAmount = 0
	}

	qty, _ := strconv.ParseFloat(strings.TrimSpace(req.Qty), 64)
	record := OrderRecord{
		OrderID:         coreResp.OrderId,
		Status:          statusUpper,
		Symbol:          coreResp.Symbol,
		Seq:             coreResp.Seq,
		AcceptedAt:      acceptedAt,
		OwnerUserID:     apiKey,
		ReserveCurrency: reserveCurrency,
		ReserveAmount:   reserveAmount,
		Side:            strings.ToUpper(strings.TrimSpace(req.Side)),
		Qty:             qty,
		TerminalAt:      terminalAt,
	}
	s.state.mu.Lock()
	s.state.orders[coreResp.OrderId] = record
	s.state.ordersTotal++
	s.pruneOrdersLocked(time.Now().UnixMilli())
	s.state.mu.Unlock()

	resp := OrderResponse{
		OrderID:     coreResp.OrderId,
		Status:      statusUpper,
		Symbol:      coreResp.Symbol,
		Seq:         coreResp.Seq,
		AcceptedAt:  acceptedAt,
		RejectCode:  coreResp.RejectCode,
		Correlation: coreResp.CorrelationId,
	}
	status, body := marshalResponse(http.StatusOK, resp)
	s.idempotencySet(apiKey, idemKey, r.Method, r.URL.Path, requestHash, status, body)
	writeRaw(w, status, body)
}

func (s *Server) handleCancelOrder(w http.ResponseWriter, r *http.Request) {
	apiKey := s.apiKeyFromContext(r.Context())
	if apiKey == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "login required"})
		return
	}
	idemKey := r.Header.Get("Idempotency-Key")
	if idemKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Idempotency-Key required"})
		return
	}
	orderID := chi.URLParam(r, "orderId")
	pathKey := "/v1/orders/" + orderID
	requestHash := idempotencyRequestHash(r.Method, pathKey, nil)
	if status, body, ok, conflict := s.idempotencyGet(apiKey, idemKey, r.Method, pathKey, requestHash); conflict {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "IDEMPOTENCY_CONFLICT"})
		return
	} else if ok {
		writeRaw(w, status, body)
		return
	}
	if s.coreClient == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "core_unavailable"})
		return
	}

	s.state.mu.Lock()
	record, ok := s.state.orders[orderID]
	if !ok {
		s.state.mu.Unlock()
		status, body := marshalResponse(http.StatusNotFound, map[string]string{"error": "UNKNOWN_ORDER"})
		s.idempotencySet(apiKey, idemKey, r.Method, pathKey, requestHash, status, body)
		writeRaw(w, status, body)
		return
	}
	if record.OwnerUserID != "" && record.OwnerUserID != apiKey {
		s.state.mu.Unlock()
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "FORBIDDEN"})
		return
	}
	s.state.mu.Unlock()

	symbol := record.Symbol
	if strings.TrimSpace(symbol) == "" {
		status, body := marshalResponse(http.StatusInternalServerError, map[string]string{"error": "order_symbol_missing"})
		s.idempotencySet(apiKey, idemKey, r.Method, pathKey, requestHash, status, body)
		writeRaw(w, status, body)
		return
	}
	commandID := uuid.NewString()
	correlationID := uuid.NewString()
	traceID := trace.SpanFromContext(r.Context()).SpanContext().TraceID().String()
	if traceID == "" || traceID == "00000000000000000000000000000000" {
		traceID = uuid.NewString()
	}
	coreReq := &exchangev1.CancelOrderRequest{
		Meta: &exchangev1.CommandMetadata{
			CommandId:      commandID,
			IdempotencyKey: idemKey,
			UserId:         apiKey,
			Symbol:         symbol,
			TsServer:       timestamppb.Now(),
			TraceId:        traceID,
			CorrelationId:  correlationID,
		},
		OrderId: orderID,
	}

	coreCtx, cancel := context.WithTimeout(r.Context(), s.cfg.CoreTimeout)
	defer cancel()
	coreResp, err := s.coreClient.CancelOrder(coreCtx, coreReq)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "core_unavailable"})
		return
	}

	canceledAt := int64(0)
	if coreResp.GetCanceledAt() != nil {
		canceledAt = coreResp.CanceledAt.AsTime().UnixMilli()
	}

	statusUpper := strings.ToUpper(coreResp.Status)
	if statusUpper == "ACCEPTED" {
		statusUpper = "CANCELED"
	}
	if statusUpper == "PARTIAL" {
		statusUpper = "PARTIALLY_FILLED"
	}

	if coreResp.Accepted && statusUpper == "CANCELED" {
		s.state.mu.Lock()
		record = s.state.orders[orderID]
		record.Status = "CANCELED"
		record.Seq = coreResp.Seq
		record.CanceledAt = canceledAt
		if canceledAt > 0 {
			record.TerminalAt = canceledAt
		} else {
			record.TerminalAt = time.Now().UnixMilli()
		}
		releaseAmount := record.ReserveAmount - record.ReserveConsumed
		if releaseAmount < 0 {
			releaseAmount = 0
		}
		record.ReserveAmount -= releaseAmount
		s.state.orders[orderID] = record
		s.pruneOrdersLocked(time.Now().UnixMilli())
		s.state.mu.Unlock()

		if releaseAmount > 0 && record.ReserveCurrency != "" && record.OwnerUserID != "" {
			if _, releaseErr := s.releaseReserve(record.OwnerUserID, record.ReserveCurrency, releaseAmount); releaseErr != nil {
				writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "reserve_release_failed"})
				return
			}
		}
	}

	resp := OrderResponse{
		OrderID:     coreResp.OrderId,
		Status:      statusUpper,
		Symbol:      coreResp.Symbol,
		Seq:         coreResp.Seq,
		CanceledAt:  canceledAt,
		RejectCode:  coreResp.RejectCode,
		Correlation: coreResp.CorrelationId,
	}
	status, body := marshalResponse(http.StatusOK, resp)
	s.idempotencySet(apiKey, idemKey, r.Method, pathKey, requestHash, status, body)
	writeRaw(w, status, body)
}

func (s *Server) handleGetOrder(w http.ResponseWriter, r *http.Request) {
	apiKey := s.apiKeyFromContext(r.Context())
	if apiKey == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "login required"})
		return
	}
	orderID := chi.URLParam(r, "orderId")
	s.state.mu.Lock()
	record, ok := s.state.orders[orderID]
	s.state.mu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "UNKNOWN_ORDER"})
		return
	}
	if record.OwnerUserID != "" && record.OwnerUserID != apiKey {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "FORBIDDEN"})
		return
	}
	writeJSON(w, http.StatusOK, record)
}

func (s *Server) handleSmokeTrade(w http.ResponseWriter, r *http.Request) {
	if !s.cfg.EnableSmokeRoutes {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "smoke_disabled"})
		return
	}
	var req SmokeTradeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if req.TradeID == "" || req.Symbol == "" || req.Price == "" || req.Qty == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "tradeId/symbol/price/qty required"})
		return
	}

	seq, err := s.ingestSmokeTrade(r.Context(), req, time.Now().UnixMilli(), true, 0)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"status": "settled", "seq": seq})
}

func (s *Server) ingestSmokeTrade(
	ctx context.Context,
	req SmokeTradeRequest,
	tsMs int64,
	persist bool,
	seqOverride uint64,
) (uint64, error) {
	if persist {
		if err := s.appendSettlement(ctx, req); err != nil {
			return 0, err
		}
	}

	s.state.mu.Lock()
	seq := seqOverride
	if seq == 0 {
		seq = s.state.nextSeq
		s.state.nextSeq++
	} else if seq >= s.state.nextSeq {
		s.state.nextSeq = seq + 1
	}
	s.state.tradesTotal++
	s.state.mu.Unlock()

	tradeMsg := WSMessage{
		Type:    "TradeExecuted",
		Channel: "trades",
		Symbol:  req.Symbol,
		Seq:     seq,
		Ts:      tsMs,
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
		Ts:      tsMs,
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
	tickerData := s.recordTicker(req.Symbol, req.Price, req.Qty, tsMs)
	tickerMsg := WSMessage{
		Type:    "TickerUpdated",
		Channel: "ticker",
		Symbol:  req.Symbol,
		Seq:     seq,
		Ts:      tsMs,
		Data:    tickerData,
	}
	bookMsg := WSMessage{
		Type:    "OrderbookUpdated",
		Channel: "book",
		Symbol:  req.Symbol,
		Seq:     seq,
		Ts:      tsMs,
		Data:    buildOrderbookData(req.Price, req.Qty),
	}

	s.appendHistory(req.Symbol, tradeMsg)
	s.appendHistory(req.Symbol, candleMsg)
	s.appendHistory(req.Symbol, tickerMsg)
	s.appendHistory(req.Symbol, bookMsg)
	_ = s.cacheSet(ctx, cacheKey("trades", req.Symbol), tradeMsg)
	_ = s.cacheSet(ctx, cacheKey("candles", req.Symbol), candleMsg)
	_ = s.cacheSet(ctx, cacheKey("ticker", req.Symbol), tickerMsg)
	_ = s.cacheSet(ctx, cacheKey("book", req.Symbol), bookMsg)

	s.broadcast(tradeMsg)
	s.broadcast(candleMsg)
	s.broadcast(tickerMsg)
	s.broadcast(bookMsg)
	return seq, nil
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

func (s *Server) seedSampleMarketData(ctx context.Context) error {
	type seedSpec struct {
		symbol    string
		basePrice int64
		baseQty   int64
	}

	specs := []seedSpec{
		{symbol: "BTC-KRW", basePrice: 96400000, baseQty: 2100},
		{symbol: "ETH-KRW", basePrice: 5250000, baseQty: 4300},
		{symbol: "SOL-KRW", basePrice: 173000, baseQty: 9700},
		{symbol: "XRP-KRW", basePrice: 920, baseQty: 77000},
		{symbol: "BNB-KRW", basePrice: 987000, baseQty: 6400},
	}

	const samplePoints = 120
	const stepMs = int64(time.Minute / time.Millisecond)
	nowMs := time.Now().UnixMilli()

	for idx, spec := range specs {
		for i := 0; i < samplePoints; i++ {
			tsMs := nowMs - int64(samplePoints-i)*stepMs
			trendUnit := maxInt64(1, spec.basePrice/20000)
			swingUnit := maxInt64(1, spec.basePrice/4000)
			trend := int64(i-samplePoints/2) * trendUnit
			swing := int64(((i*17)+(idx*11))%15-7) * swingUnit
			price := maxInt64(1, spec.basePrice+trend+swing)
			qty := maxInt64(1, spec.baseQty+int64((i*37+idx*19)%4000))
			tradeID := fmt.Sprintf(
				"seed-%s-%03d",
				strings.ToLower(strings.ReplaceAll(spec.symbol, "-", "")),
				i,
			)

			if _, err := s.ingestSmokeTrade(ctx, SmokeTradeRequest{
				TradeID: tradeID,
				Symbol:  spec.symbol,
				Price:   strconv.FormatInt(price, 10),
				Qty:     strconv.FormatInt(qty, 10),
			}, tsMs, false, 0); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Server) startTradeConsumer() {
	if strings.TrimSpace(s.cfg.KafkaBrokers) == "" {
		s.state.mu.Lock()
		s.state.tradeConsumerExpected = false
		s.state.tradeConsumerRunning = false
		s.state.tradeConsumerErrorMs = 0
		s.state.mu.Unlock()
		return
	}
	brokers := make([]string, 0, 3)
	for _, raw := range strings.Split(s.cfg.KafkaBrokers, ",") {
		v := strings.TrimSpace(raw)
		if v != "" {
			brokers = append(brokers, v)
		}
	}
	if len(brokers) == 0 {
		s.state.mu.Lock()
		s.state.tradeConsumerExpected = false
		s.state.tradeConsumerRunning = false
		s.state.tradeConsumerErrorMs = 0
		s.state.mu.Unlock()
		return
	}

	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers:     brokers,
		GroupID:     s.cfg.KafkaGroupID,
		Topic:       s.cfg.KafkaTradeTopic,
		StartOffset: kafkaStartOffset(s.cfg.KafkaStartOffset),
		MinBytes:    1,
		MaxBytes:    10e6,
		MaxWait:     1 * time.Second,
	})
	ctx, cancel := context.WithCancel(context.Background())

	s.tradeConsumer = reader
	s.tradeCancel = cancel
	s.state.mu.Lock()
	s.state.tradeConsumerExpected = true
	s.state.tradeConsumerRunning = true
	s.state.tradeConsumerErrorMs = 0
	s.state.mu.Unlock()
	s.tradeWG.Add(1)
	go func() {
		defer s.tradeWG.Done()
		defer func() {
			s.state.mu.Lock()
			s.state.tradeConsumerRunning = false
			s.state.mu.Unlock()
		}()
		for {
			msg, err := reader.ReadMessage(ctx)
			if err != nil {
				if errors.Is(err, context.Canceled) || errors.Is(err, kafka.ErrGroupClosed) {
					return
				}
				s.state.mu.Lock()
				s.state.tradeConsumerReadErrors++
				s.state.tradeConsumerErrorMs = time.Now().UnixMilli()
				s.state.mu.Unlock()
				log.Printf("service=edge-gateway msg=trade_consume_failed topic=%s reason=%v", s.cfg.KafkaTradeTopic, err)
				select {
				case <-ctx.Done():
					return
				case <-time.After(500 * time.Millisecond):
				}
				continue
			}
			s.state.mu.Lock()
			s.state.tradeConsumerErrorMs = 0
			s.state.mu.Unlock()
			if err := s.consumeTradeMessage(ctx, msg.Value); err != nil {
				log.Printf("service=edge-gateway msg=trade_apply_failed reason=%v payload=%s", err, string(msg.Value))
			}
		}
	}()
}

func (s *Server) consumeTradeMessage(ctx context.Context, raw []byte) error {
	var payload tradeEventPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return fmt.Errorf("decode trade payload: %w", err)
	}
	if payload.Envelope.EventVersion != 1 {
		return fmt.Errorf("unsupported eventVersion: %d", payload.Envelope.EventVersion)
	}
	if strings.TrimSpace(payload.TradeID) == "" {
		return fmt.Errorf("missing tradeId")
	}

	symbol := strings.ToUpper(strings.TrimSpace(payload.Envelope.Symbol))
	if symbol == "" {
		symbol = strings.ToUpper(strings.TrimSpace(payload.Symbol))
	}
	if symbol == "" {
		return fmt.Errorf("missing symbol")
	}

	price, ok := parseInt64Any(payload.Price)
	if !ok || price <= 0 {
		return fmt.Errorf("invalid price: %v", payload.Price)
	}
	qty, ok := parseInt64Any(payload.Quantity)
	if !ok || qty <= 0 {
		return fmt.Errorf("invalid quantity: %v", payload.Quantity)
	}
	quoteAmount := price * qty
	if parsed, ok := parseInt64Any(payload.QuoteAmount); ok && parsed > 0 {
		quoteAmount = parsed
	}

	seq := payload.Envelope.Seq
	if seq == 0 {
		seq = payload.Seq
	}
	if seq == 0 {
		return fmt.Errorf("missing seq")
	}

	tsMs := payload.TsMs
	if tsMs <= 0 {
		if t, err := time.Parse(time.RFC3339Nano, payload.Envelope.OccurredAtRaw); err == nil {
			tsMs = t.UnixMilli()
		}
	}
	if tsMs <= 0 {
		tsMs = time.Now().UnixMilli()
	}

	if !s.beginTradeApply(payload.TradeID) {
		return nil
	}
	applied := false
	defer func() {
		if !applied {
			s.abortTradeApply(payload.TradeID)
		}
	}()

	if err := s.applyTradeSettlement(payload.BuyerUserID, payload.SellerUserID, symbol, qty, quoteAmount); err != nil {
		return fmt.Errorf("apply settlement: %w", err)
	}
	if err := s.applyOrderFill(payload.MakerOrderID, qty, price, seq); err != nil {
		return fmt.Errorf("apply maker fill: %w", err)
	}
	if err := s.applyOrderFill(payload.TakerOrderID, qty, price, seq); err != nil {
		return fmt.Errorf("apply taker fill: %w", err)
	}

	_, err := s.ingestSmokeTrade(ctx, SmokeTradeRequest{
		TradeID: payload.TradeID,
		Symbol:  symbol,
		Price:   strconv.FormatInt(price, 10),
		Qty:     strconv.FormatInt(qty, 10),
	}, tsMs, false, seq)
	if err != nil {
		return fmt.Errorf("ingest trade message: %w", err)
	}
	s.commitTradeApply(payload.TradeID, tsMs)
	applied = true
	return nil
}

func (s *Server) beginTradeApply(tradeID string) bool {
	now := time.Now().UnixMilli()
	cutoff := now - 24*60*60*1000

	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	for id, seenAt := range s.state.appliedTrades {
		if seenAt < cutoff {
			delete(s.state.appliedTrades, id)
		}
	}
	for id, startedAt := range s.state.applyingTrades {
		if startedAt < cutoff {
			delete(s.state.applyingTrades, id)
		}
	}
	if _, exists := s.state.appliedTrades[tradeID]; exists {
		return false
	}
	if _, inProgress := s.state.applyingTrades[tradeID]; inProgress {
		return false
	}
	s.state.applyingTrades[tradeID] = now
	return true
}

func (s *Server) commitTradeApply(tradeID string, tsMs int64) {
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	delete(s.state.applyingTrades, tradeID)
	s.state.appliedTrades[tradeID] = tsMs
}

func (s *Server) abortTradeApply(tradeID string) {
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	delete(s.state.applyingTrades, tradeID)
}

type walletPersistUpdate struct {
	userID   string
	currency string
	balance  walletBalance
}

type walletSnapshot struct {
	exists bool
	wallet map[string]walletBalance
}

func (s *Server) captureWalletSnapshotsLocked(userIDs ...string) map[string]walletSnapshot {
	snapshots := make(map[string]walletSnapshot, len(userIDs))
	for _, userID := range userIDs {
		if strings.TrimSpace(userID) == "" {
			continue
		}
		if _, seen := snapshots[userID]; seen {
			continue
		}
		wallet, exists := s.state.wallets[userID]
		snapshot := walletSnapshot{exists: exists}
		if exists {
			snapshot.wallet = cloneWallet(wallet)
		}
		snapshots[userID] = snapshot
	}
	return snapshots
}

func (s *Server) restoreWalletSnapshotsLocked(snapshots map[string]walletSnapshot) {
	for userID, snapshot := range snapshots {
		if snapshot.exists {
			s.state.wallets[userID] = cloneWallet(snapshot.wallet)
		} else {
			delete(s.state.wallets, userID)
		}
	}
}

func (s *Server) applyTradeSettlement(buyerUserID, sellerUserID, symbol string, qty, quoteAmount int64) error {
	base, quote, ok := parseSymbol(symbol)
	if !ok {
		return fmt.Errorf("invalid symbol")
	}
	qtyF := float64(qty)
	quoteF := float64(quoteAmount)

	updates := make([]walletPersistUpdate, 0, 4)
	s.state.mu.Lock()
	snapshots := s.captureWalletSnapshotsLocked(buyerUserID, sellerUserID)
	if buyerUserID != "" {
		before := len(updates)
		updates = append(updates, s.settleBuyerLocked(buyerUserID, base, quote, qtyF, quoteF)...)
		if len(updates) == before {
			s.restoreWalletSnapshotsLocked(snapshots)
			s.state.mu.Unlock()
			return fmt.Errorf("insufficient buyer balance")
		}
	}
	if sellerUserID != "" {
		before := len(updates)
		updates = append(updates, s.settleSellerLocked(sellerUserID, base, quote, qtyF, quoteF)...)
		if len(updates) == before {
			s.restoreWalletSnapshotsLocked(snapshots)
			s.state.mu.Unlock()
			return fmt.Errorf("insufficient seller balance")
		}
	}
	s.state.mu.Unlock()

	for _, update := range updates {
		if err := s.persistWalletBalance(context.Background(), update.userID, update.currency, update.balance); err != nil {
			s.state.mu.Lock()
			s.restoreWalletSnapshotsLocked(snapshots)
			s.state.settlementAnomalies++
			s.state.walletPersistErrors++
			s.state.mu.Unlock()
			return err
		}
	}
	return nil
}

func (s *Server) settleBuyerLocked(userID, base, quote string, qty, quoteAmount float64) []walletPersistUpdate {
	wallet := s.state.wallets[userID]
	if wallet == nil {
		wallet = map[string]walletBalance{}
	}

	quoteBal := wallet[quote]
	if quoteBal.Hold+quoteBal.Available+1e-9 < quoteAmount {
		s.state.settlementAnomalies++
		return nil
	}
	remaining := quoteAmount
	if quoteBal.Hold >= remaining {
		quoteBal.Hold -= remaining
		remaining = 0
	} else {
		remaining -= quoteBal.Hold
		quoteBal.Hold = 0
	}
	if remaining > 0 {
		quoteBal.Available -= remaining
		if quoteBal.Available < 0 {
			quoteBal.Available = 0
		}
	}
	wallet[quote] = quoteBal

	baseBal := wallet[base]
	baseBal.Available += qty
	wallet[base] = baseBal

	s.state.wallets[userID] = wallet
	return []walletPersistUpdate{
		{userID: userID, currency: quote, balance: quoteBal},
		{userID: userID, currency: base, balance: baseBal},
	}
}

func (s *Server) settleSellerLocked(userID, base, quote string, qty, quoteAmount float64) []walletPersistUpdate {
	wallet := s.state.wallets[userID]
	if wallet == nil {
		wallet = map[string]walletBalance{}
	}

	baseBal := wallet[base]
	if baseBal.Hold+baseBal.Available+1e-9 < qty {
		s.state.settlementAnomalies++
		return nil
	}
	remaining := qty
	if baseBal.Hold >= remaining {
		baseBal.Hold -= remaining
		remaining = 0
	} else {
		remaining -= baseBal.Hold
		baseBal.Hold = 0
	}
	if remaining > 0 {
		baseBal.Available -= remaining
		if baseBal.Available < 0 {
			baseBal.Available = 0
		}
	}
	wallet[base] = baseBal

	quoteBal := wallet[quote]
	quoteBal.Available += quoteAmount
	wallet[quote] = quoteBal

	s.state.wallets[userID] = wallet
	return []walletPersistUpdate{
		{userID: userID, currency: base, balance: baseBal},
		{userID: userID, currency: quote, balance: quoteBal},
	}
}

type reserveRelease struct {
	userID   string
	currency string
	amount   float64
}

func (s *Server) applyOrderFill(orderID string, fillQty, fillPrice int64, seq uint64) error {
	orderID = strings.TrimSpace(orderID)
	if orderID == "" {
		return nil
	}

	var release *reserveRelease
	fillQtyF := float64(fillQty)
	fillQuoteF := float64(fillQty) * float64(fillPrice)

	s.state.mu.Lock()
	record, ok := s.state.orders[orderID]
	if ok {
		record.FilledQty += fillQtyF
		switch strings.ToUpper(record.Side) {
		case "BUY":
			record.ReserveConsumed += fillQuoteF
		case "SELL":
			record.ReserveConsumed += fillQtyF
		}

		if record.Qty > 0 && record.FilledQty >= record.Qty-1e-9 {
			record.FilledQty = record.Qty
			record.Status = "FILLED"
			record.TerminalAt = time.Now().UnixMilli()
			remainingReserve := record.ReserveAmount - record.ReserveConsumed
			if remainingReserve > 1e-9 && record.OwnerUserID != "" && record.ReserveCurrency != "" {
				release = &reserveRelease{
					userID:   record.OwnerUserID,
					currency: record.ReserveCurrency,
					amount:   remainingReserve,
				}
				record.ReserveAmount -= remainingReserve
			}
		} else if record.FilledQty > 0 {
			record.Status = "PARTIALLY_FILLED"
		}

		if seq > record.Seq {
			record.Seq = seq
		}
		s.state.orders[orderID] = record
		s.pruneOrdersLocked(time.Now().UnixMilli())
	}
	s.state.mu.Unlock()

	if release != nil {
		if _, err := s.releaseReserve(release.userID, release.currency, release.amount); err != nil {
			return err
		}
	}
	return nil
}

func isTerminalOrderStatus(status string) bool {
	normalized := strings.ToUpper(strings.TrimSpace(status))
	return normalized == "FILLED" || normalized == "CANCELED" || normalized == "REJECTED"
}

func (s *Server) pruneOrdersLocked(nowMs int64) {
	if s.cfg.OrderMaxRecords <= 0 {
		return
	}
	if len(s.state.orders) == 0 {
		s.state.nextOrderGcAtMs = nowMs + s.cfg.OrderGCInterval.Milliseconds()
		return
	}
	if len(s.state.orders) <= s.cfg.OrderMaxRecords && nowMs < s.state.nextOrderGcAtMs {
		return
	}

	retentionCutoff := nowMs - s.cfg.OrderRetention.Milliseconds()
	if retentionCutoff < 0 {
		retentionCutoff = 0
	}

	for orderID, record := range s.state.orders {
		if !isTerminalOrderStatus(record.Status) {
			continue
		}
		if record.TerminalAt > 0 && record.TerminalAt <= retentionCutoff {
			delete(s.state.orders, orderID)
		}
	}

	if len(s.state.orders) > s.cfg.OrderMaxRecords {
		type terminalRecord struct {
			orderID    string
			terminalAt int64
		}
		terminal := make([]terminalRecord, 0, len(s.state.orders))
		for orderID, record := range s.state.orders {
			if !isTerminalOrderStatus(record.Status) {
				continue
			}
			terminalAt := record.TerminalAt
			if terminalAt <= 0 {
				terminalAt = record.CanceledAt
			}
			if terminalAt <= 0 {
				terminalAt = record.AcceptedAt
			}
			terminal = append(terminal, terminalRecord{
				orderID:    orderID,
				terminalAt: terminalAt,
			})
		}
		sort.Slice(terminal, func(i, j int) bool {
			if terminal[i].terminalAt == terminal[j].terminalAt {
				return terminal[i].orderID < terminal[j].orderID
			}
			return terminal[i].terminalAt < terminal[j].terminalAt
		})
		need := len(s.state.orders) - s.cfg.OrderMaxRecords
		for i := 0; i < need && i < len(terminal); i++ {
			delete(s.state.orders, terminal[i].orderID)
		}
	}

	s.state.nextOrderGcAtMs = nowMs + s.cfg.OrderGCInterval.Milliseconds()
}

func wsClientIP(remoteAddr string) string {
	remoteAddr = strings.TrimSpace(remoteAddr)
	if remoteAddr == "" {
		return "unknown"
	}
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	if strings.TrimSpace(host) == "" {
		return "unknown"
	}
	return host
}

func (s *Server) reserveWSConnection(ip string) bool {
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	total := 0
	for _, count := range s.state.wsConnsByIP {
		total += count
	}
	if total >= s.cfg.WSMaxConns {
		s.state.wsConnRejects++
		return false
	}
	if s.state.wsConnsByIP[ip] >= s.cfg.WSMaxConnsPerIP {
		s.state.wsConnRejects++
		return false
	}
	s.state.wsConnsByIP[ip]++
	return true
}

func (s *Server) releaseWSConnection(ip string) {
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	count := s.state.wsConnsByIP[ip]
	if count <= 1 {
		delete(s.state.wsConnsByIP, ip)
		return
	}
	s.state.wsConnsByIP[ip] = count - 1
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	clientIP := wsClientIP(r.RemoteAddr)
	if !s.reserveWSConnection(clientIP) {
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "ws_connection_limit"})
		return
	}
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		s.releaseWSConnection(clientIP)
		return
	}
	conn.SetReadLimit(s.cfg.WSReadLimitBytes)
	_ = conn.SetReadDeadline(time.Now().Add(s.cfg.WSPongTimeout))
	conn.SetPongHandler(func(_ string) error {
		return conn.SetReadDeadline(time.Now().Add(s.cfg.WSPongTimeout))
	})
	client := &client{
		conn:        conn,
		send:        make(chan []byte, s.cfg.WSQueueSize),
		conflated:   map[string][]byte{},
		subscribers: map[string]wsSubscription{},
	}

	s.state.mu.Lock()
	s.state.clients[client] = struct{}{}
	s.state.mu.Unlock()

	go s.wsWriter(client, clientIP)
	s.wsReader(client)
}

func (s *Server) wsWriter(c *client, clientIP string) {
	defer func() {
		s.state.mu.Lock()
		delete(s.state.clients, c)
		s.state.mu.Unlock()
		s.releaseWSConnection(clientIP)
		c.closeSend()
		_ = c.conn.Close()
	}()

	flushTicker := time.NewTicker(100 * time.Millisecond)
	defer flushTicker.Stop()
	pingTicker := time.NewTicker(s.cfg.WSPingInterval)
	defer pingTicker.Stop()

	writeJSON := func(payload []byte) error {
		_ = c.conn.SetWriteDeadline(time.Now().Add(1 * time.Second))
		if err := c.conn.WriteMessage(websocket.TextMessage, payload); err != nil {
			return err
		}
		if s.cfg.WSWriteDelay > 0 {
			time.Sleep(s.cfg.WSWriteDelay)
		}
		return nil
	}

	for {
		select {
		case msg, ok := <-c.send:
			if !ok {
				return
			}
			if err := writeJSON(msg); err != nil {
				return
			}
		case <-flushTicker.C:
			pending := c.drainConflated()
			for _, payload := range pending {
				if err := writeJSON(payload); err != nil {
					return
				}
			}
		case <-pingTicker.C:
			deadline := time.Now().Add(1 * time.Second)
			if err := c.conn.WriteControl(websocket.PingMessage, nil, deadline); err != nil {
				return
			}
		}
	}
}

func (s *Server) wsReader(c *client) {
	defer func() {
		c.closeSend()
		_ = c.conn.Close()
	}()

	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		if !c.allowCommand(
			time.Now().UnixMilli(),
			s.cfg.WSCommandRateLimit,
			s.cfg.WSCommandWindow.Milliseconds(),
		) {
			s.state.mu.Lock()
			s.state.wsPolicyCloses++
			s.state.wsRateLimitCloses++
			s.state.mu.Unlock()
			if c.conn != nil {
				_ = c.conn.WriteControl(
					websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "RATE_LIMIT"),
					time.Now().Add(1*time.Second),
				)
			}
			c.closeSend()
			return
		}
		var cmd WSCommand
		if err := json.Unmarshal(raw, &cmd); err != nil {
			s.sendToClient(c, WSMessage{Type: "Error", Symbol: "", Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]string{"error": "INVALID_COMMAND"}}, false, "")
			continue
		}

		switch strings.ToUpper(cmd.Op) {
		case "SUB":
			sub, err := parseWSSubscription(cmd)
			if err != nil {
				s.sendToClient(c, WSMessage{
					Type: "Error", Symbol: "", Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]string{"error": "INVALID_SUBSCRIPTION"},
				}, false, "")
				continue
			}
			if !c.upsertSubscription(sub, s.cfg.WSMaxSubscriptions) {
				s.state.mu.Lock()
				s.state.wsPolicyCloses++
				s.state.mu.Unlock()
				if c.conn != nil {
					_ = c.conn.WriteControl(
						websocket.CloseMessage,
						websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "TOO_MANY_SUBSCRIPTIONS"),
						time.Now().Add(1*time.Second),
					)
				}
				c.closeSend()
				return
			}
			s.sendSnapshot(c, sub)
		case "UNSUB":
			sub, err := parseWSSubscription(cmd)
			if err != nil {
				s.sendToClient(c, WSMessage{
					Type: "Error", Symbol: "", Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]string{"error": "INVALID_SUBSCRIPTION"},
				}, false, "")
				continue
			}
			c.removeSubscription(sub)
		case "RESUME":
			sub, err := parseWSSubscription(cmd)
			if err != nil {
				s.sendToClient(c, WSMessage{
					Type: "Error", Symbol: "", Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]string{"error": "INVALID_SUBSCRIPTION"},
				}, false, "")
				continue
			}
			if !c.upsertSubscription(sub, s.cfg.WSMaxSubscriptions) {
				s.state.mu.Lock()
				s.state.wsPolicyCloses++
				s.state.mu.Unlock()
				if c.conn != nil {
					_ = c.conn.WriteControl(
						websocket.CloseMessage,
						websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "TOO_MANY_SUBSCRIPTIONS"),
						time.Now().Add(1*time.Second),
					)
				}
				c.closeSend()
				return
			}
			s.handleResume(c, sub, cmd.LastSeq)
		default:
			s.sendToClient(c, WSMessage{Type: "Error", Symbol: "", Seq: 0, Ts: time.Now().UnixMilli(), Data: map[string]string{"error": "UNKNOWN_OP"}}, false, "")
		}
	}
}

func (s *Server) handleResume(c *client, sub wsSubscription, lastSeq uint64) {
	history := s.history(sub.symbol)
	if len(history) == 0 {
		s.sendSnapshot(c, sub)
		return
	}

	// For high-volume channels that use conflation semantics, snapshot is the recovery primitive.
	if sub.channel == "book" || sub.channel == "candles" || sub.channel == "ticker" {
		s.sendSnapshot(c, sub)
		return
	}

	oldest := uint64(0)
	found := false
	for _, evt := range history {
		if evt.Channel != sub.channel || evt.Symbol != sub.symbol {
			continue
		}
		oldest = evt.Seq
		found = true
		break
	}
	if !found || lastSeq+1 < oldest {
		s.sendSnapshot(c, sub)
		return
	}

	replayed := false
	for _, evt := range history {
		if evt.Channel != sub.channel || evt.Symbol != sub.symbol {
			continue
		}
		if evt.Seq > lastSeq {
			s.sendToClient(c, evt, conflatable(evt.Channel), sub.key())
			replayed = true
		}
	}
	if !replayed {
		s.sendSnapshot(c, sub)
	}
}

func (s *Server) sendSnapshot(c *client, sub wsSubscription) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	key := cacheKey(sub.channel, sub.symbol)
	if payload, ok := s.cacheGet(ctx, key); ok {
		var msg WSMessage
		if err := json.Unmarshal(payload, &msg); err == nil {
			msg.Type = "Snapshot"
			msg = applySubscriptionView(msg, sub)
			s.sendToClient(c, msg, conflatable(sub.channel), sub.key())
			return
		}
	}

	snapshot := WSMessage{
		Type:    "Snapshot",
		Channel: sub.channel,
		Symbol:  sub.symbol,
		Seq:     0,
		Ts:      time.Now().UnixMilli(),
		Data:    map[string]interface{}{},
	}
	if sub.channel == "book" {
		snapshot.Data = map[string]interface{}{
			"depth": sub.depth,
			"bids":  []interface{}{},
			"asks":  []interface{}{},
		}
	}
	if sub.channel == "candles" {
		snapshot.Data = map[string]interface{}{"interval": sub.interval}
	}
	s.sendToClient(c, snapshot, conflatable(sub.channel), sub.key())
}

func (s *Server) broadcast(msg WSMessage) {
	s.state.mu.Lock()
	clients := make([]*client, 0, len(s.state.clients))
	for c := range s.state.clients {
		clients = append(clients, c)
	}
	s.state.mu.Unlock()

	for _, c := range clients {
		for _, sub := range c.matchingSubscriptions(msg.Channel, msg.Symbol) {
			view, ok := messageForSubscription(msg, sub)
			if !ok {
				continue
			}
			s.sendToClient(c, view, conflatable(msg.Channel), sub.key())
		}
	}
}

func (s *Server) sendToClient(c *client, msg WSMessage, conflatableMessage bool, conflationKey string) {
	payload, _ := json.Marshal(msg)
	if conflatableMessage {
		if conflationKey == "" {
			conflationKey = conflationKeyForMessage(msg)
		}
		replaced, accepted := c.setConflated(conflationKey, payload)
		if accepted && replaced {
			s.state.mu.Lock()
			s.state.wsDroppedMsgs++
			s.state.mu.Unlock()
		}
		return
	}

	if !c.enqueue(payload) {
		s.state.mu.Lock()
		s.state.slowConsumerCloses++
		s.state.wsDroppedMsgs++
		s.state.mu.Unlock()
		if c.conn != nil {
			_ = c.conn.WriteControl(websocket.CloseMessage,
				websocket.FormatCloseMessage(slowConsumerCloseCode, "SLOW_CONSUMER"),
				time.Now().Add(1*time.Second),
			)
		}
		c.closeSend()
	}
}

func parseWSSubscription(cmd WSCommand) (wsSubscription, error) {
	channel := strings.ToLower(strings.TrimSpace(cmd.Channel))
	symbol := strings.ToUpper(strings.TrimSpace(cmd.Symbol))
	if channel == "" || symbol == "" {
		return wsSubscription{}, fmt.Errorf("channel/symbol required")
	}
	if !wsSymbolPattern.MatchString(symbol) {
		return wsSubscription{}, fmt.Errorf("invalid symbol")
	}
	if !supportedWSChannel(channel) {
		return wsSubscription{}, fmt.Errorf("unsupported channel")
	}

	sub := wsSubscription{
		channel: channel,
		symbol:  symbol,
	}
	switch channel {
	case "book":
		sub.depth = parseLimit(strconv.Itoa(cmd.Depth), defaultBookDepth)
	case "candles":
		interval := strings.ToLower(strings.TrimSpace(cmd.Interval))
		if interval == "" {
			interval = defaultCandleInterval
		}
		sub.interval = interval
	}
	return sub, nil
}

func originAllowed(allowed map[string]struct{}, origin string) bool {
	if len(allowed) == 0 {
		return true
	}
	normalized := strings.ToLower(strings.TrimSpace(origin))
	if normalized == "" {
		return false
	}
	_, ok := allowed[normalized]
	return ok
}

func defaultSubscription(channel, symbol string) wsSubscription {
	sub := wsSubscription{
		channel: strings.ToLower(strings.TrimSpace(channel)),
		symbol:  strings.ToUpper(strings.TrimSpace(symbol)),
	}
	if sub.channel == "book" {
		sub.depth = defaultBookDepth
	}
	if sub.channel == "candles" {
		sub.interval = defaultCandleInterval
	}
	return sub
}

func supportedWSChannel(channel string) bool {
	return channel == "trades" || channel == "book" || channel == "candles" || channel == "ticker"
}

func applySubscriptionView(msg WSMessage, sub wsSubscription) WSMessage {
	view, ok := messageForSubscription(msg, sub)
	if !ok {
		return msg
	}
	return view
}

func messageForSubscription(msg WSMessage, sub wsSubscription) (WSMessage, bool) {
	if msg.Channel != sub.channel || msg.Symbol != sub.symbol {
		return WSMessage{}, false
	}

	switch sub.channel {
	case "book":
		data, ok := msg.Data.(map[string]interface{})
		if !ok {
			return msg, true
		}
		cloned := map[string]interface{}{}
		for k, v := range data {
			cloned[k] = v
		}
		cloned["depth"] = sub.depth
		cloned["bids"] = trimBookLevels(cloned["bids"], sub.depth)
		cloned["asks"] = trimBookLevels(cloned["asks"], sub.depth)
		msg.Data = cloned
		return msg, true
	case "candles":
		eventInterval := candleInterval(msg)
		if eventInterval != sub.interval {
			return WSMessage{}, false
		}
		data, ok := msg.Data.(map[string]interface{})
		if !ok {
			return msg, true
		}
		cloned := map[string]interface{}{}
		for k, v := range data {
			cloned[k] = v
		}
		cloned["interval"] = sub.interval
		msg.Data = cloned
		return msg, true
	default:
		return msg, true
	}
}

func candleInterval(msg WSMessage) string {
	data, ok := msg.Data.(map[string]interface{})
	if !ok {
		return defaultCandleInterval
	}
	interval, ok := data["interval"].(string)
	if !ok {
		return defaultCandleInterval
	}
	interval = strings.ToLower(strings.TrimSpace(interval))
	if interval == "" {
		return defaultCandleInterval
	}
	return interval
}

func conflationKeyForMessage(msg WSMessage) string {
	sub := defaultSubscription(msg.Channel, msg.Symbol)
	if sub.channel == "book" {
		data, ok := msg.Data.(map[string]interface{})
		if ok {
			sub.depth = parseLimit(fmt.Sprint(data["depth"]), defaultBookDepth)
		}
	}
	if sub.channel == "candles" {
		sub.interval = candleInterval(msg)
	}
	return sub.key()
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

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	payload, ok := s.cacheGet(ctx, cacheKey("book", symbol))
	if ok {
		var msg WSMessage
		if err := json.Unmarshal(payload, &msg); err == nil {
			if data, castOK := msg.Data.(map[string]interface{}); castOK {
				bids := trimBookLevels(data["bids"], depth)
				asks := trimBookLevels(data["asks"], depth)
				writeJSON(w, http.StatusOK, map[string]interface{}{
					"symbol": symbol,
					"depth":  depth,
					"source": "demo-derived-from-last-trade",
					"bids":   bids,
					"asks":   asks,
				})
				return
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"symbol": symbol,
		"depth":  depth,
		"source": "demo-derived-from-last-trade",
		"bids":   []interface{}{},
		"asks":   []interface{}{},
	})
}

func (s *Server) handleGetCandles(w http.ResponseWriter, r *http.Request) {
	symbol := chi.URLParam(r, "symbol")
	limit := parseLimit(r.URL.Query().Get("limit"), 120)
	history := s.history(symbol)
	candles := make([]WSMessage, 0, len(history))
	for _, evt := range history {
		if evt.Channel == "candles" {
			candles = append(candles, evt)
		}
	}
	if len(candles) > limit {
		candles = candles[len(candles)-limit:]
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"symbol": symbol, "candles": candles})
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

func trimBookLevels(raw interface{}, depth int) []interface{} {
	levels, ok := raw.([]interface{})
	if !ok || len(levels) == 0 {
		return []interface{}{}
	}
	if depth <= 0 || depth > len(levels) {
		depth = len(levels)
	}
	out := make([]interface{}, depth)
	copy(out, levels[:depth])
	return out
}

func buildOrderbookData(priceRaw, qtyRaw string) map[string]interface{} {
	price, err := strconv.ParseInt(priceRaw, 10, 64)
	if err != nil || price <= 0 {
		price = 1
	}
	baseQty, err := strconv.ParseInt(qtyRaw, 10, 64)
	if err != nil || baseQty <= 0 {
		baseQty = 1
	}

	depth := 20
	tick := maxInt64(1, price/2000)
	bids := make([][]string, 0, depth)
	asks := make([][]string, 0, depth)
	for i := 0; i < depth; i++ {
		spread := int64(i+1) * tick
		bidPrice := maxInt64(1, price-spread)
		askPrice := price + spread
		bidQty := maxInt64(1, baseQty+int64((depth-i)*17))
		askQty := maxInt64(1, baseQty+int64((i+1)*19))
		bids = append(bids, []string{
			strconv.FormatInt(bidPrice, 10),
			strconv.FormatInt(bidQty, 10),
		})
		asks = append(asks, []string{
			strconv.FormatInt(askPrice, 10),
			strconv.FormatInt(askQty, 10),
		})
	}

	return map[string]interface{}{
		"depth": depth,
		"bids":  bids,
		"asks":  asks,
	}
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

func prometheusLabelEscape(value string) string {
	escaped := strings.ReplaceAll(value, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	escaped = strings.ReplaceAll(escaped, "\n", `\n`)
	return escaped
}

func conflatable(channel string) bool {
	return channel == "book" || channel == "candles" || channel == "ticker"
}

func kafkaStartOffset(raw string) int64 {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "last", "latest":
		return kafka.LastOffset
	default:
		return kafka.FirstOffset
	}
}

func (s *Server) idempotencyGet(
	apiKey,
	idemKey,
	method,
	path,
	requestHash string,
) (int, []byte, bool, bool) {
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
		return 0, nil, false, false
	}
	if rec.requestHash != "" && requestHash != "" && rec.requestHash != requestHash {
		return 0, nil, false, true
	}
	cp := make([]byte, len(rec.body))
	copy(cp, rec.body)
	return rec.status, cp, true, false
}

func (s *Server) idempotencySet(
	apiKey,
	idemKey,
	method,
	path,
	requestHash string,
	status int,
	body []byte,
) {
	k := apiKey + "|" + method + "|" + path + "|" + idemKey
	s.state.mu.Lock()
	s.state.idempotencyResults[k] = idempotencyRecord{
		status:      status,
		body:        body,
		requestHash: requestHash,
		tsMs:        time.Now().UnixMilli(),
	}
	s.state.mu.Unlock()
}

func idempotencyRequestHash(method, path string, body []byte) string {
	hash := sha256.New()
	_, _ = hash.Write([]byte(method))
	_, _ = hash.Write([]byte{'\n'})
	_, _ = hash.Write([]byte(path))
	_, _ = hash.Write([]byte{'\n'})
	_, _ = hash.Write(body)
	return hex.EncodeToString(hash.Sum(nil))
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

func (s *Server) allowPublicRate(clientKey string, nowMs int64) bool {
	if s.cfg.PublicRateLimitPerMinute <= 0 {
		return true
	}
	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	window := nowMs - 60_000
	series := s.state.publicRateWindow[clientKey]
	keep := series[:0]
	for _, ts := range series {
		if ts >= window {
			keep = append(keep, ts)
		}
	}
	if len(keep) >= s.cfg.PublicRateLimitPerMinute {
		s.state.publicRateWindow[clientKey] = keep
		s.state.publicRateLimited++
		return false
	}
	keep = append(keep, nowMs)
	s.state.publicRateWindow[clientKey] = keep
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

func parseInt64Any(raw interface{}) (int64, bool) {
	switch v := raw.(type) {
	case nil:
		return 0, false
	case float64:
		return int64(v), true
	case float32:
		return int64(v), true
	case int64:
		return v, true
	case int32:
		return int64(v), true
	case int:
		return int64(v), true
	case json.Number:
		if iv, err := v.Int64(); err == nil {
			return iv, true
		}
		if fv, err := v.Float64(); err == nil {
			return int64(fv), true
		}
		return 0, false
	case string:
		trimmed := strings.TrimSpace(v)
		if trimmed == "" {
			return 0, false
		}
		if iv, err := strconv.ParseInt(trimmed, 10, 64); err == nil {
			return iv, true
		}
		if fv, err := strconv.ParseFloat(trimmed, 64); err == nil {
			return int64(fv), true
		}
		return 0, false
	default:
		return 0, false
	}
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

func p99(values []int) int {
	if len(values) == 0 {
		return 0
	}
	sorted := make([]int, len(values))
	copy(sorted, values)
	sort.Ints(sorted)

	rank := (99*len(sorted) + 100 - 1) / 100 // ceil(0.99*n)
	if rank <= 0 {
		rank = 1
	}
	idx := rank - 1
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
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
			semconv.DeploymentEnvironment(otelEnvironment(cfg)),
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

func otelEnvironment(cfg Config) string {
	env := strings.TrimSpace(cfg.OTelEnvironment)
	if env == "" {
		return "local"
	}
	return env
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
