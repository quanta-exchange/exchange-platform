package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

type thresholds struct {
	MaxOrderErrorRate float64 `json:"max_order_error_rate"`
	MaxOrderP99Ms     float64 `json:"max_order_p99_ms"`
	MinOrderTPS       float64 `json:"min_order_tps"`
	MaxWSErrorRate    float64 `json:"max_ws_error_rate"`
	MinWSMessages     int64   `json:"min_ws_messages"`
}

type report struct {
	TimestampUTC      string  `json:"timestamp_utc"`
	Target            string  `json:"target"`
	OrdersRequested   int64   `json:"orders_requested"`
	OrdersSucceeded   int64   `json:"orders_succeeded"`
	OrdersFailed      int64   `json:"orders_failed"`
	OrderErrorRate    float64 `json:"order_error_rate"`
	OrderP50Ms        float64 `json:"order_p50_ms"`
	OrderP95Ms        float64 `json:"order_p95_ms"`
	OrderP99Ms        float64 `json:"order_p99_ms"`
	OrderTPS          float64 `json:"order_tps"`
	WSClients         int     `json:"ws_clients"`
	WSMessages        int64   `json:"ws_messages"`
	WSFailures        int64   `json:"ws_failures"`
	WSErrorRate       float64 `json:"ws_error_rate"`
	ThresholdsChecked bool    `json:"thresholds_checked"`
	ThresholdsPassed  bool    `json:"thresholds_passed"`
}

func main() {
	target := flag.String("target", "http://localhost:8081", "edge base URL")
	orders := flag.Int("orders", 500, "number of order requests")
	concurrency := flag.Int("concurrency", 20, "number of concurrent order workers")
	wsClients := flag.Int("ws-clients", 30, "number of websocket clients")
	trades := flag.Int("trades", 200, "number of smoke trades to fan-out")
	wsDurationSec := flag.Int("ws-duration-sec", 8, "ws collection duration in seconds")
	outPath := flag.String("out", "build/load/load-report.json", "output report path")
	thresholdPath := flag.String("thresholds", "", "optional thresholds json path")
	check := flag.Bool("check", false, "fail if thresholds are violated")
	flag.Parse()

	if *orders <= 0 {
		log.Fatal("orders must be > 0")
	}
	if *concurrency <= 0 {
		log.Fatal("concurrency must be > 0")
	}

	var loadedThresholds thresholds
	thresholdsLoaded := false
	if *thresholdPath != "" {
		raw, err := os.ReadFile(*thresholdPath)
		if err != nil {
			log.Fatalf("read thresholds: %v", err)
		}
		if err := json.Unmarshal(raw, &loadedThresholds); err != nil {
			log.Fatalf("parse thresholds: %v", err)
		}
		thresholdsLoaded = true
	}

	client := &http.Client{Timeout: 5 * time.Second}
	latencies := make([]float64, 0, *orders)
	latMu := sync.Mutex{}

	var sent atomic.Int64
	var success atomic.Int64
	var failed atomic.Int64

	started := time.Now()
	wg := sync.WaitGroup{}
	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for {
				n := int(sent.Add(1))
				if n > *orders {
					return
				}
				idemKey := fmt.Sprintf("load-order-%d-%d", worker, n)
				body := []byte(`{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100000000","qty":"10000","timeInForce":"GTC"}`)
				req, err := http.NewRequest(http.MethodPost, strings.TrimRight(*target, "/")+"/v1/orders", bytes.NewReader(body))
				if err != nil {
					failed.Add(1)
					continue
				}
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Idempotency-Key", idemKey)

				reqStarted := time.Now()
				resp, err := client.Do(req)
				latMs := float64(time.Since(reqStarted).Microseconds()) / 1000.0
				latMu.Lock()
				latencies = append(latencies, latMs)
				latMu.Unlock()

				if err != nil {
					failed.Add(1)
					continue
				}
				_ = resp.Body.Close()
				if resp.StatusCode >= 200 && resp.StatusCode < 300 {
					success.Add(1)
				} else {
					failed.Add(1)
				}
			}
		}(i)
	}
	wg.Wait()
	orderElapsed := time.Since(started)

	wsMessages, wsFailures := runWSFanoutLoad(*target, *wsClients, *trades, time.Duration(*wsDurationSec)*time.Second)

	p50 := percentile(latencies, 50)
	p95 := percentile(latencies, 95)
	p99 := percentile(latencies, 99)
	totalOrders := success.Load() + failed.Load()
	orderErrRate := 0.0
	if totalOrders > 0 {
		orderErrRate = float64(failed.Load()) / float64(totalOrders)
	}
	wsErrRate := 0.0
	if *wsClients > 0 {
		wsErrRate = float64(wsFailures) / float64(*wsClients)
	}
	orderTPS := 0.0
	if orderElapsed > 0 {
		orderTPS = float64(totalOrders) / orderElapsed.Seconds()
	}

	result := report{
		TimestampUTC:      time.Now().UTC().Format(time.RFC3339),
		Target:            *target,
		OrdersRequested:   int64(*orders),
		OrdersSucceeded:   success.Load(),
		OrdersFailed:      failed.Load(),
		OrderErrorRate:    orderErrRate,
		OrderP50Ms:        p50,
		OrderP95Ms:        p95,
		OrderP99Ms:        p99,
		OrderTPS:          orderTPS,
		WSClients:         *wsClients,
		WSMessages:        wsMessages,
		WSFailures:        wsFailures,
		WSErrorRate:       wsErrRate,
		ThresholdsChecked: thresholdsLoaded && *check,
		ThresholdsPassed:  true,
	}

	if thresholdsLoaded && *check {
		result.ThresholdsPassed = checkThresholds(result, loadedThresholds)
	}

	if err := os.MkdirAll(dirOf(*outPath), 0o755); err != nil {
		log.Fatalf("mkdir output dir: %v", err)
	}
	payload, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		log.Fatalf("marshal report: %v", err)
	}
	if err := os.WriteFile(*outPath, payload, 0o644); err != nil {
		log.Fatalf("write report: %v", err)
	}

	fmt.Printf("load_report=%s\n", string(payload))
	if thresholdsLoaded && *check && !result.ThresholdsPassed {
		log.Fatal("load thresholds violated")
	}
}

