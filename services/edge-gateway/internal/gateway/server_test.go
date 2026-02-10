package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	exchangev1 "github.com/quanta-exchange/exchange-platform/contracts/gen/go/exchange/v1"

	"github.com/gorilla/websocket"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func newTestServer(t *testing.T) (*Server, func()) {
	t.Helper()
	coreAddr, shutdownCore := startTestCore(t)
	s, err := New(Config{
		DisableDB:          true,
		WSQueueSize:        8,
		APISecrets:         map[string]string{"test-key": "secret"},
		TimestampSkew:      30 * time.Second,
		ReplayTTL:          2 * time.Minute,
		RateLimitPerMinute: 100,
		CoreAddr:           coreAddr,
		CoreTimeout:        2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	return s, func() {
		_ = s.Close()
		shutdownCore()
	}
}

func signHeaders(t *testing.T, method, path string, body []byte, tsMs int64) http.Header {
	t.Helper()
	h := http.Header{}
	h.Set("X-API-KEY", "test-key")
	h.Set("X-TS", strconv.FormatInt(tsMs, 10))
	canonical := method + "\n" + path + "\n" + strconv.FormatInt(tsMs, 10) + "\n" + string(body)
	h.Set("X-SIGNATURE", sign("secret", canonical))
	return h
}

type stubCore struct {
	exchangev1.UnimplementedTradingCoreServiceServer
	mu  sync.Mutex
	seq uint64
}

func (s *stubCore) PlaceOrder(
	_ context.Context,
	req *exchangev1.PlaceOrderRequest,
) (*exchangev1.PlaceOrderResponse, error) {
	s.mu.Lock()
	s.seq++
	seq := s.seq
	s.mu.Unlock()
	return &exchangev1.PlaceOrderResponse{
		Accepted:      true,
		OrderId:       req.OrderId,
		Status:        "ACCEPTED",
		Symbol:        req.GetMeta().GetSymbol(),
		Seq:           seq,
		AcceptedAt:    timestamppb.Now(),
		CorrelationId: req.GetMeta().GetCorrelationId(),
	}, nil
}

func (s *stubCore) CancelOrder(
	_ context.Context,
	req *exchangev1.CancelOrderRequest,
) (*exchangev1.CancelOrderResponse, error) {
	s.mu.Lock()
	s.seq++
	seq := s.seq
	s.mu.Unlock()
	return &exchangev1.CancelOrderResponse{
		Accepted:      true,
		OrderId:       req.OrderId,
		Status:        "CANCELED",
		Symbol:        req.GetMeta().GetSymbol(),
		Seq:           seq,
		CanceledAt:    timestamppb.Now(),
		CorrelationId: req.GetMeta().GetCorrelationId(),
	}, nil
}

func startTestCore(t *testing.T) (string, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := grpc.NewServer()
	exchangev1.RegisterTradingCoreServiceServer(server, &stubCore{})
	go func() {
		_ = server.Serve(listener)
	}()
	return listener.Addr().String(), func() {
		server.Stop()
		_ = listener.Close()
	}
}

func TestCreateOrderRequiresIdempotencyKey(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1","timeInForce":"GTC"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", body, time.Now().UnixMilli()) {
		req.Header[k] = vals
	}
	w := httptest.NewRecorder()

	s.Router().ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 got %d", w.Code)
	}
}

