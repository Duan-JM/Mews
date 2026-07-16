package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/Duan-JM/mews/internal/app"
	"github.com/Duan-JM/mews/internal/doctor"
	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/launchd"
	"github.com/Duan-JM/mews/internal/store"
)

var version = "dev"
var deliverEventFn = deliverEvent
var pingAgent = ipc.Ping
var bootstrapLaunchAgent = launchd.Bootstrap
var bootstrapRetryDelay = 20 * time.Millisecond

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
	case "history":
		return runHistory(args[1:], stdout, stderr)
	case "listen":
		return runListen(stdout, stderr)
	case "doctor":
		return runDoctor(stdout, stderr)
	case "stop":
		return runStop(stdout, stderr)
	case "undo":
		return runUndo(stdout, stderr)
	case "reset":
		return runReset(args[1:], stdout, stderr)
	case "notify":
		return runNotify(args[1:], stdin, stdout, stderr)
	case "hook":
		return runHook(args[1:], stdin, stdout, stderr)
	case "run":
		return runCommand(args[1:], stdin, stdout, stderr)
	case "agent":
		return runAgent(stdout, stderr)
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
	if bundle, err := app.ResolveBundle(); err == nil {
		fmt.Fprintf(stdout, "  - launch menu bar app: %s\n", bundle.Path)
	} else {
		fmt.Fprintln(stdout, "  - use the menu bar app after `make build` packages it")
	}
	if hookPath, err := integrations.CopilotHookPath(); err == nil {
		fmt.Fprintf(stdout, "  - install Copilot CLI hooks: %s\n", hookPath)
	}
	if settingsPath, err := integrations.ClaudeSettingsPath(); err == nil {
		fmt.Fprintf(stdout, "  - install Claude Code hooks: %s\n", settingsPath)
	}
	if configPath, err := integrations.CodexConfigPath(); err == nil {
		fmt.Fprintf(stdout, "  - install Codex notify integration: %s\n", configPath)
	}
	fmt.Fprintln(stdout, "  - include project, cwd, hook event, and session metadata in events")
	if includeTaskTitle {
		fmt.Fprintln(stdout, "  - include a local-only task title, truncated to 80 characters")
	} else {
		fmt.Fprintln(stdout, "  - skip task titles by default; use --include-task-title to opt in")
	}
	fmt.Fprintln(stdout, "  - record setup state for `mw doctor` and `mw undo`")
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
	mwPath = app.StableInstalledPath(mwPath)
	installed, err := integrations.InstallAll(mwPath)
	if err != nil {
		fmt.Fprintf(stderr, "Could not install integrations: %v\n", err)
		return 1
	}

	state := store.SetupState{
		Version:          1,
		SetupAt:          time.Now(),
		Agent:            "menu bar app configured",
		Copilot:          "hooks installed",
		IncludeTaskTitle: includeTaskTitle,
		Claude:           "hooks installed",
		UndoReady:        true,
	}
	for _, integration := range installed {
		if integration.Name == "copilot" {
			state.CopilotHook = integration.Path
		}
	}
	if err := store.SaveSetupState(state); err != nil {
		_ = integrations.UndoAll()
		fmt.Fprintf(stderr, "Could not save setup state: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews setup state saved.")
	for _, integration := range installed {
		fmt.Fprintf(stdout, "Installed %s integration: %s\n", integration.Name, integration.Path)
	}
	if includeTaskTitle {
		fmt.Fprintln(stdout, "Task titles enabled. Mews stores at most 80 local-only characters from hook payloads.")
	}
	fmt.Fprintln(stdout, "Run `mw start` to start the menu bar app.")
	return 0
}

