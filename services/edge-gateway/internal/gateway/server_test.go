package gateway

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCreateOrderRequiresIdempotencyKey(t *testing.T) {
	s, err := New(Config{DBDsn: "postgres://exchange:exchange@localhost:5432/exchange?sslmode=disable"})
	if err != nil {
		t.Skipf("postgres unavailable for test setup: %v", err)
	}
	defer func() { _ = s.Close() }()

	body := strings.NewReader(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1","timeInForce":"GTC"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/orders", body)
	w := httptest.NewRecorder()

	s.Router().ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 got %d", w.Code)
	}
}

func TestCreateOrderIsIdempotent(t *testing.T) {
	s, err := New(Config{DBDsn: "postgres://exchange:exchange@localhost:5432/exchange?sslmode=disable"})
	if err != nil {
		t.Skipf("postgres unavailable for test setup: %v", err)
	}
	defer func() { _ = s.Close() }()

	payload := OrderRequest{
		Symbol:      "BTC-KRW",
		Side:        "BUY",
		Type:        "LIMIT",
		Price:       "100",
		Qty:         "1",
		TimeInForce: "GTC",
	}
	raw, _ := json.Marshal(payload)

	first := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(raw))
	first.Header.Set("Idempotency-Key", "idem-1")
	w1 := httptest.NewRecorder()
	s.Router().ServeHTTP(w1, first)

	second := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(raw))
	second.Header.Set("Idempotency-Key", "idem-1")
	w2 := httptest.NewRecorder()
	s.Router().ServeHTTP(w2, second)

	if w1.Code != http.StatusOK || w2.Code != http.StatusOK {
		t.Fatalf("expected both requests to succeed: first=%d second=%d", w1.Code, w2.Code)
	}

	var a1, a2 OrderAck
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
