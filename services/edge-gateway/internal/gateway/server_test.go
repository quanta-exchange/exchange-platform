package gateway

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lib/pq"
	exchangev1 "github.com/quanta-exchange/exchange-platform/contracts/gen/go/exchange/v1"

	"github.com/gorilla/websocket"
	"github.com/segmentio/kafka-go"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const testAPISecret = "test-secret-123456"

func newTestServer(t *testing.T) (*Server, func()) {
	t.Helper()
	coreAddr, shutdownCore := startTestCore(t)
	s, err := New(Config{
		DisableDB:          true,
		WSQueueSize:        8,
		APISecrets:         map[string]string{"test-key": testAPISecret},
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

func prodBaselineConfig(coreAddr string) Config {
	return Config{
		DisableDB:                true,
		WSQueueSize:              8,
		Environment:              "prod",
		APISecrets:               map[string]string{"prod-key": "prod-secret-1234567890"},
		AllowInsecureNoAuth:      false,
		EnableSmokeRoutes:        false,
		SeedMarketData:           false,
		OTelInsecure:             false,
		WSAllowedOrigins:         []string{"https://app.exchange.test"},
		CoreAddr:                 coreAddr,
		CoreTimeout:              2 * time.Second,
		RateLimitPerMinute:       100,
		PublicRateLimitPerMinute: 100,
	}
}

func signHeaders(t *testing.T, method, path string, body []byte, tsMs int64) http.Header {
	t.Helper()
	h := http.Header{}
	h.Set("X-API-KEY", "test-key")
	h.Set("X-TS", strconv.FormatInt(tsMs, 10))
	canonical := method + "\n" + path + "\n" + strconv.FormatInt(tsMs, 10) + "\n" + string(body)
	h.Set("X-SIGNATURE", sign(testAPISecret, canonical))
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

func writeSignedPolicyFixture(t *testing.T, policyBody []byte) (policyPath string, signaturePath string, publicKeyPath string) {
	t.Helper()

	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate rsa key: %v", err)
	}
	pubRaw, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatalf("marshal public key: %v", err)
	}

	hash := sha256.Sum256(policyBody)
	signature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA256, hash[:])
	if err != nil {
		t.Fatalf("sign policy: %v", err)
	}

	dir := t.TempDir()
	policyPath = filepath.Join(dir, "policy.json")
	signaturePath = filepath.Join(dir, "policy.sig")
	publicKeyPath = filepath.Join(dir, "policy.pub.pem")

	if err := os.WriteFile(policyPath, policyBody, 0o600); err != nil {
		t.Fatalf("write policy file: %v", err)
	}
	if err := os.WriteFile(signaturePath, signature, 0o600); err != nil {
		t.Fatalf("write signature file: %v", err)
	}

	pemRaw := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubRaw})
	if err := os.WriteFile(publicKeyPath, pemRaw, 0o600); err != nil {
		t.Fatalf("write public key file: %v", err)
	}
	return policyPath, signaturePath, publicKeyPath
}

func TestNewRejectsWeakAPISecret(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	_, err := New(Config{
		DisableDB:   true,
		WSQueueSize: 8,
		APISecrets:  map[string]string{"weak-key": "short"},
		CoreAddr:    coreAddr,
		CoreTimeout: 2 * time.Second,
	})
	if err == nil {
		t.Fatalf("expected weak api secret to fail server creation")
	}
	if !strings.Contains(err.Error(), "at least 16 characters") {
		t.Fatalf("unexpected weak secret error: %v", err)
	}
}

func TestNewRejectsMissingSignedPolicyFiles(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	_, err := New(Config{
		DisableDB:           true,
		WSQueueSize:         8,
		CoreAddr:            coreAddr,
		CoreTimeout:         2 * time.Second,
		PolicyRequireSigned: true,
	})
	if err == nil {
		t.Fatalf("expected signed policy requirement to fail without files")
	}
	if !strings.Contains(err.Error(), "signed policy required") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestNewAcceptsValidSignedPolicy(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	policyPath, signaturePath, publicKeyPath := writeSignedPolicyFixture(t, []byte(`{"policyVersion":"v1"}`))

	s, err := New(Config{
		DisableDB:           true,
		WSQueueSize:         8,
		CoreAddr:            coreAddr,
		CoreTimeout:         2 * time.Second,
		PolicyRequireSigned: true,
		PolicyFile:          policyPath,
		PolicySignatureFile: signaturePath,
		PolicyPublicKeyFile: publicKeyPath,
	})
	if err != nil {
		t.Fatalf("expected valid signed policy to pass, got err=%v", err)
	}
	_ = s.Close()
}

func TestNewRejectsInvalidSignedPolicy(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	policyPath, signaturePath, publicKeyPath := writeSignedPolicyFixture(t, []byte(`{"policyVersion":"v1"}`))
	if err := os.WriteFile(policyPath, []byte(`{"policyVersion":"v2"}`), 0o600); err != nil {
		t.Fatalf("mutate policy file: %v", err)
	}

	_, err := New(Config{
		DisableDB:           true,
		WSQueueSize:         8,
		CoreAddr:            coreAddr,
		CoreTimeout:         2 * time.Second,
		PolicyRequireSigned: true,
		PolicyFile:          policyPath,
		PolicySignatureFile: signaturePath,
		PolicyPublicKeyFile: publicKeyPath,
	})
	if err == nil {
		t.Fatalf("expected invalid signature to fail")
	}
	if !strings.Contains(err.Error(), "policy signature verification failed") {
		t.Fatalf("unexpected invalid signature error: %v", err)
	}
}

func TestReadyzFailsWhenCoreConnectionClosed(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	if s.coreConn == nil {
		t.Fatalf("expected core connection")
	}
	_ = s.coreConn.Close()

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 got %d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "core_unready") {
		t.Fatalf("expected core_unready body, got %s", w.Body.String())
	}
}

func TestReadyzFailsWhenTradeConsumerIsNotRunning(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	s.cfg.KafkaBrokers = "localhost:29092"
	s.state.mu.Lock()
	s.state.tradeConsumerExpected = true
	s.state.tradeConsumerRunning = false
	s.state.tradeConsumerErrorMs = 0
	s.state.mu.Unlock()

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 got %d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "trade_consumer_unready") {
		t.Fatalf("expected trade_consumer_unready body, got %s", w.Body.String())
	}
}

func TestReadyzFailsOnRecentTradeConsumerReadError(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	s.cfg.KafkaBrokers = "localhost:29092"
	s.state.mu.Lock()
	s.state.tradeConsumerExpected = true
	s.state.tradeConsumerRunning = true
	s.state.tradeConsumerErrorMs = time.Now().UnixMilli()
	s.state.mu.Unlock()

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 got %d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "trade_consumer_unready") {
		t.Fatalf("expected trade_consumer_unready body, got %s", w.Body.String())
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

func TestCreateOrderRejectsInvalidIdempotencyKey(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1","timeInForce":"GTC"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", body, time.Now().UnixMilli()) {
		req.Header[k] = vals
	}
	req.Header.Set("Idempotency-Key", "bad/key")
	w := httptest.NewRecorder()

	s.Router().ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 got %d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "invalid Idempotency-Key") {
		t.Fatalf("expected invalid idempotency key body, got %s", w.Body.String())
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
	if strings.Contains(strings.ToLower(a1.OrderID), "idem-1") {
		t.Fatalf("order id leaks idempotency key: %s", a1.OrderID)
	}
	if !strings.HasPrefix(a1.OrderID, "ord_") {
		t.Fatalf("unexpected order id format: %s", a1.OrderID)
	}
}

