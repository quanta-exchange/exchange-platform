package main

import (
	"log"
	"os"
	"strconv"

	"github.com/quanta-exchange/exchange-platform/services/edge-gateway/internal/gateway"
)

func main() {
	cfg := gateway.Config{
		Addr:        getenv("EDGE_ADDR", ":8080"),
		DBDsn:       getenv("EDGE_DB_DSN", "postgres://exchange:exchange@localhost:5432/exchange?sslmode=disable"),
		WSQueueSize: getenvInt("EDGE_WS_QUEUE_SIZE", 128),
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
