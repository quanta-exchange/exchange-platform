package health

import "testing"

func TestPlaceholder(t *testing.T) {
	if "ok" != "ok" {
		t.Fatal("health check failed")
	}
}
