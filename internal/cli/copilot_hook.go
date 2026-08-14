package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/store"
)

type copilotHookPayload struct {
	SessionID        string `json:"sessionId"`
	LegacySessionID  string `json:"session_id"`
	CWD              string `json:"cwd"`
	TranscriptPath   string `json:"transcriptPath"`
	LegacyTranscript string `json:"transcript_path"`
	AgentName        string `json:"agentName"`
	LegacyAgentName  string `json:"agent_name"`
	Recoverable      *bool  `json:"recoverable"`
}

type copilotTaskTitlePayload struct {
	TaskTitle       string `json:"taskTitle"`
	LegacyTaskTitle string `json:"task_title"`
	Title           string `json:"title"`
	Prompt          string `json:"prompt"`
	InitialPrompt   string `json:"initialPrompt"`
	Message         string `json:"message"`
}

func runCopilotHook(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		printHookUsage(stderr)
		return 2
	}
	hookEvent := args[0]
	if !supportedCopilotHook(hookEvent) {
		fmt.Fprintf(stderr, "Unknown Copilot hook event: %s\n", hookEvent)
		return 2
	}

	data, payload, err := readCopilotHookPayload(stdin)
	if err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot hook payload: %v\n", err)
		return 2
	}
	if handled, code := handleCopilotControlEvent(
		hookEvent,
		payload,
		stdout,
		stderr,
	); handled {
		return code
	}

	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	switch hookEvent {
	case "agentStop":
		return runCopilotMainStop(paths, payload, data, stdout, stderr)
	case "subagentStop":
		return runCopilotSubagentStop(paths, payload, data, stdout, stderr)
	}

	event, err := copilotEvent(hookEvent, payload, data)
	if err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot hook payload: %v\n", err)
		return 2
	}
	if err := deliverCopilotEvent(paths, &event, stderr); err != nil {
		fmt.Fprintf(stderr, "Could not deliver Copilot event: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Mews Copilot hook accepted: %s\n", hookEvent)
	return 0
}

func handleCopilotControlEvent(
	hookEvent string,
	payload copilotHookPayload,
	stdout io.Writer,
	stderr io.Writer,
) (bool, int) {
	if isCopilotToolCallSessionID(payload.SessionID) {
		fmt.Fprintln(stdout, "Mews ignored Copilot tool-call lifecycle event")
		return true, 0
	}

	switch hookEvent {
	case "sessionStart":
		if err := store.ClearCopilotHookSession(payload.SessionID); err != nil {
			fmt.Fprintf(stderr, "Could not reset Copilot hook state: %v\n", err)
			return true, 1
		}
		fmt.Fprintln(stdout, "Mews Copilot hook accepted: sessionStart")
		return true, 0
	case "subagentStart":
		if err := store.StartCopilotSubagent(
			payload.SessionID,
			payload.TranscriptPath,
		); err != nil {
			fmt.Fprintf(stderr, "Could not record Copilot subagent: %v\n", err)
			return true, 1
		}
		fmt.Fprintln(stdout, "Mews Copilot hook accepted: subagentStart")
		return true, 0
	case "agentStop":
		if payload.AgentName != "" {
			fmt.Fprintln(stdout, "Mews ignored duplicate Copilot subagent stop")
			return true, 0
		}
	case "userPromptSubmitted", "errorOccurred":
		if err := store.CancelCopilotMainStop(payload.SessionID); err != nil {
			fmt.Fprintf(stderr, "Could not cancel deferred Copilot completion: %v\n", err)
			return true, 1
		}
	case "sessionEnd":
		if err := store.ClearCopilotHookSession(payload.SessionID); err != nil {
			fmt.Fprintf(stderr, "Could not clear Copilot hook state: %v\n", err)
			return true, 1
		}
	}
	return false, 0
}