func TestCreateOrderIdempotencyConflictOnPayloadMismatch(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	firstPayload := OrderRequest{Symbol: "BTC-KRW", Side: "BUY", Type: "LIMIT", Price: "100", Qty: "1", TimeInForce: "GTC"}
	firstRaw, _ := json.Marshal(firstPayload)
	first := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(firstRaw))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", firstRaw, time.Now().UnixMilli()) {
		first.Header[k] = vals
	}
	first.Header.Set("Idempotency-Key", "idem-conflict")
	w1 := httptest.NewRecorder()
	s.Router().ServeHTTP(w1, first)
	if w1.Code != http.StatusOK {
		t.Fatalf("first request failed: %d body=%s", w1.Code, w1.Body.String())
	}

	secondPayload := OrderRequest{Symbol: "BTC-KRW", Side: "BUY", Type: "LIMIT", Price: "100", Qty: "2", TimeInForce: "GTC"}
	secondRaw, _ := json.Marshal(secondPayload)
	second := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(secondRaw))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", secondRaw, time.Now().UnixMilli()+1) {
		second.Header[k] = vals
	}
	second.Header.Set("Idempotency-Key", "idem-conflict")
	w2 := httptest.NewRecorder()
	s.Router().ServeHTTP(w2, second)

	if w2.Code != http.StatusConflict {
		t.Fatalf("expected 409 conflict, got %d body=%s", w2.Code, w2.Body.String())
	}
	if !strings.Contains(w2.Body.String(), "IDEMPOTENCY_CONFLICT") {
		t.Fatalf("expected IDEMPOTENCY_CONFLICT body, got %s", w2.Body.String())
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

func TestUnknownKeyAuthIsRateLimitedByClient(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()
	s.cfg.RateLimitPerMinute = 1

	body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1"}`)

	first := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	first.RemoteAddr = "203.0.113.10:40000"
	first.Header.Set("X-API-KEY", "unknown-key")
	first.Header.Set("X-TS", strconv.FormatInt(time.Now().UnixMilli(), 10))
	first.Header.Set("X-SIGNATURE", "invalid")
	first.Header.Set("Idempotency-Key", "idem-unknown-1")
	firstW := httptest.NewRecorder()
	s.Router().ServeHTTP(firstW, first)
	if firstW.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for first unknown key request, got %d body=%s", firstW.Code, firstW.Body.String())
	}

	second := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	second.RemoteAddr = "203.0.113.10:40000"
	second.Header.Set("X-API-KEY", "unknown-key")
	second.Header.Set("X-TS", strconv.FormatInt(time.Now().UnixMilli(), 10))
	second.Header.Set("X-SIGNATURE", "invalid")
	second.Header.Set("Idempotency-Key", "idem-unknown-2")
	secondW := httptest.NewRecorder()
	s.Router().ServeHTTP(secondW, second)
	if secondW.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 for repeated unknown key request, got %d body=%s", secondW.Code, secondW.Body.String())
	}
}

func TestTryReserveRejectsNonFiniteNumbers(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	if _, _, err := s.tryReserveForOrder("test-key", OrderRequest{
		Symbol: "BTC-KRW",
		Side:   "BUY",
		Type:   "LIMIT",
		Price:  "100",
		Qty:    "NaN",
	}); err == nil || !strings.Contains(err.Error(), "invalid qty") {
		t.Fatalf("expected invalid qty for NaN, got %v", err)
	}

	if _, _, err := s.tryReserveForOrder("test-key", OrderRequest{
		Symbol: "BTC-KRW",
		Side:   "BUY",
		Type:   "LIMIT",
		Price:  "Inf",
		Qty:    "1",
	}); err == nil || !strings.Contains(err.Error(), "invalid price") {
		t.Fatalf("expected invalid price for Inf, got %v", err)
	}
}

func TestApplyReserveRollsBackOnPersistFailure(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	s.state.mu.Lock()
	s.state.wallets["test-key"] = map[string]walletBalance{
		"KRW": {Available: 100, Hold: 0},
	}
	s.state.mu.Unlock()

	db, err := sql.Open("postgres", "postgres://localhost:1/invalid?sslmode=disable")
	if err != nil {
		t.Fatalf("open failing db handle: %v", err)
	}
	defer db.Close()
	s.db = db

	_, applyErr := s.applyReserve("test-key", "KRW", 10)
	if applyErr == nil {
		t.Fatalf("expected persist failure")
	}

	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	krw := s.state.wallets["test-key"]["KRW"]
	if krw.Available != 100 || krw.Hold != 0 {
		t.Fatalf("wallet should be rolled back after persist failure: %+v", krw)
	}
	if s.state.walletPersistErrors == 0 {
		t.Fatalf("expected wallet persist error counter increment")
	}
}

func TestReleaseReserveRollsBackOnPersistFailure(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	s.state.mu.Lock()
	s.state.wallets["test-key"] = map[string]walletBalance{
		"KRW": {Available: 0, Hold: 25},
	}
	s.state.mu.Unlock()

	db, err := sql.Open("postgres", "postgres://localhost:1/invalid?sslmode=disable")
	if err != nil {
		t.Fatalf("open failing db handle: %v", err)
	}
	defer db.Close()
	s.db = db

	_, releaseErr := s.releaseReserve("test-key", "KRW", 10)
	if releaseErr == nil {
		t.Fatalf("expected persist failure")
	}

	s.state.mu.Lock()
	defer s.state.mu.Unlock()
	krw := s.state.wallets["test-key"]["KRW"]
	if krw.Available != 0 || krw.Hold != 25 {
		t.Fatalf("wallet should be rolled back after persist failure: %+v", krw)
	}
	if s.state.walletPersistErrors == 0 {
		t.Fatalf("expected wallet persist error counter increment")
	}
}

