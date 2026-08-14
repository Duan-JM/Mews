package terminal

import "testing"

func TestDetectFindsKittyAndTmuxContext(t *testing.T) {
	values := map[string]string{
		"TERM_PROGRAM":    "tmux",
		"KITTY_WINDOW_ID": "17",
		"KITTY_LISTEN_ON": "unix:/tmp/kitty-control",
		"TMUX":            "/private/tmp/tmux-501/default,9336,2",
		"TMUX_PANE":       "%6",
	}
	context := Detect(func(key string) string { return values[key] })

	if context.Profile != Kitty || context.WindowID != "17" {
		t.Fatalf("kitty context = %#v", context)
	}
	if context.KittyListen != "unix:/tmp/kitty-control" {
		t.Fatalf("kitty listen = %q", context.KittyListen)
	}
	if context.TmuxSocket != "/private/tmp/tmux-501/default" || context.TmuxPane != "%6" {
		t.Fatalf("tmux context = %#v", context)
	}
}

func TestDetectDropsUnsafeSessionMetadata(t *testing.T) {
	values := map[string]string{
		"KITTY_WINDOW_ID": "window-17",
		"KITTY_LISTEN_ON": "tcp:127.0.0.1:5000",
		"TMUX":            "relative/default,9336,2",
		"TMUX_PANE":       "6",
	}
	context := Detect(func(key string) string { return values[key] })

	if context.Profile != Kitty {
		t.Fatalf("profile = %q, want kitty", context.Profile)
	}
	if context.WindowID != "" || context.KittyListen != "" {
		t.Fatalf("unsafe kitty metadata retained: %#v", context)
	}
	if context.TmuxSocket != "" || context.TmuxPane != "" {
		t.Fatalf("unsafe tmux metadata retained: %#v", context)
	}
}

func TestValidTmuxClientRequiresLocalTTY(t *testing.T) {
	for _, value := range []string{"/dev/ttys006", "/dev/pts/2"} {
		if !ValidTmuxClient(value) {
			t.Fatalf("ValidTmuxClient(%q) = false", value)
		}
	}
	for _, value := range []string{"ttys006", "/tmp/client", "/dev/../tmp/client", "/dev/ttys006\nother"} {
		if ValidTmuxClient(value) {
			t.Fatalf("ValidTmuxClient(%q) = true", value)
		}
	}
}

func TestParseProfileNormalizesAliases(t *testing.T) {
	profile, err := ParseProfile("iTerm")
	if err != nil {
		t.Fatal(err)
	}
	if profile != ITerm2 {
		t.Fatalf("profile = %q, want iterm2", profile)
	}
}
