package cli

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/Duan-JM/mews/internal/doctor"
	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/store"
)

const version = "0.0.0-dev"

// Run executes the mews CLI and returns a process exit code.
func Run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printHelp(stdout)
		return 0
	}

	switch args[0] {
	case "start":
		return runStart(stdout, stderr)
	case "status":
		return runStatus(stdout, stderr)
	case "history":
		return runHistory(stdout, stderr)
	case "doctor":
		return runDoctor(stdout, stderr)
	case "stop":
		return runStop(stdout, stderr)
	case "undo":
		return runUndo(stdout)
	case "notify":
		return runNotify(args[1:], stdout, stderr)
	case "run":
		return runCommand(args[1:], stdout, stderr)
	case "agent":
		return runAgent(stdout, stderr)
	case "--help", "-h", "help":
		printHelp(stdout)
		return 0
	case "--version", "version":
		fmt.Fprintf(stdout, "mews %s\n", version)
		return 0
	default:
		fmt.Fprintf(stderr, "Unknown command: %s\n\n", args[0])
		printHelp(stderr)
		return 2
	}
}

func runStart(stdout, stderr io.Writer) int {
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}

	if err := ipc.Ping(paths.Socket); err == nil {
		fmt.Fprintln(stdout, "Mews local agent is already running.")
		return 0
	}

	logFile, err := os.OpenFile(filepath.Join(paths.Logs, "agent.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		fmt.Fprintf(stderr, "Could not open Mews agent log: %v\n", err)
		return 1
	}
	defer logFile.Close()

	executable, err := os.Executable()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews executable: %v\n", err)
		return 1
	}
	cmd := exec.Command(executable, "agent")
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(stderr, "Could not start Mews local agent: %v\n", err)
		return 1
	}
	if err := cmd.Process.Release(); err != nil {
		fmt.Fprintf(stderr, "Could not release Mews local agent: %v\n", err)
		return 1
	}

	if err := waitForAgent(paths.Socket, 2*time.Second); err != nil {
		fmt.Fprintf(stderr, "Mews local agent did not start: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews store is ready.")
	fmt.Fprintf(stdout, "  Store: %s\n", paths.AppSupport)
	fmt.Fprintln(stdout, "Mews local agent is running.")
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "Menu bar companion is not packaged yet.")
	fmt.Fprintln(stdout, "Run `mews doctor` to inspect the local setup.")
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
		fmt.Fprintln(stdout, "Latest event: none")
		return 0
	}
	printEventSummary(stdout, "Latest event", recent[0])
	return 0
}

func runHistory(stdout, stderr io.Writer) int {
	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}

	recent, err := store.ReadEvents(paths.Events, 10)
	if err != nil {
		fmt.Fprintf(stderr, "Could not read event history: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews History")
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
	if err := ipc.Stop(paths.Socket); err != nil {
		if err == ipc.ErrUnavailable {
			fmt.Fprintln(stdout, "Mews local agent is not running.")
			return 0
		}
		fmt.Fprintf(stderr, "Could not stop Mews local agent: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "Mews local agent stopped.")
	return 0
}

func runUndo(stdout io.Writer) int {
	fmt.Fprintln(stdout, "No Mews integrations are installed yet.")
	return 0
}

func runNotify(args []string, stdout, stderr io.Writer) int {
	event, err := events.FromArgs(args)
	if err != nil {
		fmt.Fprintf(stderr, "Invalid event: %v\n", err)
		return 2
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
	if err := ipc.SendEvent(paths.Socket, event); err == nil {
		fmt.Fprintf(stdout, "Mews event sent: %s %s\n", event.Source, event.Status)
		return 0
	}
	if err := store.AppendEvent(paths.Events, event); err != nil {
		fmt.Fprintf(stderr, "Could not save event: %v\n", err)
		return 1
	}

	fmt.Fprintf(stdout, "Mews event accepted: %s %s\n", event.Source, event.Status)
	return 0
}

func runAgent(stdout, stderr io.Writer) int {
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "Mews local agent started.")
	if err := ipc.Serve(paths.Socket, paths.Events); err != nil {
		fmt.Fprintf(stderr, "Mews local agent failed: %v\n", err)
		return 1
	}
	return 0
}

func runCommand(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "--" || len(args) == 1 {
		fmt.Fprintln(stderr, "Usage: mews run -- <command>")
		return 2
	}

	name := args[1]
	cmdArgs := args[2:]
	cmd := exec.Command(name, cmdArgs...)
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
		if saveErr := store.AppendEvent(paths.Events, commandEvent(events.StatusFailed, commandText, cwd, 0)); saveErr != nil {
			fmt.Fprintf(stderr, "Could not save event: %v\n", saveErr)
			return 1
		}
		fmt.Fprintf(stderr, "Mews: command failed to start: %s\n", commandText)
		return 1
	}

	if err := store.AppendEvent(paths.Events, commandEvent(events.StatusRunning, commandText, cwd, cmd.Process.Pid)); err != nil {
		fmt.Fprintf(stderr, "Could not save event: %v\n", err)
		return 1
	}

	if err := cmd.Wait(); err != nil {
		if saveErr := store.AppendEvent(paths.Events, commandEvent(events.StatusFailed, commandText, cwd, cmd.Process.Pid)); saveErr != nil {
			fmt.Fprintf(stderr, "Could not save event: %v\n", saveErr)
			return 1
		}
		fmt.Fprintf(stderr, "Mews: command failed: %s\n", commandText)
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}

	if err := store.AppendEvent(paths.Events, commandEvent(events.StatusDone, commandText, cwd, cmd.Process.Pid)); err != nil {
		fmt.Fprintf(stderr, "Could not save event: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Mews: command completed: %s\n", commandText)
	return 0
}

func printHelp(w io.Writer) {
	fmt.Fprint(w, `Mews watches terminal AI agents and tells you when they need you.

Usage:
  mews start
  mews status
  mews history
  mews doctor
  mews stop
  mews undo
  mews notify --status done --source custom
  mews run -- <command>

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
	fmt.Fprintf(w, "%s: %s %s (%s) %s\n", prefix, event.Source, event.Status, project, message)
}

func commandEvent(status events.Status, commandText, cwd string, pid int) events.Event {
	project := filepath.Base(cwd)
	return events.Event{
		Version:   1,
		Source:    "runner",
		SessionID: project,
		Project:   project,
		Status:    status,
		Message:   commandText,
		CWD:       cwd,
		PID:       pid,
		Timestamp: time.Now(),
	}
}

func waitForAgent(socketPath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := ipc.Ping(socketPath); err == nil {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return ipc.ErrUnavailable
}