func TestLoginReturns503WhenAuthStoreUnavailable(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	db, err := sql.Open("postgres", "postgres://localhost:1/invalid?sslmode=disable")
	if err != nil {
		t.Fatalf("open db handle: %v", err)
	}
	_ = db.Close()
	s.db = db

	body := []byte(`{"email":"alice@example.com","password":"password1234"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/login", bytes.NewReader(body))
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for auth store failure, got %d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "auth_store_unavailable") {
		t.Fatalf("unexpected error body: %s", w.Body.String())
	}
}

func TestPublicRateMiddlewareRejectsBurstByIP(t *testing.T) {
	s := &Server{
		cfg: Config{
			PublicRateLimitPerMinute: 1,
		},
		state: &state{
			publicRateWindow: map[string][]int64{},
		},
	}

	handler := s.publicRateMiddleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}))

	req1 := httptest.NewRequest(http.MethodGet, "/v1/markets/BTC-KRW/ticker", nil)
	req1.RemoteAddr = "127.0.0.1:12345"
	w1 := httptest.NewRecorder()
	handler.ServeHTTP(w1, req1)
	if w1.Code != http.StatusOK {
		t.Fatalf("expected first public request to pass, got %d", w1.Code)
	}

	req2 := httptest.NewRequest(http.MethodGet, "/v1/markets/BTC-KRW/ticker", nil)
	req2.RemoteAddr = "127.0.0.1:23456"
	w2 := httptest.NewRecorder()
	handler.ServeHTTP(w2, req2)
	if w2.Code != http.StatusTooManyRequests {
		t.Fatalf("expected second public request to be rate-limited, got %d body=%s", w2.Code, w2.Body.String())
	}
	if !strings.Contains(w2.Body.String(), "TOO_MANY_REQUESTS") {
		t.Fatalf("unexpected public rate-limit body: %s", w2.Body.String())
	}
	if got := s.state.publicRateLimited; got != 1 {
		t.Fatalf("expected one public rate-limited event, got %d", got)
	}
}

func TestRejectsUnsignedTradingWhenAuthNotConfigured(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:   true,
		WSQueueSize: 8,
		CoreAddr:    coreAddr,
		CoreTimeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer func() { _ = s.Close() }()

	body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", "idem-auth-config")
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when auth is not configured, got %d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "auth_not_configured") {
		t.Fatalf("unexpected body for auth guard: %s", w.Body.String())
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

func TestCancelOrderFailsClosedWhenSymbolIsMissing(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	orderID := "ord-missing-symbol"
	s.state.mu.Lock()
	s.state.orders[orderID] = OrderRecord{
		OrderID:     orderID,
		Status:      "ACCEPTED",
		OwnerUserID: "test-key",
		Symbol:      "",
	}
	s.state.mu.Unlock()

	path := "/v1/orders/" + orderID
	req := httptest.NewRequest(http.MethodDelete, path, nil)
	for k, vals := range signHeaders(t, http.MethodDelete, path, nil, time.Now().UnixMilli()) {
		req.Header[k] = vals
	}
	req.Header.Set("Idempotency-Key", "idem-cancel-missing-symbol")
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 got %d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "order_symbol_missing") {
		t.Fatalf("expected order_symbol_missing body, got %s", w.Body.String())
	}
}

func TestCancelOrderRejectsInvalidIdempotencyKey(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	createBody := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1","timeInForce":"GTC"}`)
	createReq := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(createBody))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/orders", createBody, time.Now().UnixMilli()) {
		createReq.Header[k] = vals
	}
	createReq.Header.Set("Idempotency-Key", "idem-cancel-invalid-create")
	createW := httptest.NewRecorder()
	s.Router().ServeHTTP(createW, createReq)
	if createW.Code != http.StatusOK {
		t.Fatalf("create failed: %d body=%s", createW.Code, createW.Body.String())
	}

	var created OrderResponse
	if err := json.Unmarshal(createW.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if created.OrderID == "" {
		t.Fatalf("expected non-empty order id")
	}

	cancelPath := "/v1/orders/" + created.OrderID
	cancelReq := httptest.NewRequest(http.MethodDelete, cancelPath, nil)
	for k, vals := range signHeaders(t, http.MethodDelete, cancelPath, nil, time.Now().UnixMilli()+1) {
		cancelReq.Header[k] = vals
	}
	cancelReq.Header.Set("Idempotency-Key", "bad/key")
	cancelW := httptest.NewRecorder()
	s.Router().ServeHTTP(cancelW, cancelReq)

	if cancelW.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 got %d body=%s", cancelW.Code, cancelW.Body.String())
	}
	if !strings.Contains(cancelW.Body.String(), "invalid Idempotency-Key") {
		t.Fatalf("expected invalid idempotency key body, got %s", cancelW.Body.String())
	}
}

func TestTradeApplyDedupTransitions(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	if !s.beginTradeApply("trade-dedup-1") {
		t.Fatalf("first begin should succeed")
	}
	if s.beginTradeApply("trade-dedup-1") {
		t.Fatalf("in-progress trade should be blocked")
	}

	s.abortTradeApply("trade-dedup-1")
	if !s.beginTradeApply("trade-dedup-1") {
		t.Fatalf("begin should succeed after abort")
	}

	s.commitTradeApply("trade-dedup-1", time.Now().UnixMilli())
	if s.beginTradeApply("trade-dedup-1") {
		t.Fatalf("committed trade should not be re-applied")
	}
}

func TestConsumeTradeMessageAbortsDedupOnWalletPersistFailure(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	s.state.mu.Lock()
	s.state.wallets["buyer"] = map[string]walletBalance{
		"KRW": {Available: 1000, Hold: 0},
	}
	s.state.wallets["seller"] = map[string]walletBalance{
		"BTC": {Available: 0, Hold: 10},
	}
	s.state.mu.Unlock()

	db, err := sql.Open("postgres", "postgres://localhost:1/invalid?sslmode=disable")
	if err != nil {
		t.Fatalf("open failing db handle: %v", err)
	}
	defer db.Close()
	s.db = db

	raw := []byte(`{
		"envelope":{
			"eventId":"evt-persist-fail",
			"eventVersion":1,
			"symbol":"BTC-KRW",
			"seq":20,
			"occurredAt":"2026-02-23T12:00:00Z",
			"correlationId":"corr-persist-fail",
			"causationId":"cause-persist-fail"
		},
		"tradeId":"trade-persist-fail",
		"buyerUserId":"buyer",
		"sellerUserId":"seller",
		"price":100,
		"quantity":1,
		"quoteAmount":100
	}`)

	consumeErr := s.consumeTradeMessage(context.Background(), raw)
	if consumeErr == nil {
		t.Fatalf("expected consume trade to fail on persist error")
	}
	if !strings.Contains(consumeErr.Error(), "persist wallet balance") {
		t.Fatalf("unexpected consume error: %v", consumeErr)
	}

	s.state.mu.Lock()
	_, applied := s.state.appliedTrades["trade-persist-fail"]
	_, inProgress := s.state.applyingTrades["trade-persist-fail"]
	s.state.mu.Unlock()
	if applied {
		t.Fatalf("trade should not be marked applied on persist failure")
	}
	if inProgress {
		t.Fatalf("trade should not remain in-progress after failure")
	}
}

func TestConsumeTradeMessageRejectsMissingSeq(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	raw := []byte(`{
		"envelope":{
			"eventId":"evt-missing-seq",
			"eventVersion":1,
			"symbol":"BTC-KRW",
			"seq":0,
			"occurredAt":"2026-02-23T12:00:00Z",
			"correlationId":"corr-1",
			"causationId":"cause-1"
		},
		"tradeId":"trade-missing-seq",
		"buyerUserId":"buyer",
		"sellerUserId":"seller",
		"price":100,
		"quantity":1,
		"quoteAmount":100
	}`)

	err := s.consumeTradeMessage(context.Background(), raw)
	if err == nil || !strings.Contains(err.Error(), "missing seq") {
		t.Fatalf("expected missing seq error, got %v", err)
	}
}

func TestConsumeTradeMessageRejectsUnsupportedEventVersion(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	raw := []byte(`{
		"envelope":{
			"eventId":"evt-bad-version",
			"eventVersion":2,
			"symbol":"BTC-KRW",
			"seq":10,
			"occurredAt":"2026-02-23T12:00:00Z",
			"correlationId":"corr-2",
			"causationId":"cause-2"
		},
		"tradeId":"trade-bad-version",
		"buyerUserId":"buyer",
		"sellerUserId":"seller",
		"price":100,
		"quantity":1,
		"quoteAmount":100
	}`)

	err := s.consumeTradeMessage(context.Background(), raw)
	if err == nil || !strings.Contains(err.Error(), "unsupported eventVersion") {
		t.Fatalf("expected unsupported eventVersion error, got %v", err)
	}
}

