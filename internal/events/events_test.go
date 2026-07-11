package events

import (
	"strings"
	"testing"
	"time"
)

func TestEventValidationRejectsOversizedMetadata(t *testing.T) {
	event := Event{
		Version:   1,
		Source:    "test",
		Status:    StatusDone,
		Message:   strings.Repeat("x", 1025),
		Timestamp: time.Now(),
	}
	if err := event.Validate(); err == nil || !strings.Contains(err.Error(), "message exceeds") {
		t.Fatalf("Validate error = %v, want message length error", err)
	}
}

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
