package events

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"time"
)

type Status string

const (
	StatusRunning    Status = "running"
	StatusNeedsInput Status = "needs_input"
	StatusDone       Status = "done"
	StatusFailed     Status = "failed"
	StatusIdle       Status = "idle"
)

type Event struct {
	Version   int       `json:"version"`
	Source    string    `json:"source"`
	HookEvent string    `json:"hook_event,omitempty"`
	SessionID string    `json:"session_id,omitempty"`
	Project   string    `json:"project,omitempty"`
	TaskTitle string    `json:"task_title,omitempty"`
	Status    Status    `json:"status"`
	Message   string    `json:"message,omitempty"`
	CWD       string    `json:"cwd,omitempty"`
	PID       int       `json:"pid,omitempty"`
	Timestamp time.Time `json:"timestamp"`
}

func FromArgs(args []string) (Event, error) {
	fs := flag.NewFlagSet("notify", flag.ContinueOnError)
	source := fs.String("source", "custom", "event source")
	status := fs.String("status", "", "event status")
	project := fs.String("project", "", "project name")
	message := fs.String("message", "", "event message")
	sessionID := fs.String("session", "", "session identifier")
	hookEvent := fs.String("hook-event", "", "source hook event name")
	fs.SetOutput(io.Discard)

	if err := fs.Parse(args); err != nil {
		return Event{}, err
	}

	return Event{
		Version:   1,
		Source:    *source,
		HookEvent: *hookEvent,
		SessionID: *sessionID,
		Project:   *project,
		Status:    Status(*status),
		Message:   *message,
		Timestamp: time.Now(),
	}, nil
}

func (e Event) Validate() error {
	if e.Version != 1 {
		return fmt.Errorf("unsupported version %d", e.Version)
	}
	if e.Source == "" {
		return errors.New("source is required")
	}
	if e.Timestamp.IsZero() {
		return errors.New("timestamp is required")
	}
	switch e.Status {
	case StatusRunning, StatusNeedsInput, StatusDone, StatusFailed, StatusIdle:
		return nil
	default:
		return fmt.Errorf("unsupported status %q", e.Status)
	}
}
