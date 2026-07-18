package cli

import (
	"fmt"
	"io"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/store"
)

func runAgent(stdout, stderr io.Writer) int {
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "Mews local agent started.")
	if err := ipc.ServeWithObserver(paths.Socket, paths.Events, func(event events.Event) {
		printEventSummary(stdout, "Event", &event)
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
		printEventSummary(stdout, "Event", &event)
	}); err != nil {
		fmt.Fprintf(stderr, "Mews listener failed: %v\n", err)
		return 1
	}
	return 0
}
