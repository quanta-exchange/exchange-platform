package exchangev1

import "testing"

func TestGeneratedContractTypesCompile(t *testing.T) {
	envelope := &EventEnvelope{
		EventId:       "evt-1",
		EventVersion:  1,
		Symbol:        "BTC-KRW",
		Seq:           1,
		CorrelationId: "corr-1",
		CausationId:   "cause-1",
	}
	if envelope.Symbol != "BTC-KRW" {
		t.Fatalf("unexpected symbol: %s", envelope.Symbol)
	}
}
