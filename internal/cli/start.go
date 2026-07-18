package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/Duan-JM/mews/internal/app"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/launchd"
	"github.com/Duan-JM/mews/internal/store"
)

var pingAgent = ipc.Ping
var bootstrapLaunchAgent = launchd.Bootstrap
var registerBundle = app.RegisterBundle
var bootstrapRetryDelay = 20 * time.Millisecond

type startState struct {
	loadedJob    launchd.LoadedJob
	loaded       bool
	agentRunning bool
}

func runStart(stdout, stderr io.Writer) int {
	paths, err := store.Ensure()
	if err != nil {
		fmt.Fprintf(stderr, "Could not prepare Mews store: %v\n", err)
		return 1
	}
	if !setupReady(stdout, stderr) {
		return 1
	}

	state, ok := inspectStartState(&paths, stdout, stderr)
	if !ok {
		return 1
	}
	bundle, plistPath, ok := installMenuBarApp(&paths, stderr)
	if !ok {
		return 1
	}
	if !stopExistingAgent(state, paths.Socket, stderr) {
		return 1
	}
	if !activateMenuBarApp(state, bundle, &paths, stderr) {
		return 1
	}
	if err := waitForAgent(paths.Socket, 2*time.Second); err != nil {
		fmt.Fprintf(stderr, "Mews menu bar app did not start its local agent: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Mews menu bar app is running.")
	fmt.Fprintf(stdout, "  LaunchAgent: %s\n", plistPath)
	fmt.Fprintf(stdout, "  Store: %s\n", paths.AppSupport)
	return 0
}

func setupReady(stdout, stderr io.Writer) bool {
	_, configured, err := store.LoadSetupState()
	if err != nil {
		fmt.Fprintf(stderr, "Could not read setup state: %v\n", err)
		return false
	}
	if configured {
		return true
	}
	fmt.Fprintln(stdout, "Mews is not set up yet.")
	fmt.Fprintln(stdout, "Run `mw setup` to review the local setup plan.")
	fmt.Fprintln(stdout, "Run `mw setup --yes` to create Mews-owned setup state.")
	return false
}

func inspectStartState(paths *store.StorePaths, stdout, stderr io.Writer) (startState, bool) {
	loadedJob, loaded, err := launchd.CurrentJob()
	if err != nil {
		fmt.Fprintf(stderr, "Could not inspect Mews LaunchAgent: %v\n", err)
		return startState{}, false
	}

	state := startState{loadedJob: loadedJob, loaded: loaded}
	if err := ipc.Ping(paths.Socket); err == nil {
		state.agentRunning = true
		if loaded {
			fmt.Fprintln(stdout, "Mews menu bar app is already running; refreshing it.")
		} else {
			fmt.Fprintln(stdout, "Mews local agent is already running; starting menu bar app too.")
		}
	} else if !errors.Is(err, ipc.ErrUnavailable) {
		fmt.Fprintf(stderr, "Could not check Mews local agent: %v\n", err)
		return startState{}, false
	}
	return state, true
}

func installMenuBarApp(paths *store.StorePaths, stderr io.Writer) (app.Bundle, string, bool) {
	bundle, err := app.ResolveBundle()
	if err != nil {
		fmt.Fprintf(stderr, "Could not find Mews.app: %v\n", err)
		fmt.Fprintln(stderr, "Run `make build` from the repository, or install a package that includes Mews.app.")
		return app.Bundle{}, "", false
	}
	if err := registerBundle(bundle.Path); err != nil {
		fmt.Fprintf(stderr, "Could not register Mews.app icon: %v\n", err)
		return app.Bundle{}, "", false
	}
	plistPath, err := launchd.Install(bundle.Executable, paths.Logs)
	if err != nil {
		fmt.Fprintf(stderr, "Could not install LaunchAgent: %v\n", err)
		return app.Bundle{}, "", false
	}
	return bundle, plistPath, true
}

func stopExistingAgent(state startState, socketPath string, stderr io.Writer) bool {
	if !state.loaded || !state.agentRunning {
		return true
	}
	if err := ipc.Stop(socketPath); err != nil && !errors.Is(err, ipc.ErrUnavailable) {
		fmt.Fprintf(stderr, "Could not stop the existing Mews local agent: %v\n", err)
		return false
	}
	if err := waitForAgentStop(socketPath, 2*time.Second); err != nil {
		fmt.Fprintf(stderr, "Existing Mews local agent did not stop: %v\n", err)
		return false
	}
	return true
}

func activateMenuBarApp(state startState, bundle app.Bundle, paths *store.StorePaths, stderr io.Writer) bool {
	if !state.loaded {
		if err := bootstrapWithRetry(2 * time.Second); err != nil {
			fmt.Fprintf(stderr, "Could not start Mews menu bar app: %v\n", err)
			return false
		}
		return true
	}

	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(stderr, "Could not resolve the current home directory: %v\n", err)
		return false
	}
	if loadedJobMatches(state.loadedJob, bundle.Executable, home, paths) {
		if err := launchd.Kickstart(); err != nil {
			fmt.Fprintf(stderr, "Could not refresh Mews menu bar app: %v\n", err)
			return false
		}
		return true
	}
	return replaceLaunchAgent(state.loadedJob, stderr)
}

func loadedJobMatches(job launchd.LoadedJob, executable, home string, paths *store.StorePaths) bool {
	desiredLogPath := filepath.Join(paths.Logs, "app.log")
	return job.Program == executable &&
		job.HomePath == home &&
		job.SocketNamespace == os.Getenv("MEWS_SOCKET_NAMESPACE") &&
		job.StdoutPath == desiredLogPath &&
		job.StderrPath == desiredLogPath
}

func replaceLaunchAgent(previous launchd.LoadedJob, stderr io.Writer) bool {
	if err := launchd.Bootout(); err != nil {
		fmt.Fprintf(stderr, "Could not replace Mews LaunchAgent: %v\n", err)
		return false
	}
	startErr := bootstrapWithRetry(2 * time.Second)
	if startErr == nil {
		return true
	}

	_, restoreErr := launchd.InstallLoadedJob(previous)
	if restoreErr == nil {
		restoreErr = bootstrapWithRetry(2 * time.Second)
	}
	if restoreErr != nil {
		fmt.Fprintf(
			stderr,
			"Could not start the new Mews app (%v) or restore the previous LaunchAgent (%v).\n",
			startErr,
			restoreErr,
		)
	} else {
		fmt.Fprintf(
			stderr,
			"Could not start the new Mews app; the previous LaunchAgent was restored: %v\n",
			startErr,
		)
	}
	return false
}

func waitForAgent(socketPath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := pingAgent(socketPath); err == nil {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return ipc.ErrUnavailable
}

func waitForAgentStop(socketPath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := pingAgent(socketPath); err != nil {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return errors.New("timed out waiting for local agent to stop")
}

func bootstrapWithRetry(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		err := bootstrapLaunchAgent()
		if err == nil {
			return nil
		}
		if !launchd.IsBootstrapRace(err) || !time.Now().Before(deadline) {
			return err
		}
		time.Sleep(bootstrapRetryDelay)
	}
}
