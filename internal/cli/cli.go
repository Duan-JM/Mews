package cli

import (
	"fmt"
	"io"
)

var version = "dev"

// Run executes the mw CLI and returns a process exit code.
func Run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printHelp(stdout)
		return 0
	}

	switch args[0] {
	case "--help", "-h", "help":
		printHelp(stdout)
		return 0
	case "--version", "version":
		fmt.Fprintf(stdout, "mw %s\n", version)
		return 0
	default:
		return dispatchCommand(args[0], args[1:], stdin, stdout, stderr)
	}
}

func dispatchCommand(command string, args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	switch command {
	case "notify":
		return runNotify(args, stdin, stdout, stderr)
	case "hook":
		return runHook(args, stdin, stdout, stderr)
	case "run":
		return runCommand(args, stdin, stdout, stderr)
	case "agent":
		return runAgent(stdout, stderr)
	default:
		return dispatchUserCommand(command, args, stdout, stderr)
	}
}

func dispatchUserCommand(command string, args []string, stdout, stderr io.Writer) int {
	switch command {
	case "setup":
		return runSetup(args, stdout, stderr)
	case "start":
		return runStart(stdout, stderr)
	case "status":
		return runStatus(stdout, stderr)
	case "config":
		return runConfig(args, stdout, stderr)
	case "history":
		return runHistory(args, stdout, stderr)
	case "listen":
		return runListen(stdout, stderr)
	case "doctor":
		return runDoctor(stdout, stderr)
	case "stop":
		return runStop(stdout, stderr)
	case "undo":
		return runUndo(stdout, stderr)
	case "reset":
		return runReset(args, stdout, stderr)
	}
	fmt.Fprintf(stderr, "Unknown command: %s\n\n", command)
	printHelp(stderr)
	return 2
}

func printHelp(w io.Writer) {
	fmt.Fprint(w, `Mews watches terminal AI agents and tells you when they need you.

Usage:
  mw setup [--yes] [--include-task-title] [--terminal <name>]
  mw start
  mw status
  mw config terminal [auto|terminal|kitty|iterm2|wezterm|ghostty|alacritty]
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
