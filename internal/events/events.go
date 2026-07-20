package events

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/Duan-JM/mews/internal/terminal"
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
	ID         string    `json:"id,omitempty"`
	Version    int       `json:"version"`
	Source     string    `json:"source"`
	HookEvent  string    `json:"hook_event,omitempty"`
	SessionID  string    `json:"session_id,omitempty"`
	Project    string    `json:"project,omitempty"`
	TaskTitle  string    `json:"task_title,omitempty"`
	Status     Status    `json:"status"`
	Message    string    `json:"message,omitempty"`
	CWD        string    `json:"cwd,omitempty"`
	PID        int       `json:"pid,omitempty"`
	Terminal   string    `json:"terminal,omitempty"`
	WindowID   string    `json:"terminal_window_id,omitempty"`
	KittyAddr  string    `json:"kitty_listen_on,omitempty"`
	TmuxSocket string    `json:"tmux_socket,omitempty"`
	TmuxPane   string    `json:"tmux_pane,omitempty"`
	Timestamp  time.Time `json:"timestamp"`
}

func FromArgs(args []string) (Event, error) {
	fs := flag.NewFlagSet("notify", flag.ContinueOnError)
	source := fs.String("source", "custom", "event source")
	status := fs.String("status", "", "event status")
	project := fs.String("project", "", "project name")
	message := fs.String("message", "", "event message")
	sessionID := fs.String("session", "", "session identifier")
	hookEvent := fs.String("hook-event", "", "source hook event name")
	cwd := fs.String("cwd", "", "working directory")
	pid := fs.Int("pid", 0, "process identifier")
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
		CWD:       *cwd,
		PID:       *pid,
		Timestamp: time.Now(),
	}, nil
}

func (e *Event) Validate() error {
	if e.Version != 1 {
		return fmt.Errorf("unsupported version %d", e.Version)
	}
	if e.Source == "" {
		return errors.New("source is required")
	}
	if e.Timestamp.IsZero() {
		return errors.New("timestamp is required")
	}
	limits := []struct {
		name  string
		value string
		max   int
	}{
		{name: "source", value: e.Source, max: 64},
		{name: "id", value: e.ID, max: 64},
		{name: "hook_event", value: e.HookEvent, max: 128},
		{name: "session_id", value: e.SessionID, max: 256},
		{name: "project", value: e.Project, max: 256},
		{name: "task_title", value: e.TaskTitle, max: 80},
		{name: "message", value: e.Message, max: 1024},
		{name: "cwd", value: e.CWD, max: 4096},
		{name: "terminal", value: e.Terminal, max: 64},
		{name: "terminal_window_id", value: e.WindowID, max: 64},
		{name: "kitty_listen_on", value: e.KittyAddr, max: 4096},
		{name: "tmux_socket", value: e.TmuxSocket, max: 4096},
		{name: "tmux_pane", value: e.TmuxPane, max: 64},
	}
	for _, field := range limits {
		if len([]rune(field.value)) > field.max {
			return fmt.Errorf("%s exceeds %d characters", field.name, field.max)
		}
	}
	if err := e.validateTerminalContext(); err != nil {
		return err
	}
	switch e.Status {
	case StatusRunning, StatusNeedsInput, StatusDone, StatusFailed, StatusIdle:
		return nil
	default:
		return fmt.Errorf("unsupported status %q", e.Status)
	}
}

func (e *Event) validateTerminalContext() error {
	if e.Terminal != "" && !terminal.IsSourceProfile(e.Terminal) {
		return fmt.Errorf("unsupported terminal %q", e.Terminal)
	}
	if e.WindowID != "" && (e.Terminal != string(terminal.Kitty) || !terminal.ValidWindowID(e.WindowID)) {
		return errors.New("invalid terminal_window_id")
	}
	if e.KittyAddr != "" && (e.Terminal != string(terminal.Kitty) || !terminal.ValidKittyListen(e.KittyAddr)) {
		return errors.New("invalid kitty_listen_on")
	}
	if (e.TmuxSocket == "") != (e.TmuxPane == "") {
		return errors.New("tmux_socket and tmux_pane must be provided together")
	}
	if e.TmuxSocket != "" &&
		(!terminal.ValidTmuxSocket(e.TmuxSocket) || !terminal.ValidTmuxPane(e.TmuxPane)) {
		return errors.New("invalid tmux context")
	}
	return nil
}
