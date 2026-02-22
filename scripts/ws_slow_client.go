package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	url := flag.String("url", "ws://localhost:8081/ws", "websocket url")
	symbol := flag.String("symbol", "BTC-KRW", "market symbol")
	readSleep := flag.Duration("read-sleep", 250*time.Millisecond, "sleep after each received message")
	initialPause := flag.Duration("initial-pause", 0, "pause before starting reads")
	timeout := flag.Duration("timeout", 25*time.Second, "total run timeout")
	expectCloseCode := flag.Int("expect-close-code", 4001, "expected websocket close code (<=0 to disable check)")
	out := flag.String("out", "", "optional output file for received messages (JSONL)")
	flag.Parse()

	conn, _, err := websocket.DefaultDialer.Dial(*url, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dial ws: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	subscriptions := []map[string]interface{}{
		{"op": "SUB", "channel": "trades", "symbol": *symbol},
		{"op": "SUB", "channel": "candles", "symbol": *symbol, "interval": "1m"},
		{"op": "SUB", "channel": "book", "symbol": *symbol, "depth": 20},
	}
	for _, sub := range subscriptions {
		if err := conn.WriteJSON(sub); err != nil {
			fmt.Fprintf(os.Stderr, "write subscribe: %v\n", err)
			os.Exit(1)
		}
	}

	var outFile *os.File
	if *out != "" {
		outFile, err = os.Create(*out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "create output file: %v\n", err)
			os.Exit(1)
		}
		defer outFile.Close()
	}

	if *initialPause > 0 {
		time.Sleep(*initialPause)
	}

	deadline := time.Now().Add(*timeout)
	received := 0
	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(deadline)
		_, payload, err := conn.ReadMessage()
		if err != nil {
			var closeErr *websocket.CloseError
			if errors.As(err, &closeErr) {
				fmt.Printf("ws_closed=true\n")
				fmt.Printf("ws_close_code=%d\n", closeErr.Code)
				fmt.Printf("ws_close_text=%s\n", closeErr.Text)
				fmt.Printf("ws_messages=%d\n", received)
				if *expectCloseCode > 0 && closeErr.Code != *expectCloseCode {
					fmt.Fprintf(os.Stderr, "unexpected close code: got=%d want=%d\n", closeErr.Code, *expectCloseCode)
					os.Exit(1)
				}
				return
			}
			fmt.Fprintf(os.Stderr, "read message: %v\n", err)
			os.Exit(1)
		}

		received++
		if outFile != nil {
			if _, err := outFile.Write(append(payload, '\n')); err != nil {
				fmt.Fprintf(os.Stderr, "write output: %v\n", err)
				os.Exit(1)
			}
		}
		if *readSleep > 0 {
			time.Sleep(*readSleep)
		}
	}

	fmt.Printf("ws_closed=false\n")
	fmt.Printf("ws_messages=%d\n", received)
	if *expectCloseCode > 0 {
		fmt.Fprintf(os.Stderr, "expected close code %d but connection stayed open\n", *expectCloseCode)
		os.Exit(1)
	}
}