func TestCreateOrderIsIdempotent(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	payload := OrderRequest{Symbol: "BTC-KRW", Side: "BUY", Type: "LIMIT", Price: "100", Qty: "1", TimeInForce: "GTC"}
	raw, _ := json.Marshal(payload)

	first := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(raw))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", raw, time.Now().UnixMilli()) {
		first.Header[k] = vals
	}
	first.Header.Set("Idempotency-Key", "idem-1")
	w1 := httptest.NewRecorder()
	s.Router().ServeHTTP(w1, first)

	second := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(raw))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", raw, time.Now().UnixMilli()+1) {
		second.Header[k] = vals
	}
	second.Header.Set("Idempotency-Key", "idem-1")
	w2 := httptest.NewRecorder()
	s.Router().ServeHTTP(w2, second)

	if w1.Code != http.StatusOK || w2.Code != http.StatusOK {
		t.Fatalf("expected both requests to succeed: first=%d second=%d", w1.Code, w2.Code)
	}

	var a1, a2 OrderResponse
	if err := json.Unmarshal(w1.Body.Bytes(), &a1); err != nil {
		t.Fatalf("decode first response: %v", err)
	}
	if err := json.Unmarshal(w2.Body.Bytes(), &a2); err != nil {
		t.Fatalf("decode second response: %v", err)
	}
	if a1.OrderID != a2.OrderID || a1.Seq != a2.Seq {
		t.Fatalf("expected idempotent response, got %+v vs %+v", a1, a2)
	}
}

func TestRejectsInvalidSignature(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	req.Header.Set("X-API-KEY", "test-key")
	req.Header.Set("X-TS", strconv.FormatInt(time.Now().UnixMilli(), 10))
	req.Header.Set("X-SIGNATURE", "bad-signature")
	req.Header.Set("Idempotency-Key", "idem-x")
	w := httptest.NewRecorder()

	s.Router().ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 got %d", w.Code)
	}
}

func TestRejectsTimestampSkew(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1"}`)
	oldTs := time.Now().Add(-2 * time.Hour).UnixMilli()
	req := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", body, oldTs) {
		req.Header[k] = vals
	}
	req.Header.Set("Idempotency-Key", "idem-y")
	w := httptest.NewRecorder()

	s.Router().ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 got %d", w.Code)
	}
}

func TestRejectsReplayRequest(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1"}`)
	tsMs := time.Now().UnixMilli()
	headers := signHeaders(t, http.MethodPost, "/v1/orders", body, tsMs)

	first := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	for k, vals := range headers {
		first.Header[k] = vals
	}
	first.Header.Set("Idempotency-Key", "idem-a")
	w1 := httptest.NewRecorder()
	s.Router().ServeHTTP(w1, first)
	if w1.Code != http.StatusOK {
		t.Fatalf("first request failed: %d", w1.Code)
	}

	second := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	for k, vals := range headers {
		second.Header[k] = vals
	}
	second.Header.Set("Idempotency-Key", "idem-b")
	w2 := httptest.NewRecorder()
	s.Router().ServeHTTP(w2, second)
	if w2.Code != http.StatusUnauthorized {
		t.Fatalf("expected replay rejection 401 got %d", w2.Code)
	}
}

func TestOrderLifecycleCreateGetCancel(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", body, time.Now().UnixMilli()) {
		req.Header[k] = vals
	}
	req.Header.Set("Idempotency-Key", "idem-create")
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("create failed: %d", w.Code)
	}

	var created OrderResponse
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create: %v", err)
	}

	getReq := httptest.NewRequest(http.MethodGet, "/v1/orders/"+created.OrderID, nil)
	for k, vals := range signHeaders(t, http.MethodGet, "/v1/orders/"+created.OrderID, nil, time.Now().UnixMilli()+1) {
		getReq.Header[k] = vals
	}
	getW := httptest.NewRecorder()
	s.Router().ServeHTTP(getW, getReq)
	if getW.Code != http.StatusOK {
		t.Fatalf("get failed: %d", getW.Code)
	}

	cancelReq := httptest.NewRequest(http.MethodDelete, "/v1/orders/"+created.OrderID, nil)
	for k, vals := range signHeaders(t, http.MethodDelete, "/v1/orders/"+created.OrderID, nil, time.Now().UnixMilli()+2) {
		cancelReq.Header[k] = vals
	}
	cancelReq.Header.Set("Idempotency-Key", "idem-cancel")
	cancelW := httptest.NewRecorder()
	s.Router().ServeHTTP(cancelW, cancelReq)
	if cancelW.Code != http.StatusOK {
		t.Fatalf("cancel failed: %d", cancelW.Code)
	}
}

