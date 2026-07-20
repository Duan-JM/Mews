package cli

import (
	"os"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/terminal"
)

func enrichRuntimeContext(event *events.Event) {
	if event.CWD == "" {
		if cwd, err := os.Getwd(); err == nil {
			event.CWD = cwd
		}
	}
	if event.PID == 0 {
		event.PID = os.Getpid()
	}

	context := terminal.Detect(os.Getenv)
	if event.Terminal == "" {
		event.Terminal = string(context.Profile)
		event.WindowID = context.WindowID
		event.KittyAddr = context.KittyListen
		event.TmuxSocket = context.TmuxSocket
		event.TmuxPane = context.TmuxPane
	}
}
