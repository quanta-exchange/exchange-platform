package gateway

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func newTestServer(t *testing.T) *Server {
	t.Helper()
	s, err := New(Config{
		DisableDB:          true,
		WSQueueSize:        8,
		APISecrets:         map[string]string{"test-key": "secret"},
		TimestampSkew:      30 * time.Second,
		ReplayTTL:          2 * time.Minute,
		RateLimitPerMinute: 100,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	return s
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

func TestCreateOrderRequiresIdempotencyKey(t *testing.T) {
	s := newTestServer(t)
	defer func() { _ = s.Close() }()

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
	s := newTestServer(t)
	defer func() { _ = s.Close() }()

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
	s := newTestServer(t)
	defer func() { _ = s.Close() }()

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
	s := newTestServer(t)
	defer func() { _ = s.Close() }()

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
	s := newTestServer(t)
	defer func() { _ = s.Close() }()

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
	s := newTestServer(t)
	defer func() { _ = s.Close() }()

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
	s := newTestServer(t)
	defer func() { _ = s.Close() }()

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