func runStart(stdout, stderr io.Writer) int {
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
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
	loadedJob, loaded, err := launchd.CurrentJob()
	if err != nil {
		fmt.Fprintf(stderr, "Could not inspect Mews LaunchAgent: %v\n", err)
		return 1
	}
	agentRunning := false
	if err := ipc.Ping(paths.Socket); err == nil {
		agentRunning = true
		if loaded {
			fmt.Fprintln(stdout, "Mews menu bar app is already running; refreshing it.")
		} else {
			fmt.Fprintln(stdout, "Mews local agent is already running; starting menu bar app too.")
		}
	} else if err != ipc.ErrUnavailable {
		fmt.Fprintf(stderr, "Could not check Mews local agent: %v\n", err)
		return 1
	}

	bundle, err := app.ResolveBundle()
	if err != nil {
		fmt.Fprintf(stderr, "Could not find Mews.app: %v\n", err)
		fmt.Fprintln(stderr, "Run `make build` from the repository, or install a package that includes Mews.app.")
		return 1
	}
	plistPath, err := launchd.Install(bundle.Executable, paths.Logs)
	if err != nil {
		fmt.Fprintf(stderr, "Could not install LaunchAgent: %v\n", err)
		return 1
	}
	if loaded && agentRunning {
		if err := ipc.Stop(paths.Socket); err != nil && err != ipc.ErrUnavailable {
			fmt.Fprintf(stderr, "Could not stop the existing Mews local agent: %v\n", err)
			return 1
		}
		if err := waitForAgentStop(paths.Socket, 2*time.Second); err != nil {
			fmt.Fprintf(stderr, "Existing Mews local agent did not stop: %v\n", err)
			return 1
		}
	}
	if loaded {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintf(stderr, "Could not resolve the current home directory: %v\n", err)
			return 1
		}
		desiredNamespace := os.Getenv("MEWS_SOCKET_NAMESPACE")
		desiredLogPath := filepath.Join(paths.Logs, "app.log")
		if loadedJob.Program == bundle.Executable &&
			loadedJob.HomePath == home &&
			loadedJob.SocketNamespace == desiredNamespace &&
			loadedJob.StdoutPath == desiredLogPath &&
			loadedJob.StderrPath == desiredLogPath {
			if err := launchd.Kickstart(); err != nil {
				fmt.Fprintf(stderr, "Could not refresh Mews menu bar app: %v\n", err)
				return 1
			}
		} else {
			if err := launchd.Bootout(); err != nil {
				fmt.Fprintf(stderr, "Could not replace Mews LaunchAgent: %v\n", err)
				return 1
			}
			if err := bootstrapWithRetry(2 * time.Second); err != nil {
				_, restoreErr := launchd.InstallLoadedJob(loadedJob)
				if restoreErr == nil {
					restoreErr = bootstrapWithRetry(2 * time.Second)
				}
				if restoreErr != nil {
					fmt.Fprintf(
						stderr,
						"Could not start the new Mews app (%v) or restore the previous LaunchAgent (%v).\n",
						err,
						restoreErr,
					)
				} else {
					fmt.Fprintf(
						stderr,
						"Could not start the new Mews app; the previous LaunchAgent was restored: %v\n",
						err,
					)
				}
				return 1
			}
		}
	} else {
		if err := bootstrapWithRetry(2 * time.Second); err != nil {
			fmt.Fprintf(stderr, "Could not start Mews menu bar app: %v\n", err)
			return 1
		}
	}

	if err := waitForAgent(paths.Socket, 2*time.Second); err != nil {
		fmt.Fprintf(stderr, "Mews menu bar app did not start its local agent: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews menu bar app is running.")
	fmt.Fprintf(stdout, "  LaunchAgent: %s\n", plistPath)
	fmt.Fprintf(stdout, "  Store: %s\n", paths.AppSupport)
	return 0
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
	if err := ipc.Ping(paths.Socket); err == nil {
		fmt.Fprintln(stdout, "Agent: running")
	} else {
		fmt.Fprintln(stdout, "Agent: not running")
	}
	recent, err := store.ReadEvents(paths.Events, 1)
	if err != nil {
		fmt.Fprintf(stderr, "Could not read event history: %v\n", err)
		return 1
	}
	if len(recent) == 0 {
		fmt.Fprintln(stdout, "Latest event: no events yet")
		return 0
	}
	printEventSummary(stdout, "Latest event", recent[0])
	return 0
}

