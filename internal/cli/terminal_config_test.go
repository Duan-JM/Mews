package cli

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Duan-JM/mews/internal/store"
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
	t.Setenv("TERM_PROGRAM", "tmux")
	t.Setenv("KITTY_WINDOW_ID", "17")
	t.Setenv("KITTY_LISTEN_ON", "unix:/tmp/kitty-control")
	t.Setenv("TMUX", "/private/tmp/tmux-501/default,9336,2")
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
	if event.TmuxSocket != "/private/tmp/tmux-501/default" || event.TmuxPane != "%6" {
		t.Fatalf("tmux context = %#v", event)
	}
}

func runCLIForTest(t *testing.T, args []string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	if code := Run(args, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("Run(%v) returned %d, stderr=%s", args, code, stderr.String())
	}
}