func TestTickerEndpointAfterSmokeTrade(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:          true,
		WSQueueSize:        8,
		EnableSmokeRoutes:  true,
		APISecrets:         map[string]string{"test-key": testAPISecret},
		TimestampSkew:      30 * time.Second,
		ReplayTTL:          2 * time.Minute,
		RateLimitPerMinute: 100,
		CoreAddr:           coreAddr,
		CoreTimeout:        2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
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

func TestSmokeTradeRouteDisabledByDefault(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	body := []byte(`{"tradeId":"trade-1","symbol":"BTC-KRW","price":"100","qty":"2"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/smoke/trades", bytes.NewReader(body))
	for k, vals := range signHeaders(t, http.MethodPost, "/v1/smoke/trades", body, time.Now().UnixMilli()) {
		req.Header[k] = vals
	}
	w := httptest.NewRecorder()
	s.Router().ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Fatalf("expected smoke route to be unregistered by default, got %d", w.Code)
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
	sessionLookup := sessionLookupToken(signupResp.SessionToken)
	s.state.mu.Lock()
	_, leakedRawToken := s.state.sessionsMemory[signupResp.SessionToken]
	session, ok := s.state.sessionsMemory[sessionLookup]
	s.state.mu.Unlock()
	if leakedRawToken {
		t.Fatalf("raw session token should not be used as in-memory key")
	}
	if !ok {
		t.Fatalf("expected session to be stored in memory")
	}
	sessionRaw, err := json.Marshal(session)
	if err != nil {
		t.Fatalf("marshal session: %v", err)
	}
	if bytes.Contains(sessionRaw, []byte(`"email"`)) {
		t.Fatalf("session payload should not store email, got %s", sessionRaw)
	}
	if bytes.Contains(sessionRaw, []byte(signupResp.SessionToken)) {
		t.Fatalf("session payload should not store raw token, got %s", sessionRaw)
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

func TestSessionAuthRateLimitOnProtectedRoutes(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:                true,
		WSQueueSize:              8,
		SeedMarketData:           true,
		SessionTTL:               2 * time.Hour,
		RateLimitPerMinute:       1,
		CoreAddr:                 coreAddr,
		CoreTimeout:              2 * time.Second,
		PublicRateLimitPerMinute: 100,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer func() { _ = s.Close() }()

	signupBody := []byte(`{"email":"ratelimit-session@example.com","password":"password1234"}`)
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

	orderBody := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"1000000","qty":"0.01","timeInForce":"GTC"}`)
	orderReq1 := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(orderBody))
	orderReq1.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	orderReq1.Header.Set("Idempotency-Key", "sess-rate-1")
	orderW1 := httptest.NewRecorder()
	s.Router().ServeHTTP(orderW1, orderReq1)
	if orderW1.Code != http.StatusOK {
		t.Fatalf("first session order failed: %d body=%s", orderW1.Code, orderW1.Body.String())
	}

	orderReq2 := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(orderBody))
	orderReq2.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	orderReq2.Header.Set("Idempotency-Key", "sess-rate-2")
	orderW2 := httptest.NewRecorder()
	s.Router().ServeHTTP(orderW2, orderReq2)
	if orderW2.Code != http.StatusTooManyRequests {
		t.Fatalf("expected second session order to be rate limited, got %d body=%s", orderW2.Code, orderW2.Body.String())
	}
	if !strings.Contains(orderW2.Body.String(), "TOO_MANY_REQUESTS") {
		t.Fatalf("unexpected second order error body: %s", orderW2.Body.String())
	}
}