func runHistory(args []string, stdout, stderr io.Writer) int {
	sessionFilter := ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--session":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "Usage: mw history [--session <id>]")
				return 2
			}
			sessionFilter = args[i+1]
			i++
		default:
			fmt.Fprintf(stderr, "Unknown history option: %s\n", args[i])
			fmt.Fprintln(stderr, "Usage: mw history [--session <id>]")
			return 2
		}
	}

	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}

	limit := 10
	if sessionFilter != "" {
		limit = 200
	}
	recent, err := store.ReadEvents(paths.Events, limit)
	if err != nil {
		fmt.Fprintf(stderr, "Could not read event history: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews History")
	if sessionFilter != "" {
		fmt.Fprintf(stdout, "Session: %s\n", sessionFilter)
		filtered := recent[:0]
		for _, event := range recent {
			if event.SessionID == sessionFilter {
				filtered = append(filtered, event)
			}
		}
		recent = filtered
	}
	if len(recent) == 0 {
		fmt.Fprintln(stdout, "No events yet.")
		return 0
	}
	for _, event := range recent {
		printEventSummary(stdout, "-", event)
	}
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

func runStop(stdout, stderr io.Writer) int {
	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}
	stopped := false
	if err := ipc.Stop(paths.Socket); err == nil {
		stopped = true
	} else if err != ipc.ErrUnavailable {
		fmt.Fprintf(stderr, "Could not stop Mews local agent: %v\n", err)
		return 1
	}
	if err := launchd.Bootout(); err != nil {
		fmt.Fprintf(stderr, "Could not unload Mews LaunchAgent: %v\n", err)
		return 1
	}
	if err := launchd.RemovePlist(); err != nil {
		fmt.Fprintf(stderr, "Could not remove Mews LaunchAgent: %v\n", err)
		return 1
	}
	if stopped {
		fmt.Fprintln(stdout, "Mews menu bar app stopped.")
	} else {
		fmt.Fprintln(stdout, "Mews menu bar app is not running.")
	}
	return 0
}

