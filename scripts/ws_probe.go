package main

import (
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
	_ = conn.SetReadDeadline(time.Now().Add(*timeout))

	f, err := os.Create(*out)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create output: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	for i := 0; i < *count; i++ {
		_, message, err := conn.ReadMessage()
		if err != nil {
			fmt.Fprintf(os.Stderr, "read message: %v\n", err)
			os.Exit(1)
		}
		if _, err := f.Write(append(message, '\n')); err != nil {
			fmt.Fprintf(os.Stderr, "write output: %v\n", err)
			os.Exit(1)
		}
	}
}
