package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/store"
)

var deliverEventFn = deliverEvent

func runNotify(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	event, err := events.FromArgs(args)
	if err != nil {
		fmt.Fprintf(stderr, "Invalid event: %v\n", err)
		return 2
	}
	if event.HookEvent != "" {
		if err := enrichFromHookPayload(&event, stdin); err != nil {
			fmt.Fprintf(stderr, "Invalid hook payload: %v\n", err)
			return 2
		}
	}
	enrichRuntimeContext(&event)
	if err := event.Validate(); err != nil {
		fmt.Fprintf(stderr, "Invalid event: %v\n", err)
		return 2
	}
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	if err := deliverEvent(paths, &event, stderr); err != nil {
		fmt.Fprintf(stderr, "Could not deliver event: %v\n", err)
		return 1
	}

	fmt.Fprintf(stdout, "Mews event accepted: %s %s\n", event.Source, event.Status)
	return 0
}

func runHook(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printHookUsage(stderr)
		return 2
	}
	switch args[0] {
	case "codex":
		return runCodexHook(args[1:], stdin, stdout, stderr)
	case "copilot":
		return runCopilotHook(args[1:], stdin, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "Unknown hook source: %s\n", args[0])
		return 2
	}
}

func runCodexHook(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) > 1 {
		printHookUsage(stderr)
		return 2
	}

	payload := stdin
	if len(args) == 1 {
		payload = strings.NewReader(args[0])
	}
	event := events.Event{
		Version:   1,
		Source:    "codex",
		HookEvent: "agent-turn-complete",
		Status:    events.StatusDone,
		Message:   "Codex turn completed",
		Timestamp: time.Now(),
	}
	if err := enrichFromHookPayload(&event, payload); err != nil {
		fmt.Fprintf(stderr, "Invalid Codex hook payload: %v\n", err)
		return 2
	}
	if event.HookEvent == "" {
		event.HookEvent = "agent-turn-complete"
	}
	enrichRuntimeContext(&event)
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	if err := deliverEvent(paths, &event, stderr); err != nil {
		fmt.Fprintf(stderr, "Could not deliver Codex event: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Mews event sent: %s %s\n", event.Source, event.Status)
	return 0
}

func printHookUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: mw hook codex [payload]")
	fmt.Fprintln(w, "       mw hook copilot <event>")
}

func enrichFromHookPayload(event *events.Event, stdin io.Reader) error {
	data, err := io.ReadAll(stdin)
	if err != nil {
		return err
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return nil
	}

	var payload any
	if err := json.Unmarshal(data, &payload); err != nil {
		return err
	}

	if event.CWD == "" {
		event.CWD = firstString(payload, "cwd", "workspace", "workspacePath", "repositoryPath")
	}
	if event.SessionID == "" {
		event.SessionID = firstString(
			payload,
			"session_id",
			"sessionId",
			"sessionID",
			"session",
			"thread-id",
			"thread_id",
		)
	}
	if hookEvent := firstString(payload, "type", "hook_event", "hookEvent"); hookEvent != "" {
		event.HookEvent = hookEvent
	}
	if event.Project == "" && event.CWD != "" {
		event.Project = filepath.Base(event.CWD)
	}

	if state, configured, err := store.LoadSetupState(); err == nil && configured && state.IncludeTaskTitle {
		title := firstString(payload, "task_title", "taskTitle", "title", "prompt", "userPrompt", "message")
		event.TaskTitle = truncate(cleanOneLine(title), 80)
	}
	event.Message = notificationMessage(event)
	return nil
}

func firstString(value any, keys ...string) string {
	switch typed := value.(type) {
	case map[string]any:
		for _, key := range keys {
			if raw, ok := typed[key]; ok {
				if text, ok := raw.(string); ok && strings.TrimSpace(text) != "" {
					return text
				}
			}
		}
		for _, raw := range typed {
			if text := firstString(raw, keys...); text != "" {
				return text
			}
		}
	case []any:
		for _, raw := range typed {
			if text := firstString(raw, keys...); text != "" {
				return text
			}
		}
	}
	return ""
}

func notificationMessage(event *events.Event) string {
	action := string(event.Status)
	if event.HookEvent == "subagentRunning" {
		action = "subagents running"
	}
	switch event.Status {
	case events.StatusDone:
		action = "done"
	case events.StatusFailed:
		action = "failed"
	case events.StatusIdle:
		action = "idle"
	case events.StatusNeedsInput:
		action = "needs input"
	}

	source := event.Source
	if event.AgentScope == events.AgentScopeSubagent {
		source += " subagent"
	}
	message := fmt.Sprintf("%s %s", source, action)
	if event.Project != "" {
		message = fmt.Sprintf("%s: %s", message, event.Project)
	}
	if event.TaskTitle != "" {
		message = fmt.Sprintf("%s - %s", message, event.TaskTitle)
	}
	return message
}

func cleanOneLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func truncate(value string, maxLength int) string {
	runes := []rune(value)
	if len(runes) <= maxLength {
		return value
	}
	if maxLength <= 1 {
		return string(runes[:maxLength])
	}
	return string(runes[:maxLength-3]) + "..."
}

func deliverEvent(paths store.StorePaths, event *events.Event, _ io.Writer) error {
	if err := ipc.SendEvent(paths.Socket, event); err == nil {
		return nil
	} else if !errors.Is(err, ipc.ErrUnavailable) {
		return err
	}
	if err := store.AppendEvent(paths.Events, event); err != nil {
		return err
	}
	return nil
}
