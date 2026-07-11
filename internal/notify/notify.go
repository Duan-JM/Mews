package notify

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/Duan-JM/mews/internal/events"
)

var run = func(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}

func ShouldSend(status events.Status) bool {
	switch status {
	case events.StatusNeedsInput, events.StatusDone, events.StatusFailed:
		return true
	default:
		return false
	}
}

func Send(event events.Event) error {
	if !ShouldSend(event.Status) {
		return nil
	}
	if os.Getenv("MEWS_TESTING") == "1" {
		return nil
	}
	message := fmt.Sprintf("%s: %s", event.Source, event.Status)
	if event.Message != "" {
		message = event.Message
	}
	return run(
		"osascript",
		"-e", "on run argv",
		"-e", "display notification (item 1 of argv) with title (item 2 of argv)",
		"-e", "end run",
		"--", message, "Mews",
	)
}