func TestTickerEndpointAfterSmokeTrade(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	body := []byte(`{"tradeId":"trade-1","symbol":"BTC-KRW","price":"100","qty":"2"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/smoke/trades", bytes.NewReader(body))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/smoke/trades", body, time.Now().UnixMilli()) {
		req.Header[k] = vals
	}
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("smoke trade failed: %d", w.Code)
	}

	tickerReq := httptest.NewRequest(http.MethodGet, "/v1/markets/BTC-KRW/ticker", nil)
	tickerW := httptest.NewRecorder()
	s.Router().ServeHTTP(tickerW, tickerReq)
	if tickerW.Code != http.StatusOK {
		t.Fatalf("ticker get failed: %d", tickerW.Code)
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(tickerW.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode ticker response: %v", err)
	}
	ticker, ok := resp["ticker"].(map[string]interface{})
	if !ok {
		t.Fatalf("missing ticker object in response: %v", resp)
	}
	data, ok := ticker["data"].(map[string]interface{})
	if !ok {
		t.Fatalf("missing ticker data payload: %v", ticker)
	}
	if data["lastPrice"] != "100" {
		t.Fatalf("unexpected lastPrice: %v", data["lastPrice"])
	}
	if data["volume24h"] != "2" {
		t.Fatalf("unexpected volume24h: %v", data["volume24h"])
	}
}

func TestSeededMarketEndpoints(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:      true,
		WSQueueSize:    8,
		SeedMarketData: true,
		CoreAddr:       coreAddr,
		CoreTimeout:    2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer func() { _ = s.Close() }()

	tickerReq := httptest.NewRequest(http.MethodGet, "/v1/markets/BTC-KRW/ticker", nil)
	tickerW := httptest.NewRecorder()
	s.Router().ServeHTTP(tickerW, tickerReq)
	if tickerW.Code != http.StatusOK {
		t.Fatalf("ticker get failed: %d", tickerW.Code)
	}

	var tickerResp map[string]interface{}
	if err := json.Unmarshal(tickerW.Body.Bytes(), &tickerResp); err != nil {
		t.Fatalf("decode ticker response: %v", err)
	}
	tickerObj, ok := tickerResp["ticker"].(map[string]interface{})
	if !ok {
		t.Fatalf("missing ticker object in response: %v", tickerResp)
	}
	tickerData, ok := tickerObj["data"].(map[string]interface{})
	if !ok {
		t.Fatalf("missing ticker data payload: %v", tickerObj)
	}
	lastPrice, _ := tickerData["lastPrice"].(string)
	if strings.TrimSpace(lastPrice) == "" {
		t.Fatalf("expected seeded ticker lastPrice, got: %v", tickerData["lastPrice"])
	}

	tradesReq := httptest.NewRequest(http.MethodGet, "/v1/markets/BTC-KRW/trades?limit=20", nil)
	tradesW := httptest.NewRecorder()
	s.Router().ServeHTTP(tradesW, tradesReq)
	if tradesW.Code != http.StatusOK {
		t.Fatalf("trades get failed: %d", tradesW.Code)
	}
	var tradesResp map[string]interface{}
	if err := json.Unmarshal(tradesW.Body.Bytes(), &tradesResp); err != nil {
		t.Fatalf("decode trades response: %v", err)
	}
	trades, ok := tradesResp["trades"].([]interface{})
	if !ok || len(trades) == 0 {
		t.Fatalf("expected seeded trades, got: %v", tradesResp["trades"])
	}

	candlesReq := httptest.NewRequest(http.MethodGet, "/v1/markets/BTC-KRW/candles?limit=20", nil)
	candlesW := httptest.NewRecorder()
	s.Router().ServeHTTP(candlesW, candlesReq)
	if candlesW.Code != http.StatusOK {
		t.Fatalf("candles get failed: %d", candlesW.Code)
	}
	var candlesResp map[string]interface{}
	if err := json.Unmarshal(candlesW.Body.Bytes(), &candlesResp); err != nil {
		t.Fatalf("decode candles response: %v", err)
	}
	candles, ok := candlesResp["candles"].([]interface{})
	if !ok || len(candles) == 0 {
		t.Fatalf("expected seeded candles, got: %v", candlesResp["candles"])
	}

	orderbookReq := httptest.NewRequest(http.MethodGet, "/v1/markets/BTC-KRW/orderbook?depth=10", nil)
	orderbookW := httptest.NewRecorder()
	s.Router().ServeHTTP(orderbookW, orderbookReq)
	if orderbookW.Code != http.StatusOK {
		t.Fatalf("orderbook get failed: %d", orderbookW.Code)
	}
	var orderbookResp map[string]interface{}
	if err := json.Unmarshal(orderbookW.Body.Bytes(), &orderbookResp); err != nil {
		t.Fatalf("decode orderbook response: %v", err)
	}
	bids, ok := orderbookResp["bids"].([]interface{})
	if !ok || len(bids) != 10 {
		t.Fatalf("expected 10 bids at depth=10, got: %v", orderbookResp["bids"])
	}
	asks, ok := orderbookResp["asks"].([]interface{})
	if !ok || len(asks) != 10 {
		t.Fatalf("expected 10 asks at depth=10, got: %v", orderbookResp["asks"])
	}
}

func TestSessionAuthAndPortfolioFlow(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:      true,
		WSQueueSize:    8,
		SeedMarketData: true,
		SessionTTL:     2 * time.Hour,
		CoreAddr:       coreAddr,
		CoreTimeout:    2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer func() { _ = s.Close() }()

	signupBody := []byte(`{"email":"alice@example.com","password":"password1234"}`)
	signupReq := httptest.NewRequest(http.MethodPost, "/v1/auth/signup", bytes.NewReader(signupBody))
	signupW := httptest.NewRecorder()
	s.Router().ServeHTTP(signupW, signupReq)
	if signupW.Code != http.StatusOK {
		t.Fatalf("signup failed: %d body=%s", signupW.Code, signupW.Body.String())
	}

	var signupResp AuthSessionResponse
	if err := json.Unmarshal(signupW.Body.Bytes(), &signupResp); err != nil {
		t.Fatalf("decode signup response: %v", err)
	}
	if signupResp.SessionToken == "" {
		t.Fatalf("missing session token")
	}

	meReq := httptest.NewRequest(http.MethodGet, "/v1/auth/me", nil)
	meReq.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	meW := httptest.NewRecorder()
	s.Router().ServeHTTP(meW, meReq)
	if meW.Code != http.StatusOK {
		t.Fatalf("me failed: %d body=%s", meW.Code, meW.Body.String())
	}

	portfolioReq := httptest.NewRequest(http.MethodGet, "/v1/account/portfolio", nil)
	portfolioReq.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	portfolioW := httptest.NewRecorder()
	s.Router().ServeHTTP(portfolioW, portfolioReq)
	if portfolioW.Code != http.StatusOK {
		t.Fatalf("portfolio failed: %d body=%s", portfolioW.Code, portfolioW.Body.String())
	}
	var portfolio map[string]interface{}
	if err := json.Unmarshal(portfolioW.Body.Bytes(), &portfolio); err != nil {
		t.Fatalf("decode portfolio response: %v", err)
	}
	if assets, ok := portfolio["assets"].([]interface{}); !ok || len(assets) == 0 {
		t.Fatalf("expected non-empty assets: %v", portfolio["assets"])
	}

	orderBody := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"1000000","qty":"0.01","timeInForce":"GTC"}`)
	orderReq := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(orderBody))
	orderReq.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	orderReq.Header.Set("Idempotency-Key", "sess-order-1")
	orderW := httptest.NewRecorder()
	s.Router().ServeHTTP(orderW, orderReq)
	if orderW.Code != http.StatusOK {
		t.Fatalf("session order failed: %d body=%s", orderW.Code, orderW.Body.String())
	}

	logoutReq := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", nil)
	logoutReq.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	logoutW := httptest.NewRecorder()
	s.Router().ServeHTTP(logoutW, logoutReq)
	if logoutW.Code != http.StatusOK {
		t.Fatalf("logout failed: %d body=%s", logoutW.Code, logoutW.Body.String())
	}

	meAfterReq := httptest.NewRequest(http.MethodGet, "/v1/auth/me", nil)
	meAfterReq.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	meAfterW := httptest.NewRecorder()
	s.Router().ServeHTTP(meAfterW, meAfterReq)
	if meAfterW.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized after logout, got %d", meAfterW.Code)
	}
}