func runUndo(stdout, stderr io.Writer) int {
	setupState, setupConfigured, err := store.LoadSetupState()
	if err != nil {
		fmt.Fprintf(stderr, "Could not read setup state: %v\n", err)
		return 1
	}
	_, integrationsConfigured, err := store.LoadIntegrationState()
	if err != nil {
		fmt.Fprintf(stderr, "Could not read integration state: %v\n", err)
		return 1
	}
	if !setupConfigured && !integrationsConfigured {
		fmt.Fprintln(stdout, "No Mews setup state or integrations are installed.")
		return 0
	}

	if integrationsConfigured {
		if err := integrations.UndoAll(); err != nil {
			fmt.Fprintf(stderr, "Could not remove integrations: %v\n", err)
			return 1
		}
	} else {
		if setupState.Claude == "hooks installed" {
			fmt.Fprintln(stderr, "Could not remove integrations: integration rollback state is missing.")
			fmt.Fprintln(stderr, "Restore integrations.json from backup before retrying `mw undo`.")
			return 1
		}
		hookPath := setupState.CopilotHook
		var err error
		if hookPath != "" {
			err = integrations.RemoveRecordedCopilotHookAt(hookPath)
		} else {
			err = integrations.RemoveCopilotHooks()
		}
		if err != nil {
			fmt.Fprintf(stderr, "Could not remove integrations: %v\n", err)
			return 1
		}
	}
	if err := launchd.Bootout(); err != nil {
		fmt.Fprintf(stderr, "Could not unload Mews LaunchAgent: %v\n", err)
		return 1
	}
	if err := launchd.RemovePlist(); err != nil {
		fmt.Fprintf(stderr, "Could not remove Mews LaunchAgent: %v\n", err)
		return 1
	}
	if err := store.RemoveSetupState(); err != nil {
		fmt.Fprintf(stderr, "Could not remove setup state: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Removed Mews setup state.")
	fmt.Fprintln(stdout, "Removed Mews-owned integrations.")
	fmt.Fprintln(stdout, "Removed Mews LaunchAgent.")
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
		fmt.Fprintln(stderr, "This deletes Mews local store, logs, and event history after `mw undo`.")
		return 2
	}
	if _, configured, err := store.LoadSetupState(); err != nil {
		fmt.Fprintf(stderr, "Could not read setup state: %v\n", err)
		return 1
	} else if configured {
		fmt.Fprintln(stderr, "Mews integrations are still configured.")
		fmt.Fprintln(stderr, "Run `mw undo` before `mw reset --yes` so external config remains reversible.")
		return 1
	}
	if _, configured, err := store.LoadIntegrationState(); err != nil {
		fmt.Fprintf(stderr, "Could not read integration state: %v\n", err)
		return 1
	} else if configured {
		fmt.Fprintln(stderr, "Mews integration rollback state still exists.")
		fmt.Fprintln(stderr, "Run `mw undo` before `mw reset --yes`.")
		return 1
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
	if cwd, err := os.Getwd(); err == nil && event.CWD == "" {
		event.CWD = cwd
	}
	if event.PID == 0 {
		event.PID = os.Getpid()
	}
	if err := event.Validate(); err != nil {
		fmt.Fprintf(stderr, "Invalid event: %v\n", err)
		return 2
	}
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	if err := deliverEvent(paths, event, stderr); err != nil {
		fmt.Fprintf(stderr, "Could not deliver event: %v\n", err)
		return 1
	}

	fmt.Fprintf(stdout, "Mews event accepted: %s %s\n", event.Source, event.Status)
	return 0
}

func runHook(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "Usage: mw hook codex [payload]")
		return 2
	}
	switch args[0] {
	case "codex":
		if len(args) > 2 {
			fmt.Fprintln(stderr, "Usage: mw hook codex [payload]")
			return 2
		}
		var payload io.Reader = stdin
		if len(args) == 2 {
			payload = strings.NewReader(args[1])
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
		paths, err := store.Ensure()
		if err != nil {
			fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
			return 1
		}
		if err := deliverEvent(paths, event, stderr); err != nil {
			fmt.Fprintf(stderr, "Could not deliver Codex event: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "Mews event sent: %s %s\n", event.Source, event.Status)
		return 0
	default:
		fmt.Fprintf(stderr, "Unknown hook source: %s\n", args[0])
		return 2
	}
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
		event.SessionID = firstString(payload, "session_id", "sessionId", "sessionID", "session", "thread-id", "thread_id")
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

func runAgent(stdout, stderr io.Writer) int {
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "Mews local agent started.")
	if err := ipc.ServeWithObserver(paths.Socket, paths.Events, func(event events.Event) {
		printEventSummary(stdout, "Event", event)
	}); err != nil {
		fmt.Fprintf(stderr, "Mews local agent failed: %v\n", err)
		return 1
	}
	return 0
}

func runListen(stdout, stderr io.Writer) int {
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	if err := ipc.Ping(paths.Socket); err == nil {
		fmt.Fprintln(stderr, "Mews local agent is already running. Stop it before using foreground listen.")
		return 1
	}

	fmt.Fprintf(stdout, "Mews is listening on %s\n", paths.Socket)
	fmt.Fprintln(stdout, "Press Ctrl+C to stop, or run `mw stop` from another terminal.")
	if err := ipc.ServeWithObserver(paths.Socket, paths.Events, func(event events.Event) {
		printEventSummary(stdout, "Event", event)
	}); err != nil {
		fmt.Fprintf(stderr, "Mews listener failed: %v\n", err)
		return 1
	}
	return 0
}

func runCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "--" || len(args) == 1 {
		fmt.Fprintln(stderr, "Usage: mw run -- <command>")
		return 2
	}

	name := args[1]
	cmdArgs := args[2:]
	cmd := exec.Command(name, cmdArgs...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr

	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}

	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve working directory: %v\n", err)
		return 1
	}
	commandText := strings.Join(args[1:], " ")

	if err := cmd.Start(); err != nil {
		if saveErr := deliverEvent(paths, commandEvent(events.StatusFailed, commandText, cwd, 0), stderr); saveErr != nil {
			fmt.Fprintf(stderr, "Could not save event: %v\n", saveErr)
			return 1
		}
		fmt.Fprintf(stderr, "Mews: command failed to start: %s\n", commandText)
		return 1
	}

	if err := deliverEventFn(paths, commandEvent(events.StatusRunning, commandText, cwd, cmd.Process.Pid), stderr); err != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Wait()
		fmt.Fprintf(stderr, "Could not save event: %v\n", err)
		return 1
	}

	if err := cmd.Wait(); err != nil {
		if saveErr := deliverEventFn(paths, commandEvent(events.StatusFailed, commandText, cwd, cmd.Process.Pid), stderr); saveErr != nil {
			fmt.Fprintf(stderr, "Could not save event: %v\n", saveErr)
			return 1
		}
		fmt.Fprintf(stderr, "Mews: command failed: %s\n", commandText)
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}

	if err := deliverEventFn(paths, commandEvent(events.StatusDone, commandText, cwd, cmd.Process.Pid), stderr); err != nil {
		fmt.Fprintf(stderr, "Could not save event: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Mews: command completed: %s\n", commandText)
	return 0
}

