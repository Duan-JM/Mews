package cli

import (
	"fmt"
	"io"
	"strings"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/store"
)

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
	printEventSummary(stdout, "Latest event", &recent[0])
	return 0
}

func runHistory(args []string, stdout, stderr io.Writer) int {
	sessionFilter, ok := parseSessionFilter(args, stderr)
	if !ok {
		return 2
	}

	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}
	recent, err := store.ReadEvents(paths.Events, historyLimit(sessionFilter))
	if err != nil {
		fmt.Fprintf(stderr, "Could not read event history: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews History")
	if sessionFilter != "" {
		fmt.Fprintf(stdout, "Session: %s\n", sessionFilter)
		recent = filterSession(recent, sessionFilter)
	}
	if len(recent) == 0 {
		fmt.Fprintln(stdout, "No events yet.")
		return 0
	}
	for index := range recent {
		printEventSummary(stdout, "-", &recent[index])
	}
	return 0
}

func parseSessionFilter(args []string, stderr io.Writer) (string, bool) {
	sessionFilter := ""
	for index := 0; index < len(args); index++ {
		switch args[index] {
		case "--session":
			if index+1 >= len(args) {
				fmt.Fprintln(stderr, "Usage: mw history [--session <id>]")
				return "", false
			}
			sessionFilter = args[index+1]
			index++
		default:
			fmt.Fprintf(stderr, "Unknown history option: %s\n", args[index])
			fmt.Fprintln(stderr, "Usage: mw history [--session <id>]")
			return "", false
		}
	}
	return sessionFilter, true
}

func historyLimit(sessionFilter string) int {
	if sessionFilter != "" {
		return 200
	}
	return 10
}

func filterSession(recent []events.Event, sessionFilter string) []events.Event {
	filtered := recent[:0]
	for index := range recent {
		if recent[index].SessionID == sessionFilter {
			filtered = append(filtered, recent[index])
		}
	}
	return filtered
}

func printEventSummary(w io.Writer, prefix string, event *events.Event) {
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
