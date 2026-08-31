package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/terminal"
)

type processInfoLookup func(int) (int, string, error)

type runtimeContextSource struct {
	getenv      func(string) string
	pid         int
	parentPID   int
	processInfo processInfoLookup
}

func enrichRuntimeContext(event *events.Event) {
	enrichRuntimeContextWith(event, runtimeContextSource{
		getenv:      os.Getenv,
		pid:         os.Getpid(),
		parentPID:   os.Getppid(),
		processInfo: processInfo,
	})
}

func enrichRuntimeContextWith(event *events.Event, source runtimeContextSource) {
	if event.CWD == "" {
		if cwd, err := os.Getwd(); err == nil {
			event.CWD = cwd
		}
	}
	if event.PID == 0 {
		event.PID = source.pid
	}

	context := terminal.Detect(source.getenv)
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
		case isCodexAppEnvironment(source.getenv),
			isCodexAppProcessAncestry(source.parentPID, source.processInfo):
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

func isCodexAppProcessAncestry(
	pid int,
	lookup func(int) (int, string, error),
) bool {
	const maxAncestors = 12

	var appBundle string
	seen := make(map[int]struct{}, maxAncestors)
	for range maxAncestors {
		if pid <= 1 {
			return false
		}
		if _, ok := seen[pid]; ok {
			return false
		}
		seen[pid] = struct{}{}

		parentPID, executable, err := lookup(pid)
		if err != nil {
			return false
		}
		executable = filepath.Clean(strings.TrimSpace(executable))
		if appBundle == "" {
			appBundle = codexAppBundleForRuntime(executable)
		} else if isCodexAppMainExecutable(appBundle, executable) {
			return true
		}
		pid = parentPID
	}
	return false
}

func codexAppBundleForRuntime(executable string) string {
	if !filepath.IsAbs(executable) {
		return ""
	}
	suffix := filepath.Join("Contents", "Resources", "codex")
	if !strings.HasSuffix(executable, suffix) {
		return ""
	}
	bundle := strings.TrimSuffix(executable, suffix)
	bundle = strings.TrimSuffix(bundle, string(filepath.Separator))
	if !strings.HasSuffix(strings.ToLower(bundle), ".app") {
		return ""
	}
	return bundle
}

func isCodexAppMainExecutable(bundle, executable string) bool {
	if filepath.Dir(executable) != filepath.Join(bundle, "Contents", "MacOS") {
		return false
	}
	bundleName := strings.TrimSuffix(filepath.Base(bundle), filepath.Ext(bundle))
	return filepath.Base(executable) == bundleName
}

func processInfo(pid int) (int, string, error) {
	output, err := exec.Command(
		"/bin/ps",
		"-p", strconv.Itoa(pid),
		"-o", "ppid=",
		"-o", "comm=",
	).Output()
	if err != nil {
		return 0, "", err
	}
	line := strings.TrimSpace(string(output))
	split := strings.IndexAny(line, " \t")
	if split < 1 {
		return 0, "", strconv.ErrSyntax
	}
	parentPID, err := strconv.Atoi(line[:split])
	if err != nil {
		return 0, "", err
	}
	return parentPID, strings.TrimSpace(line[split:]), nil
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