func printHelp(w io.Writer) {
	fmt.Fprint(w, `Mews watches terminal AI agents and tells you when they need you.

Usage:
  mw setup [--yes] [--include-task-title]
  mw start
  mw status
  mw history [--session <id>]
  mw listen
  mw doctor
  mw stop
  mw undo
  mw reset --yes
  mw notify --status done --source custom
  mw hook codex [payload]
  mw run -- <command>

`)
}

func printEventSummary(w io.Writer, prefix string, event events.Event) {
	message := event.Message
	if message == "" {
		message = "no message"
	}
	project := event.Project
	if project == "" {
		project = "unknown project"
	}
	session := ""
	if event.SessionID != "" {
		session = fmt.Sprintf(" [session %s | return: %s]", event.SessionID, sessionReturnCommand(event.SessionID))
	}
	fmt.Fprintf(w, "%s: %s %s (%s) %s%s\n", prefix, event.Source, event.Status, project, message, session)
}

func sessionReturnCommand(sessionID string) string {
	return "mw history --session " + shellQuoteForDisplay(sessionID)
}

func shellQuoteForDisplay(value string) string {
	if value == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func commandEvent(status events.Status, commandText, cwd string, pid int) events.Event {
	project := filepath.Base(cwd)
	return events.Event{
		Version:   1,
		Source:    "runner",
		SessionID: project,
		Project:   project,
		Status:    status,
		Message:   truncate(commandText, 1024),
		CWD:       cwd,
		PID:       pid,
		Timestamp: time.Now(),
	}
}

func waitForAgent(socketPath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := pingAgent(socketPath); err == nil {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return ipc.ErrUnavailable
}

func waitForAgentStop(socketPath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := pingAgent(socketPath); err != nil {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return errors.New("timed out waiting for local agent to stop")
}

func bootstrapWithRetry(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		err := bootstrapLaunchAgent()
		if err == nil {
			return nil
		}
		if !launchd.IsBootstrapRace(err) || !time.Now().Before(deadline) {
			return err
		}
		time.Sleep(bootstrapRetryDelay)
	}
}

func deliverEvent(paths store.StorePaths, event events.Event, _ io.Writer) error {
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