func TestSessionMaxPerUserEvictsOldestSession(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:         true,
		WSQueueSize:       8,
		SeedMarketData:    true,
		SessionTTL:        2 * time.Hour,
		SessionMaxPerUser: 2,
		CoreAddr:          coreAddr,
		CoreTimeout:       2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer func() { _ = s.Close() }()

	signupBody := []byte(`{"email":"cap@example.com","password":"password1234"}`)
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

	loginBody := []byte(`{"email":"cap@example.com","password":"password1234"}`)
	loginReq1 := httptest.NewRequest(http.MethodPost, "/v1/auth/login", bytes.NewReader(loginBody))
	loginW1 := httptest.NewRecorder()
	s.Router().ServeHTTP(loginW1, loginReq1)
	if loginW1.Code != http.StatusOK {
		t.Fatalf("first login failed: %d body=%s", loginW1.Code, loginW1.Body.String())
	}
	var loginResp1 AuthSessionResponse
	if err := json.Unmarshal(loginW1.Body.Bytes(), &loginResp1); err != nil {
		t.Fatalf("decode first login response: %v", err)
	}

	loginReq2 := httptest.NewRequest(http.MethodPost, "/v1/auth/login", bytes.NewReader(loginBody))
	loginW2 := httptest.NewRecorder()
	s.Router().ServeHTTP(loginW2, loginReq2)
	if loginW2.Code != http.StatusOK {
		t.Fatalf("second login failed: %d body=%s", loginW2.Code, loginW2.Body.String())
	}
	var loginResp2 AuthSessionResponse
	if err := json.Unmarshal(loginW2.Body.Bytes(), &loginResp2); err != nil {
		t.Fatalf("decode second login response: %v", err)
	}

	meOldReq := httptest.NewRequest(http.MethodGet, "/v1/auth/me", nil)
	meOldReq.Header.Set("Authorization", "Bearer "+signupResp.SessionToken)
	meOldW := httptest.NewRecorder()
	s.Router().ServeHTTP(meOldW, meOldReq)
	if meOldW.Code != http.StatusUnauthorized {
		t.Fatalf("expected oldest session token to be evicted, got %d", meOldW.Code)
	}

	meNewReq := httptest.NewRequest(http.MethodGet, "/v1/auth/me", nil)
	meNewReq.Header.Set("Authorization", "Bearer "+loginResp2.SessionToken)
	meNewW := httptest.NewRecorder()
	s.Router().ServeHTTP(meNewW, meNewReq)
	if meNewW.Code != http.StatusOK {
		t.Fatalf("expected latest session token to remain valid, got %d body=%s", meNewW.Code, meNewW.Body.String())
	}

	if loginResp1.SessionToken == "" || loginResp2.SessionToken == "" {
		t.Fatalf("expected non-empty login session tokens")
	}
	if got := s.state.sessionEvictions; got != 1 {
		t.Fatalf("expected one session eviction, got %d", got)
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

func TestParseWSSubscriptionIncludesChannelDimensions(t *testing.T) {
	bookSub, err := parseWSSubscription(WSCommand{
		Op:      "SUB",
		Channel: "book",
		Symbol:  "btc-krw",
		Depth:   7,
	})
	if err != nil {
		t.Fatalf("parse book subscription: %v", err)
	}
	if got, want := bookSub.key(), "book:BTC-KRW:depth=7"; got != want {
		t.Fatalf("unexpected book key: got=%s want=%s", got, want)
	}

	candleSub, err := parseWSSubscription(WSCommand{
		Op:       "SUB",
		Channel:  "candles",
		Symbol:   "btc-krw",
		Interval: "5m",
	})
	if err != nil {
		t.Fatalf("parse candle subscription: %v", err)
	}
	if got, want := candleSub.key(), "candles:BTC-KRW:interval=5m"; got != want {
		t.Fatalf("unexpected candle key: got=%s want=%s", got, want)
	}

	if _, err := parseWSSubscription(WSCommand{
		Op:      "SUB",
		Channel: "trades",
		Symbol:  "BTC/KRW",
	}); err == nil {
		t.Fatalf("expected invalid symbol to be rejected")
	}
}

func TestClientSubscriptionLimit(t *testing.T) {
	c := &client{
		subscribers: map[string]wsSubscription{},
	}
	if !c.upsertSubscription(wsSubscription{channel: "trades", symbol: "BTC-KRW"}, 1) {
		t.Fatalf("expected first subscription to pass")
	}
	if c.upsertSubscription(wsSubscription{channel: "book", symbol: "BTC-KRW", depth: 20}, 1) {
		t.Fatalf("expected second distinct subscription to be rejected by limit")
	}
	if !c.upsertSubscription(wsSubscription{channel: "trades", symbol: "BTC-KRW"}, 1) {
		t.Fatalf("expected update of existing subscription to pass")
	}
}

func TestClientCommandRateLimitWindow(t *testing.T) {
	c := &client{}
	now := time.Now().UnixMilli()
	if !c.allowCommand(now, 2, 1_000) {
		t.Fatalf("expected first command allowed")
	}
	if !c.allowCommand(now+10, 2, 1_000) {
		t.Fatalf("expected second command allowed")
	}
	if c.allowCommand(now+20, 2, 1_000) {
		t.Fatalf("expected third command rejected in same window")
	}
	if !c.allowCommand(now+1_100, 2, 1_000) {
		t.Fatalf("expected window rollover to allow command")
	}
}

func TestOriginAllowed(t *testing.T) {
	if !originAllowed(map[string]struct{}{}, "") {
		t.Fatalf("expected empty allowlist to allow origin")
	}
	allowed := map[string]struct{}{
		"https://app.exchange.test": {},
	}
	if !originAllowed(allowed, "https://app.exchange.test") {
		t.Fatalf("expected listed origin to pass")
	}
	if originAllowed(allowed, "https://evil.test") {
		t.Fatalf("expected unlisted origin to fail")
	}
	if originAllowed(allowed, "") {
		t.Fatalf("expected empty origin to fail when allowlist is configured")
	}
}

func TestNormalizeIdempotencyKey(t *testing.T) {
	if key, ok := normalizeIdempotencyKey("idem-OK_1:2.3"); !ok || key != "idem-OK_1:2.3" {
		t.Fatalf("expected valid key normalization, got key=%q ok=%v", key, ok)
	}
	if _, ok := normalizeIdempotencyKey(""); ok {
		t.Fatalf("expected empty key to be invalid")
	}
	if _, ok := normalizeIdempotencyKey("bad key"); ok {
		t.Fatalf("expected whitespace key to be invalid")
	}
	if _, ok := normalizeIdempotencyKey("bad/key"); ok {
		t.Fatalf("expected slash key to be invalid")
	}
	if _, ok := normalizeIdempotencyKey(strings.Repeat("a", maxIdempotencyKeyLen+1)); ok {
		t.Fatalf("expected too-long key to be invalid")
	}
}

func TestKafkaStartOffsetParser(t *testing.T) {
	if got := kafkaStartOffset("first"); got != kafka.FirstOffset {
		t.Fatalf("expected first offset, got %d", got)
	}
	if got := kafkaStartOffset("latest"); got != kafka.LastOffset {
		t.Fatalf("expected latest to map to last offset, got %d", got)
	}
	if got := kafkaStartOffset("last"); got != kafka.LastOffset {
		t.Fatalf("expected last offset, got %d", got)
	}
	if got := kafkaStartOffset("unknown"); got != kafka.FirstOffset {
		t.Fatalf("expected unknown to default to first offset, got %d", got)
	}
}

func TestOTelEnvironmentDefaultAndOverride(t *testing.T) {
	if got := otelEnvironment(Config{}); got != "local" {
		t.Fatalf("expected default otel env to be local, got %s", got)
	}
	if got := otelEnvironment(Config{OTelEnvironment: "prod"}); got != "prod" {
		t.Fatalf("expected otel env override, got %s", got)
	}
}

func TestRuntimeEnvironmentPrefersExplicitEnvironment(t *testing.T) {
	cfg := Config{
		Environment:     "production",
		OTelEnvironment: "staging",
	}
	if got := runtimeEnvironment(cfg); got != "production" {
		t.Fatalf("expected runtime environment to prefer explicit environment, got %s", got)
	}
}

func TestIsProductionEnvironmentVariants(t *testing.T) {
	cases := []Config{
		{Environment: "prod"},
		{Environment: "production"},
		{Environment: "live"},
		{Environment: "", OTelEnvironment: "prod"},
	}
	for _, cfg := range cases {
		if !isProductionEnvironment(cfg) {
			t.Fatalf("expected production environment for cfg=%+v", cfg)
		}
	}
	if isProductionEnvironment(Config{Environment: "local"}) {
		t.Fatalf("expected local to be non-production")
	}
}

func TestNewAcceptsProductionGuardrailConfig(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(prodBaselineConfig(coreAddr))
	if err != nil {
		t.Fatalf("expected prod baseline config to pass, got err=%v", err)
	}
	_ = s.Close()
}

func TestNewRejectsInsecureProductionGuardrails(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	type testCase struct {
		name     string
		mutate   func(*Config)
		wantPart string
	}
	cases := []testCase{
		{
			name: "missing api secrets",
			mutate: func(cfg *Config) {
				cfg.APISecrets = nil
			},
			wantPart: "api secrets must be configured",
		},
		{
			name: "insecure no-auth enabled",
			mutate: func(cfg *Config) {
				cfg.AllowInsecureNoAuth = true
			},
			wantPart: "allow insecure no-auth must be disabled",
		},
		{
			name: "smoke routes enabled",
			mutate: func(cfg *Config) {
				cfg.EnableSmokeRoutes = true
			},
			wantPart: "smoke routes must be disabled",
		},
		{
			name: "seed market data enabled",
			mutate: func(cfg *Config) {
				cfg.SeedMarketData = true
			},
			wantPart: "seed market data must be disabled",
		},
		{
			name: "core disabled",
			mutate: func(cfg *Config) {
				cfg.DisableCore = true
			},
			wantPart: "core connection must be enabled",
		},
		{
			name: "otel insecure enabled",
			mutate: func(cfg *Config) {
				cfg.OTelInsecure = true
			},
			wantPart: "otel insecure transport must be disabled",
		},
		{
			name: "ws origins missing",
			mutate: func(cfg *Config) {
				cfg.WSAllowedOrigins = nil
			},
			wantPart: "ws allowed origins must be configured",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := prodBaselineConfig(coreAddr)
			tc.mutate(&cfg)
			_, err := New(cfg)
			if err == nil {
				t.Fatalf("expected production guardrail error")
			}
			if !strings.Contains(err.Error(), tc.wantPart) {
				t.Fatalf("unexpected guardrail error: %v", err)
			}
		})
	}
}

func TestNewRejectsInvalidOTelSampleRatio(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	_, err := New(Config{
		DisableDB:          true,
		WSQueueSize:        8,
		APISecrets:         map[string]string{"test-key": testAPISecret},
		TimestampSkew:      30 * time.Second,
		ReplayTTL:          2 * time.Minute,
		RateLimitPerMinute: 100,
		CoreAddr:           coreAddr,
		CoreTimeout:        2 * time.Second,
		OTelSampleRatio:    1.5,
	})
	if err == nil {
		t.Fatalf("expected invalid otel sample ratio to fail")
	}
	if !strings.Contains(err.Error(), "otel sample ratio must be in (0,1]") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestNewDefaultsOTelSampleRatioWhenUnset(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:          true,
		WSQueueSize:        8,
		APISecrets:         map[string]string{"test-key": testAPISecret},
		TimestampSkew:      30 * time.Second,
		ReplayTTL:          2 * time.Minute,
		RateLimitPerMinute: 100,
		CoreAddr:           coreAddr,
		CoreTimeout:        2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer s.Close()

	if got := s.cfg.OTelSampleRatio; got != 0.1 {
		t.Fatalf("expected default otel sample ratio 0.1, got %f", got)
	}
}

func TestIsUniqueViolationError(t *testing.T) {
	if !isUniqueViolationError(&pq.Error{Code: "23505"}) {
		t.Fatalf("expected pq unique violation code to be detected")
	}
	if !isUniqueViolationError(errors.New("duplicate key value violates unique constraint")) {
		t.Fatalf("expected duplicate/unique text fallback to be detected")
	}
	if isUniqueViolationError(errors.New("syntax error at or near SELECT")) {
		t.Fatalf("expected non-unique errors to be ignored")
	}
}

func TestWSClientIPParsing(t *testing.T) {
	if got := wsClientIP("127.0.0.1:8080"); got != "127.0.0.1" {
		t.Fatalf("unexpected parsed client ip: %s", got)
	}
	if got := wsClientIP("10.0.0.5"); got != "10.0.0.5" {
		t.Fatalf("unexpected fallback client ip: %s", got)
	}
	if got := wsClientIP(""); got != "unknown" {
		t.Fatalf("expected unknown for empty remote addr, got %s", got)
	}
}

func TestWithDBTimeoutAddsDeadlineWhenMissing(t *testing.T) {
	s := &Server{cfg: Config{DBStatementTimeout: 750 * time.Millisecond}}
	ctx, cancel := s.withDBTimeout(context.Background())
	defer cancel()

	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatalf("expected db timeout context to include deadline")
	}
	remaining := time.Until(deadline)
	if remaining <= 0 || remaining > time.Second {
		t.Fatalf("unexpected db timeout deadline remaining=%s", remaining)
	}
}

func TestSessionLookupTokenHashesRawToken(t *testing.T) {
	raw := "plain-session-token"
	hashed := sessionLookupToken(raw)
	if hashed == "" {
		t.Fatalf("expected hashed lookup token")
	}
	if hashed == raw {
		t.Fatalf("expected lookup token to differ from raw token")
	}
	if hashed != sessionLookupToken(raw) {
		t.Fatalf("expected stable hash for same raw token")
	}
}

func TestWithDBTimeoutPreservesExistingDeadline(t *testing.T) {
	s := &Server{cfg: Config{DBStatementTimeout: 2 * time.Second}}
	parent, parentCancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer parentCancel()

	parentDeadline, _ := parent.Deadline()
	ctx, cancel := s.withDBTimeout(parent)
	defer cancel()
	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatalf("expected inherited deadline")
	}
	if !deadline.Equal(parentDeadline) {
		t.Fatalf("expected deadline to be preserved: got=%s want=%s", deadline, parentDeadline)
	}
}

