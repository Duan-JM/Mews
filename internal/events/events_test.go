package events

import (
	"testing"
	"time"
)

func TestEventValidateAcceptsKnownStatuses(t *testing.T) {
	statuses := []Status{StatusRunning, StatusNeedsInput, StatusDone, StatusFailed, StatusIdle}
	for _, status := range statuses {
		event := Event{
			Version:   1,
			Source:    "test",
			Status:    status,
			Timestamp: time.Now(),
		}
		if err := event.Validate(); err != nil {
			t.Fatalf("Validate(%q) returned error: %v", status, err)
		}
	}
}

func TestEventValidateRejectsUnknownStatus(t *testing.T) {
	event := Event{
		Version:   1,
		Source:    "test",
		Status:    "unknown",
		Timestamp: time.Now(),
	}
	if err := event.Validate(); err == nil {
		t.Fatal("Validate accepted an unknown status")
	}
}
