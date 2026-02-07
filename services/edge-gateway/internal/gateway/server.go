package gateway

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/gorilla/websocket"
	_ "github.com/lib/pq"
)

const slowConsumerCloseCode = 4001

// Config keeps runtime settings loaded from env.
type Config struct {
	Addr        string
	DBDsn       string
	WSQueueSize int
}

type OrderRequest struct {
	Symbol      string `json:"symbol"`
	Side        string `json:"side"`
	Type        string `json:"type"`
	Price       string `json:"price"`
	Qty         string `json:"qty"`
	TimeInForce string `json:"timeInForce"`
}

type OrderAck struct {
	OrderID    string `json:"orderId"`
	Status     string `json:"status"`
	Symbol     string `json:"symbol"`
	Seq        uint64 `json:"seq"`
	AcceptedAt int64  `json:"acceptedAt"`
}

type SmokeTradeRequest struct {
	TradeID string `json:"tradeId"`
	Symbol  string `json:"symbol"`
	Price   string `json:"price"`
	Qty     string `json:"qty"`
}

type WSMessage struct {
	Type   string      `json:"type"`
	Symbol string      `json:"symbol"`
	Seq    uint64      `json:"seq"`
	Ts     int64       `json:"ts"`
	Data   interface{} `json:"data"`
}

type state struct {
	mu                 sync.Mutex
	nextSeq            uint64
	nextOrderID        uint64
	byIdempotency      map[string]OrderAck
	clients            map[*client]struct{}
	ordersTotal        uint64
	tradesTotal        uint64
	slowConsumerCloses uint64
}

type client struct {
	conn *websocket.Conn
	send chan []byte
}

type Server struct {
	cfg      Config
	router   *chi.Mux
	db       *sql.DB
	state    *state
	upgrader websocket.Upgrader
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

	db, err := sql.Open("postgres", cfg.DBDsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	s := &Server{
		cfg: cfg,
		db:  db,
		state: &state{
			nextSeq:       1,
			nextOrderID:   1,
			byIdempotency: map[string]OrderAck{},
			clients:       map[*client]struct{}{},
		},
		upgrader: websocket.Upgrader{CheckOrigin: func(_ *http.Request) bool { return true }},
	}

	r := chi.NewRouter()
	r.Get("/healthz", s.handleHealth)
	r.Get("/readyz", s.handleReady)
	r.Get("/metrics", s.handleMetrics)
	r.Post("/v1/orders", s.handleCreateOrder)
	r.Post("/v1/smoke/trades", s.handleSmokeTrade)
	r.Get("/ws", s.handleWS)
	s.router = r

	if err := s.initSchema(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Server) Router() http.Handler {
	return s.router
}

func (s *Server) Close() error {
	return s.db.Close()
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
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := s.db.PingContext(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db_unready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	s.state.mu.Lock()
	orders := s.state.ordersTotal
	trades := s.state.tradesTotal
	clients := len(s.state.clients)
	slowClose := s.state.slowConsumerCloses
	s.state.mu.Unlock()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte("edge_orders_total " + strconv.FormatUint(orders, 10) + "\n"))
	_, _ = w.Write([]byte("edge_trades_total " + strconv.FormatUint(trades, 10) + "\n"))
	_, _ = w.Write([]byte("edge_ws_clients " + strconv.Itoa(clients) + "\n"))
	_, _ = w.Write([]byte("edge_ws_slow_consumer_close_total " + strconv.FormatUint(slowClose, 10) + "\n"))
}

func (s *Server) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	idemKey := r.Header.Get("Idempotency-Key")
	if idemKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Idempotency-Key required"})
		return
	}

	var req OrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if req.Symbol == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "symbol required"})
		return
	}

	s.state.mu.Lock()
	if ack, ok := s.state.byIdempotency[idemKey]; ok {
		s.state.mu.Unlock()
		writeJSON(w, http.StatusOK, ack)
		return
	}

	seq := s.state.nextSeq
	s.state.nextSeq++
	orderID := fmt.Sprintf("ord_%d", s.state.nextOrderID)
	s.state.nextOrderID++
	nowMs := time.Now().UnixMilli()

	ack := OrderAck{
		OrderID:    orderID,
		Status:     "ACCEPTED",
		Symbol:     req.Symbol,
		Seq:        seq,
		AcceptedAt: nowMs,
	}
	s.state.byIdempotency[idemKey] = ack
	s.state.ordersTotal++
	s.state.mu.Unlock()

	log.Printf("service=edge-gateway event=order_accepted order_id=%s symbol=%s seq=%d", ack.OrderID, ack.Symbol, ack.Seq)
	writeJSON(w, http.StatusOK, ack)
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
		Type:   "TradeExecuted",
		Symbol: req.Symbol,
		Seq:    seq,
		Ts:     ts,
		Data: map[string]string{
			"tradeId": req.TradeID,
			"price":   req.Price,
			"qty":     req.Qty,
		},
	}
	candleMsg := WSMessage{
		Type:   "CandleUpdated",
		Symbol: req.Symbol,
		Seq:    seq,
		Ts:     ts,
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

	s.broadcast(tradeMsg)
	s.broadcast(candleMsg)
	writeJSON(w, http.StatusOK, map[string]interface{}{"status": "settled", "seq": seq})
}

func (s *Server) appendSettlement(ctx context.Context, req SmokeTradeRequest) error {
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
	client := &client{conn: conn, send: make(chan []byte, s.cfg.WSQueueSize)}

	s.state.mu.Lock()
	s.state.clients[client] = struct{}{}
	s.state.mu.Unlock()

	go func() {
		defer func() {
			s.state.mu.Lock()
			delete(s.state.clients, client)
			s.state.mu.Unlock()
			_ = conn.Close()
		}()
		for msg := range client.send {
			if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		}
	}()

	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			close(client.send)
			return
		}
	}
}

func (s *Server) broadcast(v interface{}) {
	payload, _ := json.Marshal(v)

	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	for c := range s.state.clients {
		select {
		case c.send <- payload:
		default:
			s.state.slowConsumerCloses++
			_ = c.conn.WriteControl(websocket.CloseMessage,
				websocket.FormatCloseMessage(slowConsumerCloseCode, "SLOW_CONSUMER"),
				time.Now().Add(1*time.Second),
			)
			close(c.send)
			delete(s.state.clients, c)
		}
	}
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
