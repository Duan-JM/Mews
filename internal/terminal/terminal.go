package terminal

import (
	"fmt"
	"path/filepath"
	"strings"
)

type Profile string

const (
	Auto      Profile = "auto"
	Terminal  Profile = "terminal"
	Kitty     Profile = "kitty"
	ITerm2    Profile = "iterm2"
	WezTerm   Profile = "wezterm"
	Ghostty   Profile = "ghostty"
	Alacritty Profile = "alacritty"
)

type RuntimeContext struct {
	Profile     Profile
	WindowID    string
	KittyListen string
	TmuxSocket  string
	TmuxPane    string
	TmuxClient  string
}

var profileAliases = map[string]Profile{
	"auto":           Auto,
	"terminal":       Terminal,
	"apple-terminal": Terminal,
	"macos-terminal": Terminal,
	"kitty":          Kitty,
	"iterm":          ITerm2,
	"iterm2":         ITerm2,
	"wezterm":        WezTerm,
	"ghostty":        Ghostty,
	"alacritty":      Alacritty,
}

func ParseProfile(value string) (Profile, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return Auto, nil
	}
	profile, ok := profileAliases[normalized]
	if !ok {
		return "", fmt.Errorf("unsupported terminal %q", value)
	}
	return profile, nil
}

func IsSourceProfile(value string) bool {
	profile, err := ParseProfile(value)
	return err == nil && profile != Auto && string(profile) == value
}

func Choices() string {
	return "auto, terminal, kitty, iterm2, wezterm, ghostty, alacritty"
}

func Description(profile Profile) string {
	if profile == Auto {
		return "auto (origin terminal, Terminal fallback)"
	}
	return string(profile)
}

func Detect(getenv func(string) string) RuntimeContext {
	context := RuntimeContext{Profile: detectProfile(getenv)}
	if context.Profile == Kitty {
		context.WindowID = validWindowID(getenv("KITTY_WINDOW_ID"))
		context.KittyListen = validKittyListen(getenv("KITTY_LISTEN_ON"))
	}
	context.TmuxSocket, context.TmuxPane = parseTmux(getenv("TMUX"), getenv("TMUX_PANE"))
	return context
}

func ValidWindowID(value string) bool {
	return value != "" && value == validWindowID(value)
}

func ValidKittyListen(value string) bool {
	return value != "" && value == validKittyListen(value)
}

func ValidTmuxSocket(value string) bool {
	return value != "" && filepath.IsAbs(value) && len(value) <= 4096
}

func ValidTmuxPane(value string) bool {
	if len(value) < 2 || value[0] != '%' {
		return false
	}
	return digitsOnly(value[1:])
}

func ValidTmuxClient(value string) bool {
	if value == "" || len(value) > 4096 || strings.ContainsAny(value, "\x00\r\n") {
		return false
	}
	cleaned := filepath.Clean(value)
	return value == cleaned && filepath.IsAbs(cleaned) && strings.HasPrefix(cleaned, "/dev/")
}

func detectProfile(getenv func(string) string) Profile {
	switch {
	case strings.TrimSpace(getenv("KITTY_WINDOW_ID")) != "":
		return Kitty
	case strings.TrimSpace(getenv("ITERM_SESSION_ID")) != "":
		return ITerm2
	case strings.TrimSpace(getenv("WEZTERM_PANE")) != "":
		return WezTerm
	case strings.TrimSpace(getenv("GHOSTTY_RESOURCES_DIR")) != "":
		return Ghostty
	case strings.TrimSpace(getenv("ALACRITTY_WINDOW_ID")) != "":
		return Alacritty
	}

	switch strings.ToLower(strings.TrimSpace(getenv("TERM_PROGRAM"))) {
	case "apple_terminal":
		return Terminal
	case "iterm.app", "iterm2":
		return ITerm2
	case "wezterm":
		return WezTerm
	case "ghostty":
		return Ghostty
	case "alacritty":
		return Alacritty
	}
	if strings.TrimSpace(getenv("TERM_SESSION_ID")) != "" {
		return Terminal
	}
	return ""
}

func parseTmux(value, pane string) (string, string) {
	pane = strings.TrimSpace(pane)
	if !ValidTmuxPane(pane) {
		return "", ""
	}
	lastComma := strings.LastIndex(value, ",")
	if lastComma < 0 {
		return "", ""
	}
	previousComma := strings.LastIndex(value[:lastComma], ",")
	if previousComma < 0 {
		return "", ""
	}
	socket := strings.TrimSpace(value[:previousComma])
	if !ValidTmuxSocket(socket) {
		return "", ""
	}
	return socket, pane
}

func validWindowID(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 64 || !digitsOnly(value) {
		return ""
	}
	return value
}

func validKittyListen(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 4096 || !strings.HasPrefix(value, "unix:/") {
		return ""
	}
	return value
}

func digitsOnly(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}
