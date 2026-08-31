package cli

import (
	"os"
	"os/exec"
	"path/filepath"
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
	if context.TmuxSocket != "" {
		if !isOwnedUnixSocket(context.TmuxSocket) {
			context.TmuxSocket = ""
			context.TmuxPane = ""
		} else {
			context.TmuxClient = resolveTmuxClient(context)
		}
	}
	if event.Terminal == "" {
		event.Terminal = string(context.Profile)
		event.WindowID = context.WindowID
		event.KittyAddr = context.KittyListen
		event.TmuxSocket = context.TmuxSocket
		event.TmuxPane = context.TmuxPane
		event.TmuxClient = context.TmuxClient
	}
	if event.Source == "codex" {
		switch {
		case context.TmuxSocket != "":
			event.LaunchContext = events.LaunchContextTmux
		case isCodexAppEnvironment(os.Getenv):
			event.LaunchContext = events.LaunchContextCodexApp
		default:
			event.LaunchContext = events.LaunchContextUnknown
		}
	}
}

func isCodexAppEnvironment(getenv func(string) string) bool {
	originator := strings.TrimSpace(getenv("CODEX_INTERNAL_ORIGINATOR_OVERRIDE"))
	if originator != "Codex" && originator != "codex_desktop" {
		return false
	}
	resources := filepath.Clean(strings.TrimSpace(getenv("CODEX_ELECTRON_RESOURCES_PATH")))
	if filepath.IsAbs(resources) &&
		strings.HasSuffix(resources, ".app/Contents/Resources") {
		return true
	}
	node := filepath.Clean(strings.TrimSpace(getenv("CODEX_MCP_NODE_PATH")))
	return filepath.IsAbs(node) &&
		strings.HasSuffix(node, ".app/Contents/Resources/cua_node/bin/node")
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
