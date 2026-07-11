package doctor

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/Duan-JM/mews/internal/app"
	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/launchd"
	"github.com/Duan-JM/mews/internal/store"
)

type CheckResult struct {
	Name   string
	Status string
	OK     bool
}

type Report struct {
	Results []CheckResult
}

func Check() (Report, error) {
	paths, err := store.Ensure()
	if err != nil {
		return Report{}, err
	}
	state, configured, err := store.LoadSetupState()
	if err != nil {
		return Report{}, err
	}

	setupStatus := "not set up; run `mw setup`"
	undoStatus := "nothing to undo"
	_, integrationsConfigured, err := store.LoadIntegrationState()
	if err != nil {
		return Report{}, err
	}
	if configured {
		setupStatus = "configured"
		if state.UndoReady && integrationsConfigured {
			undoStatus = "ready"
		}
	}

	results := []CheckResult{
		checkPath("Store", paths.AppSupport),
		checkPath("Logs", paths.Logs),
		checkFile("Events", paths.Events),
		{Name: "Setup", Status: setupStatus, OK: configured},
		checkAppBundle(),
		checkLaunchAgent(),
		checkAgent(paths.Socket),
		checkSocket(paths.Socket),
		checkNotifications(paths.NotificationStatus),
		{Name: "Undo", Status: undoStatus, OK: configured && integrationsConfigured},
	}
	for _, integration := range integrations.Statuses() {
		results = append(results, CheckResult{
			Name: integration.Name, Status: integration.Status, OK: integration.OK,
		})
	}

	return Report{Results: results}, nil
}

func checkNotifications(path string) CheckResult {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return CheckResult{
			Name: "Notifications", Status: "unknown; start Mews.app once", OK: false,
		}
	}
	if err != nil {
		return CheckResult{Name: "Notifications", Status: "unreadable", OK: false}
	}
	var state struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(data, &state); err != nil {
		return CheckResult{Name: "Notifications", Status: "invalid status file", OK: false}
	}
	switch state.Status {
	case "authorized":
		return CheckResult{Name: "Notifications", Status: "authorized", OK: true}
	case "denied":
		return CheckResult{Name: "Notifications", Status: "denied in System Settings", OK: false}
	case "not_determined":
		return CheckResult{Name: "Notifications", Status: "permission not decided", OK: false}
	default:
		return CheckResult{Name: "Notifications", Status: "unknown", OK: false}
	}
}

func (r Report) HasFailures() bool {
	for _, result := range r.Results {
		if !result.OK {
			return true
		}
	}
	return false
}

func (r Report) Print(w io.Writer) {
	fmt.Fprintln(w, "Mews Doctor")
	fmt.Fprintln(w)
	for _, result := range r.Results {
		fmt.Fprintf(w, "%-16s %s\n", result.Name, result.Status)
	}
}

func checkPath(name, path string) CheckResult {
	if info, err := os.Stat(path); err != nil || !info.IsDir() {
		return CheckResult{Name: name, Status: "missing", OK: false}
	}
	probe := filepath.Join(path, ".mews-write-test")
	if err := os.WriteFile(probe, []byte("ok"), 0o600); err != nil {
		return CheckResult{Name: name, Status: "not writable", OK: false}
	}
	if err := os.Remove(probe); err != nil {
		return CheckResult{Name: name, Status: "writable, cleanup failed", OK: false}
	}
	return CheckResult{Name: name, Status: "writable", OK: true}
}

func checkFile(name, path string) CheckResult {
	if info, err := os.Stat(path); err == nil {
		if info.IsDir() {
			return CheckResult{Name: name, Status: "is a directory", OK: false}
		}
		return CheckResult{Name: name, Status: "ready", OK: true}
	} else if !os.IsNotExist(err) {
		return CheckResult{Name: name, Status: "unreadable", OK: false}
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return CheckResult{Name: name, Status: "not writable", OK: false}
	}
	if err := file.Close(); err != nil {
		return CheckResult{Name: name, Status: "close failed", OK: false}
	}
	return CheckResult{Name: name, Status: "ready", OK: true}
}

func checkAppBundle() CheckResult {
	bundle, err := app.ResolveBundle()
	if err != nil {
		return CheckResult{Name: "Menu bar app", Status: "missing; run `make build`", OK: false}
	}
	return CheckResult{Name: "Menu bar app", Status: bundle.Path, OK: true}
}

func checkLaunchAgent() CheckResult {
	plistPath, err := launchd.PlistPath()
	if err != nil {
		return CheckResult{Name: "LaunchAgent", Status: fmt.Sprintf("path error: %v", err), OK: false}
	}
	if _, err := os.Stat(plistPath); os.IsNotExist(err) {
		return CheckResult{Name: "LaunchAgent", Status: "not installed", OK: false}
	} else if err != nil {
		return CheckResult{Name: "LaunchAgent", Status: "unreadable", OK: false}
	}
	if loaded, status := launchd.Loaded(); loaded {
		return CheckResult{Name: "LaunchAgent", Status: status, OK: true}
	} else {
		return CheckResult{Name: "LaunchAgent", Status: status, OK: false}
	}
}

func checkSocket(path string) CheckResult {
	if err := ipc.Ping(path); err == nil {
		return CheckResult{Name: "Socket", Status: "available", OK: true}
	}
	if info, err := os.Stat(path); err == nil {
		if info.Mode()&os.ModeSocket != 0 {
			return CheckResult{Name: "Socket", Status: "present but not responding", OK: false}
		}
		return CheckResult{Name: "Socket", Status: "path exists but is not a socket", OK: false}
	} else if !os.IsNotExist(err) {
		return CheckResult{Name: "Socket", Status: "unreadable", OK: false}
	}
	return CheckResult{Name: "Socket", Status: "not running", OK: false}
}

func checkAgent(socketPath string) CheckResult {
	if err := ipc.Ping(socketPath); err == nil {
		return CheckResult{Name: "Local agent", Status: "running", OK: true}
	}
	return CheckResult{Name: "Local agent", Status: "not running", OK: false}
}