func TestNewAppliesDBRuntimeDefaultsWhenUnset(t *testing.T) {
	coreAddr, shutdownCore := startTestCore(t)
	defer shutdownCore()

	s, err := New(Config{
		DisableDB:          true,
		WSQueueSize:        8,
		APISecrets:         map[string]string{"test-key": testAPISecret},
		TimestampSkew:      30 * time.Second,
		ReplayTTL:          2 * time.Minute,
		RateLimitPerMinute: 100,
		CoreAddr:           coreAddr,
		CoreTimeout:        2 * time.Second,
	})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer s.Close()

	if s.cfg.DBMaxOpenConns <= 0 {
		t.Fatalf("expected DBMaxOpenConns default to be set")
	}
	if s.cfg.DBMaxIdleConns <= 0 {
		t.Fatalf("expected DBMaxIdleConns default to be set")
	}
	if s.cfg.DBConnMaxLifetime <= 0 {
		t.Fatalf("expected DBConnMaxLifetime default to be set")
	}
	if s.cfg.DBConnMaxIdleTime <= 0 {
		t.Fatalf("expected DBConnMaxIdleTime default to be set")
	}
	if s.cfg.DBStatementTimeout <= 0 {
		t.Fatalf("expected DBStatementTimeout default to be set")
	}
}

func TestWSConnectionAdmissionLimits(t *testing.T) {
	s := &Server{
		cfg: Config{
			WSMaxConns:      2,
			WSMaxConnsPerIP: 1,
		},
		state: &state{
			clients:     map[*client]struct{}{},
			wsConnsByIP: map[string]int{},
		},
	}

	if !s.reserveWSConnection("10.0.0.1") {
		t.Fatalf("expected first connection to be admitted")
	}
	if s.reserveWSConnection("10.0.0.1") {
		t.Fatalf("expected per-ip cap to reject second connection from same ip")
	}
	if !s.reserveWSConnection("10.0.0.2") {
		t.Fatalf("expected second ip to be admitted within global cap")
	}
	if s.reserveWSConnection("10.0.0.3") {
		t.Fatalf("expected global cap to reject third concurrent connection")
	}
	if s.state.wsConnRejects != 2 {
		t.Fatalf("expected two rejected connections, got %d", s.state.wsConnRejects)
	}

	s.releaseWSConnection("10.0.0.1")
	if !s.reserveWSConnection("10.0.0.3") {
		t.Fatalf("expected admission after releasing one connection")
	}
}

func TestPruneOrdersLockedDropsExpiredTerminalOrders(t *testing.T) {
	now := time.Now().UnixMilli()
	s := &Server{
		cfg: Config{
			OrderRetention:  1 * time.Second,
			OrderMaxRecords: 10,
			OrderGCInterval: 0,
		},
		state: &state{
			orders: map[string]OrderRecord{
				"open":       {OrderID: "open", Status: "ACCEPTED"},
				"old-fill":   {OrderID: "old-fill", Status: "FILLED", TerminalAt: now - 5_000},
				"new-cancel": {OrderID: "new-cancel", Status: "CANCELED", TerminalAt: now - 100},
			},
		},
	}

	s.state.mu.Lock()
	s.pruneOrdersLocked(now)
	_, hasOpen := s.state.orders["open"]
	_, hasOldFill := s.state.orders["old-fill"]
	_, hasNewCancel := s.state.orders["new-cancel"]
	s.state.mu.Unlock()

	if !hasOpen {
		t.Fatalf("expected non-terminal order to remain")
	}
	if hasOldFill {
		t.Fatalf("expected expired terminal order to be pruned")
	}
	if !hasNewCancel {
		t.Fatalf("expected recent terminal order to remain")
	}
}

