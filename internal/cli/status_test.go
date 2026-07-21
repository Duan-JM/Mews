package cli

import (
	"bytes"
	"testing"

	"github.com/Duan-JM/mews/internal/health"
)

func TestPrintAgentStatusUsesHealthObservation(t *testing.T) {
	tests := []struct {
		name       string
		socket     health.SocketStatus
		wantOutput string
	}{
		{name: "responsive", socket: health.SocketAvailable, wantOutput: "Agent: running\n"},
		{name: "missing", socket: health.SocketMissing, wantOutput: "Agent: not running\n"},
		{name: "unresponsive", socket: health.SocketUnresponsive, wantOutput: "Agent: not running\n"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			printAgentStatus(&output, health.Observation{Socket: test.socket})
			if output.String() != test.wantOutput {
				t.Fatalf("output = %q, want %q", output.String(), test.wantOutput)
			}
		})
	}
}
