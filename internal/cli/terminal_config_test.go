package cli

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Duan-JM/mews/internal/store"
	"github.com/Duan-JM/mews/internal/terminal"
)

func TestTerminalPreferenceCanBeConfiguredAndSurvivesSetup(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	runCLIForTest(t, []string{"setup", "--yes", "--terminal", "kitty"})
	state, configured, err := store.LoadSetupState()
	if err != nil || !configured || state.Terminal != "kitty" {
		t.Fatalf("terminal after setup = %q, configured=%v, err=%v", state.Terminal, configured, err)
	}

	runCLIForTest(t, []string{"config", "terminal", "wezterm"})
	runCLIForTest(t, []string{"setup", "--yes"})
	state, configured, err = store.LoadSetupState()
	if err != nil || !configured || state.Terminal != "wezterm" {
		t.Fatalf("terminal after repeated setup = %q, configured=%v, err=%v", state.Terminal, configured, err)
	}
}

func TestTerminalConfigRequiresSetup(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	if code := Run(
		[]string{"config", "terminal", "kitty"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code != 1 || !strings.Contains(stderr.String(), "not set up") {
		t.Fatalf("config before setup returned %d, stderr=%q", code, stderr.String())
	}

}

func TestTerminalConfigRejectsUnknownProfile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := store.SaveSetupState(store.SetupState{Version: 1}); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	if code := Run(
		[]string{"config", "terminal", "unknown"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code != 2 || !strings.Contains(stderr.String(), "unsupported terminal") {
		t.Fatalf("unknown config returned %d, stderr=%q", code, stderr.String())
	}
}

func TestNotifyCapturesKittyAndTmuxContext(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	binDir := t.TempDir()
	argsPath := filepath.Join(t.TempDir(), "tmux-args")
	tmuxPath := filepath.Join(binDir, "tmux")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$MEWS_TMUX_ARGS\"\nprintf '/dev/ttys006\\n'\n"
	if err := os.WriteFile(tmuxPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
	t.Setenv("MEWS_TMUX_ARGS", argsPath)
	t.Setenv("TERM_PROGRAM", "tmux")
	t.Setenv("KITTY_WINDOW_ID", "17")
	t.Setenv("KITTY_LISTEN_ON", "unix:/tmp/kitty-control")
	socketPath := newOwnedUnixSocket(t)
	t.Setenv("TMUX", socketPath+",9336,2")
	t.Setenv("TMUX_PANE", "%6")

	runCLIForTest(t, []string{"notify", "--source", "copilot", "--status", "done"})
	paths, err := store.Paths()
	if err != nil {
		t.Fatal(err)
	}
	recent, err := store.ReadEvents(paths.Events, 1)
	if err != nil || len(recent) != 1 {
		t.Fatalf("events = %#v, err=%v", recent, err)
	}
	event := recent[0]
	if event.Terminal != "kitty" || event.WindowID != "17" ||
		event.KittyAddr != "unix:/tmp/kitty-control" {
		t.Fatalf("kitty context = %#v", event)
	}
	if event.TmuxSocket != socketPath ||
		event.TmuxPane != "%6" ||
		event.TmuxClient != "/dev/ttys006" {
		t.Fatalf("tmux context = %#v", event)
	}
	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	wantArgs := strings.Join([]string{
		"-S",
		socketPath,
		"display-message",
		"-p",
		"-t",
		"%6",
		"#{client_name}",
		"",
	}, "\n")
	if string(args) != wantArgs {
		t.Fatalf("tmux lookup args = %q, want %q", args, wantArgs)
	}
}

func TestResolveTmuxClientRejectsUnsafeClient(t *testing.T) {
	binDir := t.TempDir()
	tmuxPath := filepath.Join(binDir, "tmux")
	script := "#!/bin/sh\nprintf '/tmp/client\\n'\n"
	if err := os.WriteFile(tmuxPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)

	context := terminal.RuntimeContext{
		TmuxSocket: newOwnedUnixSocket(t),
		TmuxPane:   "%6",
	}
	if client := resolveTmuxClient(context); client != "" {
		t.Fatalf("resolveTmuxClient returned unsafe client %q", client)
	}
}

func newOwnedUnixSocket(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "mews-tmux-test-")
	if err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(directory, "socket")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		_ = os.RemoveAll(directory)
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = listener.Close()
		_ = os.RemoveAll(directory)
	})
	return socketPath
}

func runCLIForTest(t *testing.T, args []string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	if code := Run(args, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("Run(%v) returned %d, stderr=%s", args, code, stderr.String())
	}
}