func TestPruneOrdersLockedBoundsTotalRecordCount(t *testing.T) {
	now := time.Now().UnixMilli()
	s := &Server{
		cfg: Config{
			OrderRetention:  24 * time.Hour,
			OrderMaxRecords: 3,
			OrderGCInterval: 0,
		},
		state: &state{
			orders: map[string]OrderRecord{
				"open": {OrderID: "open", Status: "ACCEPTED"},
				"t1":   {OrderID: "t1", Status: "FILLED", TerminalAt: now - 3_000},
				"t2":   {OrderID: "t2", Status: "CANCELED", TerminalAt: now - 2_000},
				"t3":   {OrderID: "t3", Status: "REJECTED", TerminalAt: now - 1_000},
			},
		},
	}

	s.state.mu.Lock()
	s.pruneOrdersLocked(now)
	_, hasOpen := s.state.orders["open"]
	_, hasT1 := s.state.orders["t1"]
	_, hasT2 := s.state.orders["t2"]
	_, hasT3 := s.state.orders["t3"]
	got := len(s.state.orders)
	s.state.mu.Unlock()

	if got != 3 {
		t.Fatalf("expected bounded order records=3, got %d", got)
	}
	if !hasOpen {
		t.Fatalf("expected non-terminal order to remain after pruning")
	}
	if hasT1 {
		t.Fatalf("expected oldest terminal record to be pruned")
	}
	if !hasT2 || !hasT3 {
		t.Fatalf("expected newer terminal records to remain")
	}
}

func TestSettleBuyerLockedRejectsInsufficientQuoteWithoutCreditingBase(t *testing.T) {
	s := &Server{
		state: &state{
			wallets: map[string]map[string]walletBalance{
				"buyer": {
					"KRW": {Available: 1, Hold: 0},
					"BTC": {Available: 0, Hold: 0},
				},
			},
		},
	}

	s.state.mu.Lock()
	updates := s.settleBuyerLocked("buyer", "BTC", "KRW", 2, 10)
	krw := s.state.wallets["buyer"]["KRW"]
	btc := s.state.wallets["buyer"]["BTC"]
	anomalies := s.state.settlementAnomalies
	s.state.mu.Unlock()

	if len(updates) != 0 {
		t.Fatalf("expected no settlement updates on insufficient quote balance")
	}
	if krw.Available != 1 || krw.Hold != 0 {
		t.Fatalf("unexpected KRW mutation on failed settle: %+v", krw)
	}
	if btc.Available != 0 || btc.Hold != 0 {
		t.Fatalf("unexpected BTC credit on failed settle: %+v", btc)
	}
	if anomalies != 1 {
		t.Fatalf("expected one settlement anomaly, got %d", anomalies)
	}
}

func TestSettleSellerLockedRejectsInsufficientBaseWithoutCreditingQuote(t *testing.T) {
	s := &Server{
		state: &state{
			wallets: map[string]map[string]walletBalance{
				"seller": {
					"BTC": {Available: 0.2, Hold: 0},
					"KRW": {Available: 0, Hold: 0},
				},
			},
		},
	}

	s.state.mu.Lock()
	updates := s.settleSellerLocked("seller", "BTC", "KRW", 1, 100)
	btc := s.state.wallets["seller"]["BTC"]
	krw := s.state.wallets["seller"]["KRW"]
	anomalies := s.state.settlementAnomalies
	s.state.mu.Unlock()

	if len(updates) != 0 {
		t.Fatalf("expected no settlement updates on insufficient base balance")
	}
	if btc.Available != 0.2 || btc.Hold != 0 {
		t.Fatalf("unexpected BTC mutation on failed settle: %+v", btc)
	}
	if krw.Available != 0 || krw.Hold != 0 {
		t.Fatalf("unexpected KRW credit on failed settle: %+v", krw)
	}
	if anomalies != 1 {
		t.Fatalf("expected one settlement anomaly, got %d", anomalies)
	}
}

func TestHandleResumeReplaysTradesOnlyForTradeSubscription(t *testing.T) {
	s := &Server{
		state: &state{
			historyBySymbol: map[string][]WSMessage{
				"BTC-KRW": {
					{Type: "TradeExecuted", Channel: "trades", Symbol: "BTC-KRW", Seq: 10, Ts: 1, Data: map[string]string{"tradeId": "t-10"}},
					{Type: "CandleUpdated", Channel: "candles", Symbol: "BTC-KRW", Seq: 10, Ts: 1, Data: map[string]interface{}{"interval": "1m"}},
					{Type: "TradeExecuted", Channel: "trades", Symbol: "BTC-KRW", Seq: 11, Ts: 2, Data: map[string]string{"tradeId": "t-11"}},
				},
			},
		},
	}
	c := &client{
		send:        make(chan []byte, 8),
		conflated:   map[string][]byte{},
		subscribers: map[string]wsSubscription{},
	}

	s.handleResume(c, wsSubscription{channel: "trades", symbol: "BTC-KRW"}, 9)
	if got := len(c.send); got != 2 {
		t.Fatalf("expected two replayed trade events, got %d", got)
	}
	for i := 0; i < 2; i++ {
		raw := <-c.send
		var msg WSMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			t.Fatalf("decode replayed message: %v", err)
		}
		if msg.Channel != "trades" {
			t.Fatalf("expected trades channel replay, got %s", msg.Channel)
		}
	}
}

func TestHandleResumeTradesGapSendsMissedThenSnapshot(t *testing.T) {
	s := &Server{
		state: &state{
			historyBySymbol: map[string][]WSMessage{
				"BTC-KRW": {
					{Type: "TradeExecuted", Channel: "trades", Symbol: "BTC-KRW", Seq: 50, Ts: 1, Data: map[string]string{"tradeId": "t-50"}},
				},
			},
			cacheMemory: map[string][]byte{},
		},
	}
	c := &client{
		send:        make(chan []byte, 8),
		conflated:   map[string][]byte{},
		subscribers: map[string]wsSubscription{},
	}

	s.handleResume(c, wsSubscription{channel: "trades", symbol: "BTC-KRW"}, 10)
	if got := s.state.wsResumeGaps; got != 1 {
		t.Fatalf("expected ws resume gap counter increment, got %d", got)
	}

	if got := len(c.send); got != 2 {
		t.Fatalf("expected missed+snapshot on trade gap, got %d", got)
	}

	var missed WSMessage
	if err := json.Unmarshal(<-c.send, &missed); err != nil {
		t.Fatalf("decode missed message: %v", err)
	}
	if missed.Type != "Missed" || missed.Channel != "trades" {
		t.Fatalf("unexpected missed payload: %+v", missed)
	}
	data, ok := missed.Data.(map[string]interface{})
	if !ok {
		t.Fatalf("expected missed data map, got=%T", missed.Data)
	}
	if reason, _ := data["reason"].(string); reason != "HISTORY_GAP" {
		t.Fatalf("unexpected missed reason: %v", data["reason"])
	}

	var snap WSMessage
	if err := json.Unmarshal(<-c.send, &snap); err != nil {
		t.Fatalf("decode snapshot message: %v", err)
	}
	if snap.Type != "Snapshot" || snap.Channel != "trades" {
		t.Fatalf("unexpected snapshot payload: %+v", snap)
	}
}