func TestSessionOrderRejectsInsufficientBalance(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:      true,
		WSQueueSize:    8,
		SeedMarketData: true,
		SessionTTL:     2 * time.Hour,
		CoreAddr:       coreAddr,
		CoreTimeout:    2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer func() { _ = s.Close() }()

	signupBody := []byte(`{"email":"bob@example.com","password":"password1234"}`)
	signupReq := httptest.NewRequest(http.MethodPost, "/v1/auth/signup", bytes.NewReader(signupBody))
	signupW := httptest.NewRecorder()
	s.Router().ServeHTTP(signupW, signupReq)
	if signupW.Code != http.StatusOK {
		t.Fatalf("signup failed: %d body=%s", signupW.Code, signupW.Body.String())
	}

	var signupResp AuthSessionResponse
	if err := json.Unmarshal(signupW.Body.Bytes(), &signupResp); err != nil {
		t.Fatalf("decode signup response: %v", err)
	}

	orderBody := []byte(`{"symbol":"BTC-KRW","side":"SELL","type":"LIMIT","price":"100000000","qty":"10000","timeInForce":"GTC"}`)
	orderReq := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(orderBody))
	orderReq.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	orderReq.Header.Set("Idempotency-Key", "sess-order-insufficient")
	orderW := httptest.NewRecorder()
	s.Router().ServeHTTP(orderW, orderReq)
	if orderW.Code != http.StatusBadRequest {
		t.Fatalf("expected insufficient balance 400, got %d body=%s", orderW.Code, orderW.Body.String())
	}
}

