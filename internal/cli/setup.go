package cli

import (
	"fmt"
	"io"
	"os"
	"time"

	"github.com/Duan-JM/mews/internal/app"
	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/store"
	"github.com/Duan-JM/mews/internal/terminal"
)

type setupOptions struct {
	apply            bool
	includeTaskTitle bool
	terminal         terminal.Profile
}

func runSetup(args []string, stdout, stderr io.Writer) int {
	options, ok := parseSetupOptions(args, stderr)
	if !ok {
		return 2
	}

	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}
	terminalProfile, err := setupTerminalProfile(options.terminal)
	if err != nil {
		fmt.Fprintf(stderr, "Could not read terminal preference: %v\n", err)
		return 1
	}
	printSetupPlan(&paths, options.includeTaskTitle, terminalProfile, stdout)

	if !options.apply {
		fmt.Fprintln(stdout, "Run `mw setup --yes` to apply this safe local setup.")
		fmt.Fprintln(stdout, "Run `mw undo` later to remove Mews-owned setup state.")
		return 0
	}
	return applySetup(options, terminalProfile, stdout, stderr)
}

func parseSetupOptions(args []string, stderr io.Writer) (setupOptions, bool) {
	var options setupOptions
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "--yes", "-y":
			options.apply = true
		case "--include-task-title":
			options.includeTaskTitle = true
		case "--terminal":
			if index+1 >= len(args) {
				printSetupUsage(stderr)
				return setupOptions{}, false
			}
			profile, err := terminal.ParseProfile(args[index+1])
			if err != nil {
				fmt.Fprintf(stderr, "%v. Choose one of: %s\n", err, terminal.Choices())
				return setupOptions{}, false
			}
			options.terminal = profile
			index++
		default:
			fmt.Fprintf(stderr, "Unknown setup option: %s\n", arg)
			printSetupUsage(stderr)
			return setupOptions{}, false
		}
	}
	return options, true
}

func printSetupUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: mw setup [--yes] [--include-task-title] [--terminal <name>]")
}

func printSetupPlan(
	paths *store.StorePaths,
	includeTaskTitle bool,
	terminalProfile terminal.Profile,
	stdout io.Writer,
) {
	fmt.Fprintln(stdout, "Mews setup plan")
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "Mews will:")
	fmt.Fprintf(stdout, "  - create store: %s\n", paths.AppSupport)
	fmt.Fprintf(stdout, "  - create logs: %s\n", paths.Logs)
	if bundle, err := app.ResolveBundle(); err == nil {
		fmt.Fprintf(stdout, "  - launch menu bar app: %s\n", bundle.Path)
	} else {
		fmt.Fprintln(stdout, "  - use the menu bar app after `make build` packages it")
	}
	if hookPath, err := integrations.CopilotHookPath(); err == nil {
		fmt.Fprintf(stdout, "  - install Copilot CLI hooks: %s\n", hookPath)
	}
	if settingsPath, err := integrations.ClaudeSettingsPath(); err == nil {
		fmt.Fprintf(stdout, "  - install Claude Code hooks: %s\n", settingsPath)
	}
	if configPath, err := integrations.CodexConfigPath(); err == nil {
		fmt.Fprintf(stdout, "  - install Codex notify integration: %s\n", configPath)
	}
	fmt.Fprintln(stdout, "  - include project, cwd, hook event, and session metadata in events")
	fmt.Fprintf(stdout, "  - return to terminal: %s\n", terminal.Description(terminalProfile))
	if includeTaskTitle {
		fmt.Fprintln(stdout, "  - include a local-only task title, truncated to 80 characters")
	} else {
		fmt.Fprintln(stdout, "  - skip task titles by default; use --include-task-title to opt in")
	}
	fmt.Fprintln(stdout, "  - record setup state for `mw doctor` and `mw undo`")
	fmt.Fprintln(stdout)
}

func applySetup(
	options setupOptions,
	terminalProfile terminal.Profile,
	stdout io.Writer,
	stderr io.Writer,
) int {
	mwPath, err := os.Executable()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve mw executable path: %v\n", err)
		return 1
	}
	installed, err := integrations.InstallAll(app.StableInstalledPath(mwPath))
	if err != nil {
		fmt.Fprintf(stderr, "Could not install integrations: %v\n", err)
		return 1
	}

	state := newSetupState(installed, options.includeTaskTitle, terminalProfile)
	if err := store.SaveSetupState(state); err != nil {
		_ = integrations.UndoAll()
		fmt.Fprintf(stderr, "Could not save setup state: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews setup state saved.")
	for _, integration := range installed {
		fmt.Fprintf(stdout, "Installed %s integration: %s\n", integration.Name, integration.Path)
	}
	if options.includeTaskTitle {
		fmt.Fprintln(stdout, "Task titles enabled. Mews stores at most 80 local-only characters from hook payloads.")
	}
	fmt.Fprintln(stdout, "Run `mw start` to start the menu bar app.")
	return 0
}

func newSetupState(
	installed []store.IntegrationState,
	includeTaskTitle bool,
	terminalProfile terminal.Profile,
) store.SetupState {
	state := store.SetupState{
		Version:          1,
		SetupAt:          time.Now(),
		Agent:            "menu bar app configured",
		Copilot:          "hooks installed",
		IncludeTaskTitle: includeTaskTitle,
		Terminal:         string(terminalProfile),
		Claude:           "hooks installed",
		UndoReady:        true,
	}
	for index := range installed {
		if installed[index].Name == "copilot" {
			state.CopilotHook = installed[index].Path
		}
	}
	return state
}

func setupTerminalProfile(requested terminal.Profile) (terminal.Profile, error) {
	if requested != "" {
		return requested, nil
	}
	state, configured, err := store.LoadSetupState()
	if err != nil {
		return "", err
	}
	if !configured {
		return terminal.Auto, nil
	}
	return terminal.ParseProfile(state.Terminal)
}