func TestHandleResumeUsesSnapshotForConflatedChannels(t *testing.T) {
	s := &Server{
		state: &state{
			historyBySymbol: map[string][]WSMessage{
				"BTC-KRW": {
					{Type: "CandleUpdated", Channel: "candles", Symbol: "BTC-KRW", Seq: 20, Ts: 1, Data: map[string]interface{}{"interval": "1m"}},
				},
			},
			cacheMemory: map[string][]byte{},
		},
	}
	c := &client{
		send:        make(chan []byte, 8),
		conflated:   map[string][]byte{},
		subscribers: map[string]wsSubscription{},
	}
	sub := wsSubscription{channel: "candles", symbol: "BTC-KRW", interval: "1m"}
	s.handleResume(c, sub, 19)

	if got := len(c.send); got != 0 {
		t.Fatalf("expected no direct queue replay for conflated channel, got %d", got)
	}
	payload, ok := c.conflated[sub.key()]
	if !ok {
		t.Fatalf("expected conflated snapshot payload for key %s", sub.key())
	}
	var msg WSMessage
	if err := json.Unmarshal(payload, &msg); err != nil {
		t.Fatalf("decode snapshot payload: %v", err)
	}
	if msg.Type != "Snapshot" || msg.Channel != "candles" {
		t.Fatalf("unexpected snapshot payload: %+v", msg)
	}
}

func TestSendToClientConflationDropsPreviousMessage(t *testing.T) {
	s := &Server{state: &state{}}
	c := &client{
		send:        make(chan []byte, 1),
		conflated:   map[string][]byte{},
		subscribers: map[string]wsSubscription{},
	}
	msg := WSMessage{
		Type:    "OrderbookUpdated",
		Channel: "book",
		Symbol:  "BTC-KRW",
		Seq:     1,
		Ts:      time.Now().UnixMilli(),
		Data: map[string]interface{}{
			"depth": 20,
			"bids":  []interface{}{},
			"asks":  []interface{}{},
		},
	}

	s.sendToClient(c, msg, true, "book:BTC-KRW:depth=20")
	if got := s.state.wsDroppedMsgs; got != 0 {
		t.Fatalf("unexpected dropped count after first conflation write: %d", got)
	}
	s.sendToClient(c, msg, true, "book:BTC-KRW:depth=20")
	if got := s.state.wsDroppedMsgs; got != 1 {
		t.Fatalf("expected one dropped message for same conflation key, got %d", got)
	}

	s.sendToClient(c, msg, true, "book:BTC-KRW:depth=10")
	if got := len(c.conflated); got != 2 {
		t.Fatalf("expected two conflated buckets (depth-aware), got %d", got)
	}
}

func TestSendToClientQueueOverflowMarksSlowConsumer(t *testing.T) {
	s := &Server{state: &state{}}
	c := &client{
		send:        make(chan []byte, 1),
		conflated:   map[string][]byte{},
		subscribers: map[string]wsSubscription{},
	}
	c.send <- []byte(`{"type":"seed"}`)

	s.sendToClient(c, WSMessage{
		Type:    "TradeExecuted",
		Channel: "trades",
		Symbol:  "BTC-KRW",
		Seq:     1,
		Ts:      time.Now().UnixMilli(),
		Data:    map[string]string{"tradeId": "t-1"},
	}, false, "")

	if got := s.state.slowConsumerCloses; got != 1 {
		t.Fatalf("expected one slow-consumer close, got %d", got)
	}
	if got := s.state.wsDroppedMsgs; got != 1 {
		t.Fatalf("expected one dropped trade on overflow, got %d", got)
	}

	_, ok := <-c.send
	if !ok {
		t.Fatalf("expected buffered message before close")
	}
	_, ok = <-c.send
	if ok {
		t.Fatalf("expected closed queue after overflow")
	}
}

func TestMetricsExposeWsBackpressureSeries(t *testing.T) {
	c1 := &client{send: make(chan []byte, 8)}
	c2 := &client{send: make(chan []byte, 8)}
	c3 := &client{send: make(chan []byte, 8)}
	c2.send <- []byte("a")
	c2.send <- []byte("b")
	c3.send <- []byte("1")
	c3.send <- []byte("2")
	c3.send <- []byte("3")
	c3.send <- []byte("4")

	s := &Server{
		state: &state{
			clients: map[*client]struct{}{
				c1: {},
				c2: {},
				c3: {},
			},
			slowConsumerCloses:  2,
			wsPolicyCloses:      4,
			wsRateLimitCloses:   3,
			wsConnRejects:       5,
			wsDroppedMsgs:       7,
			wsResumeGaps:        4,
			publicRateLimited:   6,
			settlementAnomalies: 8,
			sessionEvictions:    9,
			authFailReason: map[string]uint64{
				"unknown_key":   3,
				"bad_signature": 2,
			},
		},
	}

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()
	s.handleMetrics(w, req)
	body := w.Body.String()

	assertMetric := func(name, value string) {
		t.Helper()
		line := name + " " + value
		if !strings.Contains(body, line+"\n") {
			t.Fatalf("missing metric line %q in body=%q", line, body)
		}
	}

	assertMetric("ws_active_conns", "3")
	assertMetric("ws_send_queue_p99", "4")
	assertMetric("ws_dropped_msgs", "7")
	assertMetric("ws_resume_gaps", "4")
	assertMetric("ws_slow_closes", "2")
	assertMetric("ws_policy_closes", "4")
	assertMetric("ws_command_rate_limit_closes", "3")
	assertMetric("ws_connection_rejects", "5")
	assertMetric("public_rate_limited", "6")
	assertMetric("settlement_anomalies", "8")
	assertMetric("session_evictions", "9")
	assertMetric("edge_auth_fail_total", "5")
	assertMetric("edge_ws_close_policy_total", "4")
	assertMetric("edge_ws_close_ratelimit_total", "3")
	assertMetric("edge_ws_connection_reject_total", "5")
	assertMetric("edge_public_rate_limited_total", "6")
	assertMetric("edge_settlement_anomaly_total", "8")
	assertMetric("edge_session_eviction_total", "9")
	assertMetric("edge_auth_fail_reason_total{reason=\"bad_signature\"}", "2")
	assertMetric("edge_auth_fail_reason_total{reason=\"unknown_key\"}", "3")
}

func TestHTTPServerTimeoutsConfigured(t *testing.T) {
	s, cleanup := newTestServer(t)
	defer cleanup()

	httpServer := s.httpServer()
	if httpServer.ReadTimeout != 10*time.Second {
		t.Fatalf("unexpected read timeout: %s", httpServer.ReadTimeout)
	}
	if httpServer.ReadHeaderTimeout != 5*time.Second {
		t.Fatalf("unexpected read-header timeout: %s", httpServer.ReadHeaderTimeout)
	}
	if httpServer.WriteTimeout != 15*time.Second {
		t.Fatalf("unexpected write timeout: %s", httpServer.WriteTimeout)
	}
	if httpServer.IdleTimeout != 60*time.Second {
		t.Fatalf("unexpected idle timeout: %s", httpServer.IdleTimeout)
	}
	if httpServer.MaxHeaderBytes != 1<<20 {
		t.Fatalf("unexpected max header bytes: %d", httpServer.MaxHeaderBytes)
	}
}
