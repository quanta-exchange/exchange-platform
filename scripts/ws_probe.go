package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	url := flag.String("url", "ws://localhost:8081/ws", "websocket url")
	count := flag.Int("count", 2, "message count to read")
	out := flag.String("out", "/tmp/ws_events.log", "output file")
	timeout := flag.Duration("timeout", 10*time.Second, "read timeout")
	flag.Parse()

	conn, _, err := websocket.DefaultDialer.Dial(*url, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dial ws: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()
	deadline := time.Now().Add(*timeout)
	_ = conn.SetReadDeadline(deadline)

	subCommands := []map[string]interface{}{
		{"op": "SUB", "channel": "trades", "symbol": "BTC-KRW"},
		{"op": "SUB", "channel": "candles", "symbol": "BTC-KRW"},
	}
	for _, cmd := range subCommands {
		payload, _ := json.Marshal(cmd)
		if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
			fmt.Fprintf(os.Stderr, "write sub command: %v\n", err)
			os.Exit(1)
		}
	}

	f, err := os.Create(*out)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create output: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	collected := 0
	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(deadline)
		_, message, err := conn.ReadMessage()
		if err != nil {
			fmt.Fprintf(os.Stderr, "read message: %v\n", err)
			os.Exit(1)
		}

		var parsed map[string]interface{}
		_ = json.Unmarshal(message, &parsed)
		msgType, _ := parsed["type"].(string)
		if msgType != "TradeExecuted" && msgType != "CandleUpdated" {
			continue
		}

		if _, err := f.Write(append(message, '\n')); err != nil {
			fmt.Fprintf(os.Stderr, "write output: %v\n", err)
			os.Exit(1)
		}
		collected++
		if collected >= *count {
			return
		}
	}

	fmt.Fprintf(os.Stderr, "timed out waiting for %d target ws events, got %d\n", *count, collected)
	os.Exit(1)
}
