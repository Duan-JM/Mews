package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/Duan-JM/mews/internal/doctor"
	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/store"
)

const version = "0.0.0-dev"

// Run executes the mw CLI and returns a process exit code.
func Run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printHelp(stdout)
		return 0
	}

	switch args[0] {
	case "setup":
		return runSetup(args[1:], stdout, stderr)
	case "start":
		return runStart(stdout, stderr)
	case "status":
		return runStatus(stdout, stderr)
	case "doctor":
		return runDoctor(stdout, stderr)
	case "stop":
		return runStop(stdout)
	case "undo":
		return runUndo(stdout, stderr)
	case "reset":
		return runReset(args[1:], stdout, stderr)
	case "notify":
		return runNotify(args[1:], stdin, stdout, stderr)
	case "run":
		return runCommand(args[1:], stdin, stdout, stderr)
	case "--help", "-h", "help":
		printHelp(stdout)
		return 0
	case "--version", "version":
		fmt.Fprintf(stdout, "mw %s\n", version)
		return 0
	default:
		fmt.Fprintf(stderr, "Unknown command: %s\n\n", args[0])
		printHelp(stderr)
		return 2
	}
}

func runSetup(args []string, stdout, stderr io.Writer) int {
	apply := false
	includeTaskTitle := false
	for _, arg := range args {
		switch arg {
		case "--yes", "-y":
			apply = true
		case "--include-task-title":
			includeTaskTitle = true
		default:
			fmt.Fprintf(stderr, "Unknown setup option: %s\n", arg)
			fmt.Fprintln(stderr, "Usage: mw setup [--yes] [--include-task-title]")
			return 2
		}
	}

	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews setup plan")
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "Mews will:")
	fmt.Fprintf(stdout, "  - create store: %s\n", paths.AppSupport)
	fmt.Fprintf(stdout, "  - create logs: %s\n", paths.Logs)
	if hookPath, err := integrations.CopilotHookPath(); err == nil {
		fmt.Fprintf(stdout, "  - install Copilot CLI hooks: %s\n", hookPath)
	}
	fmt.Fprintln(stdout, "  - include project, cwd, hook event, and session metadata in events")
	if includeTaskTitle {
		fmt.Fprintln(stdout, "  - include a local-only task title, truncated to 80 characters")
	} else {
		fmt.Fprintln(stdout, "  - skip task titles by default; use --include-task-title to opt in")
	}
	fmt.Fprintln(stdout, "  - record setup state for `mw doctor` and `mw undo`")
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "Not installed yet:")
	fmt.Fprintln(stdout, "  - menu bar agent and LaunchAgent")
	fmt.Fprintln(stdout, "  - Claude Code lifecycle hooks")
	fmt.Fprintln(stdout)

	if !apply {
		fmt.Fprintln(stdout, "Run `mw setup --yes` to apply this safe local setup.")
		fmt.Fprintln(stdout, "Run `mw undo` later to remove Mews-owned setup state.")
		return 0
	}

	mwPath, err := os.Executable()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve mw executable path: %v\n", err)
		return 1
	}
	if resolved, err := filepath.EvalSymlinks(mwPath); err == nil {
		mwPath = resolved
	}
	copilotInstall, err := integrations.InstallCopilotHooks(mwPath)
	if err != nil {
		fmt.Fprintf(stderr, "Could not install Copilot hooks: %v\n", err)
		return 1
	}

	state := store.SetupState{
		Version:          1,
		SetupAt:          time.Now(),
		Agent:            "not packaged yet",
		Copilot:          "hooks installed",
		CopilotHook:      copilotInstall.HookPath,
		IncludeTaskTitle: includeTaskTitle,
		Claude:           "hooks not installed",
		UndoReady:        true,
	}
	if err := store.SaveSetupState(state); err != nil {
		fmt.Fprintf(stderr, "Could not save setup state: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews setup state saved.")
	if copilotInstall.Existed {
		fmt.Fprintf(stdout, "Refreshed Copilot hook: %s\n", copilotInstall.HookPath)
	} else {
		fmt.Fprintf(stdout, "Installed Copilot hook: %s\n", copilotInstall.HookPath)
	}
	if includeTaskTitle {
		fmt.Fprintln(stdout, "Task titles enabled. Mews stores at most 80 local-only characters from hook payloads.")
	}
	fmt.Fprintln(stdout, "Run `mw start` to start Mews when the menu bar agent is available.")
	return 0
}

func runStart(stdout, stderr io.Writer) int {
	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}
	if _, configured, err := store.LoadSetupState(); err != nil {
		fmt.Fprintf(stderr, "Could not read setup state: %v\n", err)
		return 1
	} else if !configured {
		fmt.Fprintln(stdout, "Mews is not set up yet.")
		fmt.Fprintln(stdout, "Run `mw setup` to review the local setup plan.")
		fmt.Fprintln(stdout, "Run `mw setup --yes` to create Mews-owned setup state.")
		return 1
	}

	fmt.Fprintln(stdout, "Mews setup state found.")
	fmt.Fprintf(stdout, "  Store: %s\n", paths.AppSupport)
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "Menu bar companion is not packaged yet.")
	fmt.Fprintln(stdout, "Run `mw doctor` to inspect the local setup.")
	return 1
}

