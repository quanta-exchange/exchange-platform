package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

type wsMessage struct {
	Type    string      `json:"type"`
	Channel string      `json:"channel"`
	Symbol  string      `json:"symbol"`
	Seq     uint64      `json:"seq"`
	Ts      int64       `json:"ts"`
	Data    interface{} `json:"data"`
}

func normalizeExpect(value string) (string, error) {
	switch strings.ToLower(value) {
	case "trade":
		return "trade", nil
	case "snapshot":
		return "snapshot", nil
	case "any":
		return "any", nil
	default:
		return "", fmt.Errorf("invalid expect=%s (expected trade|snapshot|any)", value)
	}
}

func matches(msg wsMessage, symbol string, channel string, expect string) bool {
	if channel != "" && msg.Channel != channel {
		return false
	}
	if symbol != "" && msg.Symbol != symbol {
		return false
	}
	switch expect {
	case "trade":
		return msg.Type == "TradeExecuted"
	case "snapshot":
		return msg.Type == "Snapshot"
	default:
		return true
	}
}

func main() {
	url := flag.String("url", "ws://localhost:8081/ws", "websocket url")
	symbol := flag.String("symbol", "BTC-KRW", "symbol to subscribe/resume")
	channel := flag.String("channel", "trades", "channel to subscribe/resume")
	mode := flag.String("mode", "capture", "capture|resume")
	expect := flag.String("expect", "trade", "expected event kind: trade|snapshot|any")
	count := flag.Int("count", 5, "number of matching messages to collect")
	lastSeq := flag.Uint64("last-seq", 0, "last seen seq for resume mode")
	out := flag.String("out", "/tmp/ws-resume-events.jsonl", "output jsonl path")
	timeout := flag.Duration("timeout", 20*time.Second, "overall timeout")
	flag.Parse()

	if *count <= 0 {
		fmt.Fprintf(os.Stderr, "count must be > 0\n")
		os.Exit(1)
	}

	expectMode, err := normalizeExpect(*expect)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	conn, _, err := websocket.DefaultDialer.Dial(*url, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dial ws: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	var cmd map[string]interface{}
	switch *mode {
	case "capture":
		cmd = map[string]interface{}{
			"op":      "SUB",
			"channel": *channel,
			"symbol":  *symbol,
		}
	case "resume":
		cmd = map[string]interface{}{
			"op":      "RESUME",
			"channel": *channel,
			"symbol":  *symbol,
			"lastSeq": *lastSeq,
		}
	default:
		fmt.Fprintf(os.Stderr, "invalid mode=%s (expected capture|resume)\n", *mode)
		os.Exit(1)
	}

	payload, _ := json.Marshal(cmd)
	if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
		fmt.Fprintf(os.Stderr, "write command: %v\n", err)
		os.Exit(1)
	}

	f, err := os.Create(*out)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create output: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	deadline := time.Now().Add(*timeout)
	collected := 0
	firstType := ""
	maxSeq := uint64(0)
	minSeq := uint64(0)

	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(deadline)
		_, raw, err := conn.ReadMessage()
		if err != nil {
			fmt.Fprintf(os.Stderr, "read message: %v\n", err)
			os.Exit(1)
		}

		var msg wsMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			continue
		}
		if !matches(msg, *symbol, *channel, expectMode) {
			continue
		}

		if _, err := f.Write(append(raw, '\n')); err != nil {
			fmt.Fprintf(os.Stderr, "write output: %v\n", err)
			os.Exit(1)
		}

		if collected == 0 {
			minSeq = msg.Seq
			firstType = msg.Type
		}
		if msg.Seq < minSeq {
			minSeq = msg.Seq
		}
		if msg.Seq > maxSeq {
			maxSeq = msg.Seq
		}
		collected++
		if collected >= *count {
			fmt.Printf("ws_resume_mode=%s\n", *mode)
			fmt.Printf("ws_resume_expect=%s\n", expectMode)
			fmt.Printf("ws_resume_collected=%d\n", collected)
			fmt.Printf("ws_resume_first_type=%s\n", firstType)
			fmt.Printf("ws_resume_min_seq=%d\n", minSeq)
			fmt.Printf("ws_resume_last_seq=%d\n", maxSeq)
			fmt.Printf("ws_resume_out=%s\n", *out)
			return
		}
	}

	fmt.Fprintf(
		os.Stderr,
		"timed out waiting for %d matching messages mode=%s expect=%s channel=%s symbol=%s (got %d)\n",
		*count,
		*mode,
		expectMode,
		*channel,
		*symbol,
		collected,
	)
	os.Exit(1)
}
