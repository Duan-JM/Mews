package cli

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/store"
)

type commandExecution struct {
	process     *exec.Cmd
	paths       store.StorePaths
	commandText string
	cwd         string
	stderr      io.Writer
}

func runCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	execution, code := prepareCommand(args, stdin, stdout, stderr)
	if code != 0 {
		return code
	}
	if code := startCommand(execution); code != 0 {
		return code
	}
	return finishCommand(execution, stdout)
}

func prepareCommand(
	args []string,
	stdin io.Reader,
	stdout io.Writer,
	stderr io.Writer,
) (*commandExecution, int) {
	if len(args) == 0 || args[0] != "--" || len(args) == 1 {
		fmt.Fprintln(stderr, "Usage: mw run -- <command>")
		return nil, 2
	}

	process := exec.Command(args[1], args[2:]...)
	process.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	process.Stdin = stdin
	process.Stdout = stdout
	process.Stderr = stderr

	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return nil, 1
	}
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve working directory: %v\n", err)
		return nil, 1
	}
	return &commandExecution{
		process:     process,
		paths:       paths,
		commandText: strings.Join(args[1:], " "),
		cwd:         cwd,
		stderr:      stderr,
	}, 0
}

func startCommand(execution *commandExecution) int {
	if err := execution.process.Start(); err != nil {
		event := commandEvent(events.StatusFailed, execution.commandText, execution.cwd, 0)
		if saveErr := deliverEvent(execution.paths, event, execution.stderr); saveErr != nil {
			fmt.Fprintf(execution.stderr, "Could not save event: %v\n", saveErr)
			return 1
		}
		fmt.Fprintf(execution.stderr, "Mews: command failed to start: %s\n", execution.commandText)
		return 1
	}

	event := commandEvent(
		events.StatusRunning,
		execution.commandText,
		execution.cwd,
		execution.process.Process.Pid,
	)
	if err := deliverEventFn(execution.paths, event, execution.stderr); err != nil {
		_ = syscall.Kill(-execution.process.Process.Pid, syscall.SIGKILL)
		_ = execution.process.Wait()
		fmt.Fprintf(execution.stderr, "Could not save event: %v\n", err)
		return 1
	}
	return 0
}

func finishCommand(execution *commandExecution, stdout io.Writer) int {
	if err := execution.process.Wait(); err != nil {
		event := commandEvent(
			events.StatusFailed,
			execution.commandText,
			execution.cwd,
			execution.process.Process.Pid,
		)
		if saveErr := deliverEventFn(execution.paths, event, execution.stderr); saveErr != nil {
			fmt.Fprintf(execution.stderr, "Could not save event: %v\n", saveErr)
			return 1
		}
		fmt.Fprintf(execution.stderr, "Mews: command failed: %s\n", execution.commandText)
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}

	event := commandEvent(
		events.StatusDone,
		execution.commandText,
		execution.cwd,
		execution.process.Process.Pid,
	)
	if err := deliverEventFn(execution.paths, event, execution.stderr); err != nil {
		fmt.Fprintf(execution.stderr, "Could not save event: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Mews: command completed: %s\n", execution.commandText)
	return 0
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