func runCopilotMainStop(
	paths store.StorePaths,
	payload copilotHookPayload,
	data []byte,
	stdout io.Writer,
	stderr io.Writer,
) int {
	mainCompletion, err := copilotEvent("agentStop", payload, data)
	if err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot hook payload: %v\n", err)
		return 2
	}
	deferred := mainCompletion
	deferred.HookEvent = "subagentRunning"
	deferred.Status = events.StatusRunning
	deferred.Message = notificationMessage(&deferred)
	if err := prepareCopilotEvent(&mainCompletion); err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot event: %v\n", err)
		return 2
	}
	if err := prepareCopilotEvent(&deferred); err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot event: %v\n", err)
		return 2
	}

	_, err = store.ProcessCopilotMainStop(
		payload.SessionID,
		func() error {
			deferred.Timestamp = time.Now()
			return deliverEventFn(paths, &deferred, stderr)
		},
		func(completionID string, completionAt time.Time) error {
			mainCompletion.ID = completionID
			mainCompletion.Timestamp = completionAt
			return deliverEventFn(paths, &mainCompletion, stderr)
		},
	)
	if err != nil {
		fmt.Fprintf(stderr, "Could not deliver Copilot event: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "Mews Copilot hook accepted: agentStop")
	return 0
}

func runCopilotSubagentStop(
	paths store.StorePaths,
	payload copilotHookPayload,
	data []byte,
	stdout io.Writer,
	stderr io.Writer,
) int {
	subagentCompletion, err := copilotEvent("subagentStop", payload, data)
	if err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot hook payload: %v\n", err)
		return 2
	}
	mainCompletion, err := copilotEvent("agentStop", payload, []byte("{}"))
	if err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot hook payload: %v\n", err)
		return 2
	}
	if err := prepareCopilotEvent(&subagentCompletion); err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot event: %v\n", err)
		return 2
	}
	if err := prepareCopilotEvent(&mainCompletion); err != nil {
		fmt.Fprintf(stderr, "Invalid Copilot event: %v\n", err)
		return 2
	}

	completedMain, err := store.ProcessCopilotSubagentStop(
		payload.SessionID,
		payload.TranscriptPath,
		func(completionID string, completionAt time.Time) error {
			mainCompletion.ID = completionID
			mainCompletion.Timestamp = completionAt
			if err := deliverEventFn(paths, &subagentCompletion, stderr); err != nil {
				return err
			}
			return deliverEventFn(paths, &mainCompletion, stderr)
		},
	)
	if err != nil {
		fmt.Fprintf(stderr, "Could not deliver Copilot event: %v\n", err)
		return 1
	}
	if !completedMain {
		if err := deliverEventFn(paths, &subagentCompletion, stderr); err != nil {
			fmt.Fprintf(stderr, "Could not deliver Copilot event: %v\n", err)
			return 1
		}
	}
	fmt.Fprintln(stdout, "Mews Copilot hook accepted: subagentStop")
	return 0
}

func prepareCopilotEvent(event *events.Event) error {
	enrichRuntimeContext(event)
	return event.Validate()
}

func deliverCopilotEvent(
	paths store.StorePaths,
	event *events.Event,
	stderr io.Writer,
) error {
	if err := prepareCopilotEvent(event); err != nil {
		return err
	}
	return deliverEventFn(paths, event, stderr)
}

func supportedCopilotHook(event string) bool {
	switch event {
	case "sessionStart", "userPromptSubmitted", "subagentStart", "subagentStop",
		"agentStop", "sessionEnd", "errorOccurred":
		return true
	default:
		return false
	}
}

func readCopilotHookPayload(stdin io.Reader) ([]byte, copilotHookPayload, error) {
	data, err := io.ReadAll(stdin)
	if err != nil {
		return nil, copilotHookPayload{}, err
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return nil, copilotHookPayload{}, fmt.Errorf("payload is required")
	}
	var payload copilotHookPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, copilotHookPayload{}, err
	}
	payload.SessionID = firstNonEmpty(payload.SessionID, payload.LegacySessionID)
	payload.TranscriptPath = firstNonEmpty(payload.TranscriptPath, payload.LegacyTranscript)
	payload.AgentName = firstNonEmpty(payload.AgentName, payload.LegacyAgentName)
	return data, payload, nil
}

func copilotEvent(
	hookEvent string,
	payload copilotHookPayload,
	data []byte,
) (events.Event, error) {
	event := events.Event{
		Version:    1,
		Source:     "copilot",
		HookEvent:  hookEvent,
		AgentScope: events.AgentScopeMain,
		SessionID:  payload.SessionID,
		CWD:        payload.CWD,
		Timestamp:  time.Now(),
	}
	if event.CWD != "" {
		event.Project = filepath.Base(event.CWD)
	}
	switch hookEvent {
	case "userPromptSubmitted":
		event.Status = events.StatusRunning
	case "subagentStop":
		event.AgentScope = events.AgentScopeSubagent
		event.Status = events.StatusDone
	case "agentStop":
		event.Status = events.StatusDone
	case "sessionEnd":
		event.Status = events.StatusIdle
	case "errorOccurred":
		event.Status = events.StatusFailed
		event.Recoverable = payload.Recoverable
	default:
		return events.Event{}, fmt.Errorf("event %q does not produce a Mews event", hookEvent)
	}

	title, err := copilotTaskTitle(data)
	if err != nil {
		return events.Event{}, err
	}
	event.TaskTitle = title
	event.Message = notificationMessage(&event)
	return event, nil
}

func copilotTaskTitle(data []byte) (string, error) {
	state, configured, err := store.LoadSetupState()
	if err != nil || !configured || !state.IncludeTaskTitle {
		return "", err
	}
	var payload copilotTaskTitlePayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return "", err
	}
	title := firstNonEmpty(
		payload.TaskTitle,
		payload.LegacyTaskTitle,
		payload.Title,
		payload.Prompt,
		payload.InitialPrompt,
		payload.Message,
	)
	return truncate(cleanOneLine(title), 80), nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func isCopilotToolCallSessionID(value string) bool {
	value = strings.TrimSpace(value)
	for _, prefix := range []string{"call_", "toolu_"} {
		if strings.HasPrefix(value, prefix) && len(value) > len(prefix) {
			return true
		}
	}
	return false
}
