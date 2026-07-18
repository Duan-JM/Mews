package cli

import (
	"fmt"
	"io"

	"github.com/Duan-JM/mews/internal/doctor"
	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/launchd"
	"github.com/Duan-JM/mews/internal/store"
)

func runDoctor(stdout, stderr io.Writer) int {
	report, err := doctor.Check()
	if err != nil {
		fmt.Fprintf(stderr, "Doctor failed: %v\n", err)
		return 1
	}
	report.Print(stdout)
	if report.HasFailures() {
		return 1
	}
	return 0
}

func runStop(stdout, stderr io.Writer) int {
	paths, err := store.Paths()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve Mews paths: %v\n", err)
		return 1
	}
	stopped := false
	if err := ipc.Stop(paths.Socket); err == nil {
		stopped = true
	} else if err != ipc.ErrUnavailable {
		fmt.Fprintf(stderr, "Could not stop Mews local agent: %v\n", err)
		return 1
	}
	if err := launchd.Bootout(); err != nil {
		fmt.Fprintf(stderr, "Could not unload Mews LaunchAgent: %v\n", err)
		return 1
	}
	if err := launchd.RemovePlist(); err != nil {
		fmt.Fprintf(stderr, "Could not remove Mews LaunchAgent: %v\n", err)
		return 1
	}
	if stopped {
		fmt.Fprintln(stdout, "Mews menu bar app stopped.")
	} else {
		fmt.Fprintln(stdout, "Mews menu bar app is not running.")
	}
	return 0
}

func runUndo(stdout, stderr io.Writer) int {
	setupState, setupConfigured, err := store.LoadSetupState()
	if err != nil {
		fmt.Fprintf(stderr, "Could not read setup state: %v\n", err)
		return 1
	}
	_, integrationsConfigured, err := store.LoadIntegrationState()
	if err != nil {
		fmt.Fprintf(stderr, "Could not read integration state: %v\n", err)
		return 1
	}
	if !setupConfigured && !integrationsConfigured {
		fmt.Fprintln(stdout, "No Mews setup state or integrations are installed.")
		return 0
	}

	if code := undoIntegrations(setupState, integrationsConfigured, stderr); code != 0 {
		return code
	}
	if err := launchd.Bootout(); err != nil {
		fmt.Fprintf(stderr, "Could not unload Mews LaunchAgent: %v\n", err)
		return 1
	}
	if err := launchd.RemovePlist(); err != nil {
		fmt.Fprintf(stderr, "Could not remove Mews LaunchAgent: %v\n", err)
		return 1
	}
	if err := store.RemoveSetupState(); err != nil {
		fmt.Fprintf(stderr, "Could not remove setup state: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Removed Mews setup state.")
	fmt.Fprintln(stdout, "Removed Mews-owned integrations.")
	fmt.Fprintln(stdout, "Removed Mews LaunchAgent.")
	fmt.Fprintln(stdout, "Event history was kept. Run `mw reset --yes` to delete local Mews data.")
	return 0
}

func undoIntegrations(setupState store.SetupState, integrationsConfigured bool, stderr io.Writer) int {
	if integrationsConfigured {
		if err := integrations.UndoAll(); err != nil {
			fmt.Fprintf(stderr, "Could not remove integrations: %v\n", err)
			return 1
		}
		return 0
	}
	if setupState.Claude == "hooks installed" {
		fmt.Fprintln(stderr, "Could not remove integrations: integration rollback state is missing.")
		fmt.Fprintln(stderr, "Restore integrations.json from backup before retrying `mw undo`.")
		return 1
	}

	var err error
	if setupState.CopilotHook != "" {
		err = integrations.RemoveRecordedCopilotHookAt(setupState.CopilotHook)
	} else {
		err = integrations.RemoveCopilotHooks()
	}
	if err != nil {
		fmt.Fprintf(stderr, "Could not remove integrations: %v\n", err)
		return 1
	}
	return 0
}

func runReset(args []string, stdout, stderr io.Writer) int {
	apply, ok := parseResetOptions(args, stderr)
	if !ok {
		return 2
	}
	if !apply {
		fmt.Fprintln(stderr, "Usage: mw reset --yes")
		fmt.Fprintln(stderr, "This deletes Mews local store, logs, and event history after `mw undo`.")
		return 2
	}
	if !resetAllowed(stderr) {
		return 1
	}
	if err := store.Reset(); err != nil {
		fmt.Fprintf(stderr, "Could not reset Mews data: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Deleted Mews local store and logs.")
	return 0
}

func parseResetOptions(args []string, stderr io.Writer) (bool, bool) {
	apply := false
	for _, arg := range args {
		switch arg {
		case "--yes", "-y":
			apply = true
		default:
			fmt.Fprintf(stderr, "Unknown reset option: %s\n", arg)
			fmt.Fprintln(stderr, "Usage: mw reset --yes")
			return false, false
		}
	}
	return apply, true
}

func resetAllowed(stderr io.Writer) bool {
	if _, configured, err := store.LoadSetupState(); err != nil {
		fmt.Fprintf(stderr, "Could not read setup state: %v\n", err)
		return false
	} else if configured {
		fmt.Fprintln(stderr, "Mews integrations are still configured.")
		fmt.Fprintln(stderr, "Run `mw undo` before `mw reset --yes` so external config remains reversible.")
		return false
	}
	if _, configured, err := store.LoadIntegrationState(); err != nil {
		fmt.Fprintf(stderr, "Could not read integration state: %v\n", err)
		return false
	} else if configured {
		fmt.Fprintln(stderr, "Mews integration rollback state still exists.")
		fmt.Fprintln(stderr, "Run `mw undo` before `mw reset --yes`.")
		return false
	}
	return true
}