func TestHealthzIncludesTraceHeader(t *testing.T) {
	prevProvider := otel.GetTracerProvider()
	tp := sdktrace.NewTracerProvider()
	otel.SetTracerProvider(tp)
	defer func() {
		_ = tp.Shutdown(context.Background())
		otel.SetTracerProvider(prevProvider)
	}()

	s, cleanup := newTestServer(t)
	defer cleanup()

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("healthz failed: %d", w.Code)
	}

	traceID := w.Header().Get("X-Trace-Id")
	if traceID == "" {
		t.Fatalf("expected X-Trace-Id header")
	}
	if traceID == "00000000000000000000000000000000" {
		t.Fatalf("expected non-zero trace id")
	}
}

func TestWebSocketUpgradeWithTraceMiddleware(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	httpSrv := httptest.NewServer(s.Router())
	defer httpSrv.Close()

	wsURL := "ws" + strings.TrimPrefix(httpSrv.URL, "http") + "/ws"
	conn, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		status := 0
		body := ""
		if resp != nil {
			status = resp.StatusCode
			if resp.Body != nil {
				raw, _ := io.ReadAll(resp.Body)
				body = string(raw)
			}
		}
		t.Fatalf("websocket dial failed: err=%v status=%d body=%q", err, status, body)
	}
	defer conn.Close()

	if resp == nil || resp.StatusCode != http.StatusSwitchingProtocols {
		code := 0
		if resp != nil {
			code = resp.StatusCode
		}
		t.Fatalf("expected websocket upgrade 101, got %d", code)
	}

	if err := conn.WriteJSON(map[string]interface{}{
		"op":      "SUB",
		"channel": "trades",
		"symbol":  "BTC-KRW",
	}); err != nil {
		t.Fatalf("write subscribe frame: %v", err)
	}
}
