package cli

import (
	"fmt"
	"io"
	"os/exec"
	"strings"

	"github.com/Duan-JM/mews/internal/doctor"
	"github.com/Duan-JM/mews/internal/events"
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
	case "doctor":
		return runDoctor(stdout, stderr)
	case "stop":
		return runStop(stdout)
	case "undo":
		return runUndo(stdout)
	case "notify":
		return runNotify(args[1:], stdout, stderr)
	case "run":
		return runCommand(args[1:], stdout, stderr)
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

	fmt.Fprintln(stdout, "Mews store is ready.")
	fmt.Fprintf(stdout, "  Store: %s\n", paths.AppSupport)
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
	fmt.Fprintln(stdout, "Agent: not installed")
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

	fmt.Fprintf(stdout, "Mews event accepted: %s %s\n", event.Source, event.Status)
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
  mews start
  mews status
  mews doctor
  mews stop
  mews undo
  mews notify --status done --source custom
  mews run -- <command>

`)
}

