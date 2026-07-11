package notify

import (
	"reflect"
	"testing"
	"time"

	"github.com/Duan-JM/mews/internal/events"
)

func TestShouldSendOnlyAttentionStates(t *testing.T) {
	tests := []struct {
		status events.Status
		want   bool
	}{
		{events.StatusRunning, false},
		{events.StatusIdle, false},
		{events.StatusNeedsInput, true},
		{events.StatusDone, true},
		{events.StatusFailed, true},
	}
	for _, test := range tests {
		if got := ShouldSend(test.status); got != test.want {
			t.Fatalf("ShouldSend(%q) = %v, want %v", test.status, got, test.want)
		}
	}
}

func TestSendPassesMessageAsArgument(t *testing.T) {
	originalRun := run
	t.Cleanup(func() { run = originalRun })

	var gotName string
	var gotArgs []string
	run = func(name string, args ...string) error {
		gotName = name
		gotArgs = append([]string(nil), args...)
		return nil
	}

	event := events.Event{
		Version:   1,
		Source:    "test",
		Status:    events.StatusDone,
		Message:   `quote " and shell $(touch /tmp/nope)`,
		Timestamp: time.Now(),
	}
	if err := Send(event); err != nil {
		t.Fatalf("Send returned error: %v", err)
	}
	if gotName != "osascript" {
		t.Fatalf("command = %q, want osascript", gotName)
	}
	wantTail := []string{"--", event.Message, "Mews"}
	if !reflect.DeepEqual(gotArgs[len(gotArgs)-3:], wantTail) {
		t.Fatalf("argument tail = %#v, want %#v", gotArgs[len(gotArgs)-3:], wantTail)
	}
}

func TestSendSkipsRunningEvents(t *testing.T) {
	originalRun := run
	t.Cleanup(func() { run = originalRun })
	called := false
	run = func(string, ...string) error {
		called = true
		return nil
	}
	if err := Send(events.Event{Status: events.StatusRunning}); err != nil {
		t.Fatalf("Send returned error: %v", err)
	}
	if called {
		t.Fatal("Send invoked osascript for a running event")
	}
}