func runStatus(stdout, stderr io.Writer) int {
	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews Status")
	fmt.Fprintf(stdout, "Store: %s\n", paths.AppSupport)
	if _, configured, err := store.LoadSetupState(); err != nil {
		fmt.Fprintf(stderr, "Could not read setup state: %v\n", err)
		return 1
	} else if configured {
		fmt.Fprintln(stdout, "Setup: configured")
	} else {
		fmt.Fprintln(stdout, "Setup: not set up")
	}
	fmt.Fprintln(stdout, "Agent: not packaged yet")
	return 0
}

func runDoctor(stdout, stderr io.Writer) int {
	report, err := doctor.Check()
	if err != nil {
		fmt.Fprintf(stderr, "Doctor failed: %v\n", err)
		return 1
	}
	report.Print(stdout)
	if report.HasFailures() {
		return 1
	}
	return 0
}

func runStop(stdout io.Writer) int {
	fmt.Fprintln(stdout, "Mews menu bar companion is not running.")
	return 0
}

func runUndo(stdout, stderr io.Writer) int {
	if _, configured, err := store.LoadSetupState(); err != nil {
		fmt.Fprintf(stderr, "Could not read setup state: %v\n", err)
		return 1
	} else if !configured {
		fmt.Fprintln(stdout, "No Mews setup state or integrations are installed.")
		return 0
	}

	if err := integrations.RemoveCopilotHooks(); err != nil {
		fmt.Fprintf(stderr, "Could not remove Copilot hooks: %v\n", err)
		return 1
	}
	if err := store.RemoveSetupState(); err != nil {
		fmt.Fprintf(stderr, "Could not remove setup state: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Removed Mews setup state.")
	fmt.Fprintln(stdout, "Removed Mews-owned Copilot hooks.")
	fmt.Fprintln(stdout, "Event history was kept. Run `mw reset --yes` to delete local Mews data.")
	return 0
}

func runReset(args []string, stdout, stderr io.Writer) int {
	apply := false
	for _, arg := range args {
		switch arg {
		case "--yes", "-y":
			apply = true
		default:
			fmt.Fprintf(stderr, "Unknown reset option: %s\n", arg)
			fmt.Fprintln(stderr, "Usage: mw reset --yes")
			return 2
		}
	}

	if !apply {
		fmt.Fprintln(stderr, "Usage: mw reset --yes")
		fmt.Fprintln(stderr, "This deletes Mews local store, logs, setup state, and event history.")
		return 2
	}
	if err := store.Reset(); err != nil {
		fmt.Fprintf(stderr, "Could not reset Mews data: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Deleted Mews local store and logs.")
	return 0
}

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
	if err := event.Validate(); err != nil {
		fmt.Fprintf(stderr, "Invalid event: %v\n", err)
		return 2
	}
	if cwd, err := os.Getwd(); err == nil && event.CWD == "" {
		event.CWD = cwd
	}
	event.PID = os.Getpid()

	data, err := json.Marshal(event)
	if err != nil {
		fmt.Fprintf(stderr, "Could not encode event: %v\n", err)
		return 1
	}
	if err := store.AppendEventJSON(data); err != nil {
		fmt.Fprintf(stderr, "Could not write event: %v\n", err)
		return 1
	}
	notifyDesktop(event)

	fmt.Fprintf(stdout, "Mews event accepted: %s %s\n", event.Source, event.Status)
	return 0
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
		event.SessionID = firstString(payload, "session_id", "sessionId", "sessionID", "session")
	}
	if event.Project == "" && event.CWD != "" {
		event.Project = filepath.Base(event.CWD)
	}

	if state, configured, err := store.LoadSetupState(); err == nil && configured && state.IncludeTaskTitle {
		title := firstString(payload, "task_title", "taskTitle", "title", "prompt", "userPrompt", "message")
		event.TaskTitle = truncate(cleanOneLine(title), 80)
	}
	event.Message = notificationMessage(*event)
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

func notificationMessage(event events.Event) string {
	action := string(event.Status)
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

	message := fmt.Sprintf("%s %s", event.Source, action)
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

func truncate(value string, max int) string {
	runes := []rune(value)
	if len(runes) <= max {
		return value
	}
	if max <= 1 {
		return string(runes[:max])
	}
	return string(runes[:max-3]) + "..."
}

func notifyDesktop(event events.Event) {
	title := "Mews"
	message := fmt.Sprintf("%s: %s", event.Source, event.Status)
	if event.Message != "" {
		message = event.Message
	}
	_ = exec.Command("osascript", "-e", fmt.Sprintf("display notification %q with title %q", message, title)).Run()
}

func runCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "--" || len(args) == 1 {
		fmt.Fprintln(stderr, "Usage: mw run -- <command>")
		return 2
	}

	name := args[1]
	cmdArgs := args[2:]
	cmd := exec.Command(name, cmdArgs...)
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr

	if err := cmd.Run(); err != nil {
		fmt.Fprintf(stderr, "Mews: command failed: %s\n", strings.Join(args[1:], " "))
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}

	fmt.Fprintf(stdout, "Mews: command completed: %s\n", strings.Join(args[1:], " "))
	return 0
}

func printHelp(w io.Writer) {
	fmt.Fprint(w, `Mews watches terminal AI agents and tells you when they need you.

Usage:
  mw setup [--yes] [--include-task-title]
  mw start
  mw status
  mw doctor
  mw stop
  mw undo
  mw reset --yes
  mw notify --status done --source custom
  mw run -- <command>

`)
}
