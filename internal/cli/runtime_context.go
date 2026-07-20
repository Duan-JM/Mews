package cli

import (
	"os"
	"os/exec"
	"strings"
	"syscall"

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
	context.TmuxClient = resolveTmuxClient(context)
	if context.TmuxSocket != "" && context.TmuxClient == "" {
		context.TmuxSocket = ""
		context.TmuxPane = ""
	}
	if event.Terminal == "" {
		event.Terminal = string(context.Profile)
		event.WindowID = context.WindowID
		event.KittyAddr = context.KittyListen
		event.TmuxSocket = context.TmuxSocket
		event.TmuxPane = context.TmuxPane
		event.TmuxClient = context.TmuxClient
	}
}

func resolveTmuxClient(context terminal.RuntimeContext) string {
	if context.TmuxSocket == "" || context.TmuxPane == "" || !isOwnedUnixSocket(context.TmuxSocket) {
		return ""
	}
	output, err := exec.Command(
		"tmux",
		"-S", context.TmuxSocket,
		"display-message", "-p",
		"-t", context.TmuxPane,
		"#{client_name}",
	).Output()
	if err != nil {
		return ""
	}
	client := strings.TrimSpace(string(output))
	if !terminal.ValidTmuxClient(client) {
		return ""
	}
	return client
}

func isOwnedUnixSocket(path string) bool {
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uint32(os.Getuid())
}