func runWSFanoutLoad(target string, clients int, trades int, window time.Duration) (int64, int64) {
	if clients <= 0 || trades <= 0 {
		return 0, 0
	}
	wsURL := toWSURL(target)
	var messages atomic.Int64
	var failures atomic.Int64
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	wg := sync.WaitGroup{}
	for i := 0; i < clients; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
			if err != nil {
				failures.Add(1)
				return
			}
			defer conn.Close()

			subTrades := map[string]string{"op": "SUB", "channel": "trades", "symbol": "BTC-KRW"}
			subCandles := map[string]string{"op": "SUB", "channel": "candles", "symbol": "BTC-KRW"}
			_ = conn.WriteJSON(subTrades)
			_ = conn.WriteJSON(subCandles)
			_ = conn.SetReadDeadline(time.Now().Add(window + 2*time.Second))

			for {
				select {
				case <-ctx.Done():
					return
				default:
				}
				_, data, err := conn.ReadMessage()
				if err != nil {
					return
				}
				var frame map[string]interface{}
				if err := json.Unmarshal(data, &frame); err == nil {
					if t, ok := frame["type"].(string); ok && (t == "TradeExecuted" || t == "CandleUpdated") {
						messages.Add(1)
					}
				}
			}
		}(i)
	}

	client := &http.Client{Timeout: 3 * time.Second}
	for i := 0; i < trades; i++ {
		tradeID := fmt.Sprintf("load-trade-%d-%d", time.Now().UnixNano(), i)
		body := []byte(fmt.Sprintf(`{"tradeId":"%s","symbol":"BTC-KRW","price":"100000000","qty":"10000"}`, tradeID))
		req, err := http.NewRequest(http.MethodPost, strings.TrimRight(target, "/")+"/v1/smoke/trades", bytes.NewReader(body))
		if err != nil {
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err == nil {
			_ = resp.Body.Close()
		}
	}

	time.Sleep(window)
	cancel()
	wg.Wait()
	return messages.Load(), failures.Load()
}

func checkThresholds(rep report, t thresholds) bool {
	passed := true
	if rep.OrderErrorRate > t.MaxOrderErrorRate {
		passed = false
	}
	if rep.OrderP99Ms > t.MaxOrderP99Ms {
		passed = false
	}
	if rep.OrderTPS < t.MinOrderTPS {
		passed = false
	}
	if rep.WSErrorRate > t.MaxWSErrorRate {
		passed = false
	}
	if rep.WSMessages < t.MinWSMessages {
		passed = false
	}
	return passed
}

func percentile(values []float64, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	cp := make([]float64, len(values))
	copy(cp, values)
	sort.Float64s(cp)
	rank := (p / 100.0) * float64(len(cp)-1)
	lo := int(math.Floor(rank))
	hi := int(math.Ceil(rank))
	if lo == hi {
		return cp[lo]
	}
	weight := rank - float64(lo)
	return cp[lo]*(1-weight) + cp[hi]*weight
}

func toWSURL(httpURL string) string {
	u, err := url.Parse(strings.TrimSpace(httpURL))
	if err != nil {
		return "ws://localhost:8081/ws"
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	default:
		u.Scheme = "ws"
	}
	u.Path = "/ws"
	u.RawQuery = ""
	return u.String()
}

func dirOf(path string) string {
	idx := strings.LastIndex(path, "/")
	if idx < 0 {
		return "."
	}
	if idx == 0 {
		return "/"
	}
	return path[:idx]
}
