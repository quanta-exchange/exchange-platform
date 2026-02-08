package main

import (
	"math"
	"testing"
)

func TestCheckThresholds(t *testing.T) {
	base := report{
		OrderErrorRate: 0.01,
		OrderP99Ms:     120.0,
		OrderTPS:       500.0,
		WSErrorRate:    0.01,
		WSMessages:     1000,
	}
	limits := thresholds{
		MaxOrderErrorRate: 0.05,
		MaxOrderP99Ms:     200.0,
		MinOrderTPS:       300.0,
		MaxWSErrorRate:    0.10,
		MinWSMessages:     500,
	}

	if !checkThresholds(base, limits) {
		t.Fatalf("expected baseline report to pass thresholds")
	}

	cases := []struct {
		name   string
		mutate func(*report)
	}{
		{
			name: "order_error_rate",
			mutate: func(r *report) {
				r.OrderErrorRate = 0.06
			},
		},
		{
			name: "order_p99",
			mutate: func(r *report) {
				r.OrderP99Ms = 250.0
			},
		},
		{
			name: "order_tps",
			mutate: func(r *report) {
				r.OrderTPS = 100.0
			},
		},
		{
			name: "ws_error_rate",
			mutate: func(r *report) {
				r.WSErrorRate = 0.2
			},
		},
		{
			name: "ws_messages",
			mutate: func(r *report) {
				r.WSMessages = 10
			},
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			r := base
			tc.mutate(&r)
			if checkThresholds(r, limits) {
				t.Fatalf("expected threshold check to fail for case %q", tc.name)
			}
		})
	}
}

func TestPercentile(t *testing.T) {
	if got := percentile(nil, 50); got != 0 {
		t.Fatalf("expected empty percentile to be 0, got %v", got)
	}

	values := []float64{4, 1, 3, 2}
	if got := percentile(values, 50); !almostEqual(got, 2.5) {
		t.Fatalf("p50 mismatch: got %v", got)
	}
	if got := percentile(values, 95); !almostEqual(got, 3.85) {
		t.Fatalf("p95 mismatch: got %v", got)
	}
	if got := percentile(values, 100); !almostEqual(got, 4.0) {
		t.Fatalf("p100 mismatch: got %v", got)
	}
}

func TestToWSURL(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "http",
			in:   "http://localhost:8081",
			want: "ws://localhost:8081/ws",
		},
		{
			name: "https",
			in:   "https://api.example.com/v1/orders?foo=1",
			want: "wss://api.example.com/ws",
		},
		{
			name: "parse_error_fallback",
			in:   "://bad-url",
			want: "ws://localhost:8081/ws",
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got := toWSURL(tc.in)
			if got != tc.want {
				t.Fatalf("toWSURL(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestDirOf(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{in: "report.json", want: "."},
		{in: "/tmp/report.json", want: "/tmp"},
		{in: "/report.json", want: "/"},
	}
	for _, tc := range cases {
		if got := dirOf(tc.in); got != tc.want {
			t.Fatalf("dirOf(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func almostEqual(a, b float64) bool {
	return math.Abs(a-b) < 1e-9
}
