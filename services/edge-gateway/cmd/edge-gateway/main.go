package main

import (
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/quanta-exchange/exchange-platform/services/edge-gateway/internal/gateway"
)

func main() {
	cfg := gateway.Config{
		Addr:               getenv("EDGE_ADDR", ":8080"),
		DBDsn:              getenv("EDGE_DB_DSN", "postgres://exchange:exchange@localhost:25432/exchange?sslmode=disable"),
		WSQueueSize:        getenvInt("EDGE_WS_QUEUE_SIZE", 128),
		WSWriteDelay:       time.Duration(getenvInt("EDGE_WS_WRITE_DELAY_MS", 0)) * time.Millisecond,
		WSMaxSubscriptions: getenvInt("EDGE_WS_MAX_SUBSCRIPTIONS", 64),
		WSCommandRateLimit: getenvInt("EDGE_WS_COMMAND_RATE_LIMIT", 240),
		WSCommandWindow: time.Duration(getenvInt("EDGE_WS_COMMAND_WINDOW_SEC", 60)) *
			time.Second,
		WSPingInterval:   time.Duration(getenvInt("EDGE_WS_PING_INTERVAL_SEC", 20)) * time.Second,
		WSPongTimeout:    time.Duration(getenvInt("EDGE_WS_PONG_TIMEOUT_SEC", 60)) * time.Second,
		WSReadLimitBytes: int64(getenvInt("EDGE_WS_READ_LIMIT_BYTES", 1048576)),
		WSAllowedOrigins: parseCSV(getenv("EDGE_WS_ALLOWED_ORIGINS", "")),
		DisableDB:        getenv("EDGE_DISABLE_DB", "false") == "true",
		DisableCore:      getenv("EDGE_DISABLE_CORE", "false") == "true",
		SeedMarketData:   getenv("EDGE_SEED_MARKET_DATA", "true") == "true",
		SessionTTL:       time.Duration(getenvInt("EDGE_SESSION_TTL_HOURS", 24)) * time.Hour,
		APISecrets:       parseSecrets(getenv("EDGE_API_SECRETS", "")),
		TimestampSkew: time.Duration(getenvInt("EDGE_AUTH_SKEW_SEC", 30)) *
			time.Second,
		ReplayTTL:          time.Duration(getenvInt("EDGE_REPLAY_TTL_SEC", 120)) * time.Second,
		RateLimitPerMinute: getenvInt("EDGE_RATE_LIMIT_PER_MINUTE", 1000),
		RedisAddr:          getenv("EDGE_REDIS_ADDR", ""),
		RedisPassword:      getenv("EDGE_REDIS_PASSWORD", ""),
		RedisDB:            getenvInt("EDGE_REDIS_DB", 0),
		OTelEndpoint:       getenv("EDGE_OTEL_ENDPOINT", ""),
		OTelServiceName:    getenv("EDGE_OTEL_SERVICE_NAME", "edge-gateway"),
		OTelSampleRatio:    getenvFloat("EDGE_OTEL_SAMPLE_RATIO", 1.0),
		OTelInsecure:       getenv("EDGE_OTEL_INSECURE", "true") == "true",
		CoreAddr:           getenv("EDGE_CORE_ADDR", "localhost:50051"),
		CoreTimeout:        time.Duration(getenvInt("EDGE_CORE_TIMEOUT_MS", 3000)) * time.Millisecond,
		KafkaBrokers:       getenv("EDGE_KAFKA_BROKERS", ""),
		KafkaTradeTopic:    getenv("EDGE_KAFKA_TRADE_TOPIC", "core.trade-events.v1"),
		KafkaGroupID:       getenv("EDGE_KAFKA_GROUP_ID", "edge-trades-v1"),
	}
	srv, err := gateway.New(cfg)
	if err != nil {
		log.Fatalf("failed to create gateway: %v", err)
	}
	defer func() { _ = srv.Close() }()

	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("edge-gateway stopped: %v", err)
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getenvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		parsed, err := strconv.Atoi(v)
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func getenvFloat(key string, fallback float64) float64 {
	if v := os.Getenv(key); v != "" {
		parsed, err := strconv.ParseFloat(v, 64)
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func parseSecrets(raw string) map[string]string {
	out := map[string]string{}
	if strings.TrimSpace(raw) == "" {
		return out
	}
	pairs := strings.Split(raw, ",")
	for _, p := range pairs {
		parts := strings.SplitN(strings.TrimSpace(p), ":", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		secret := strings.TrimSpace(parts[1])
		if key == "" || secret == "" {
			continue
		}
		out[key] = secret
	}
	return out
}

func parseCSV(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		value := strings.TrimSpace(part)
		if value == "" {
			continue
		}
		out = append(out, value)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
