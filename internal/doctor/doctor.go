package doctor

import (
	"fmt"
	"io"
	"os"
	"syscall"
	"time"

	"github.com/Duan-JM/mews/internal/health"
	"github.com/Duan-JM/mews/internal/store"
)

type CheckResult struct {
	Name   string
	Status string
	OK     bool
}

type Report struct {
	Health  health.Snapshot
	Results []CheckResult
}

func Check() (Report, error) {
	paths, err := store.Ensure()
	if err != nil {
		return Report{}, err
	}
	snapshot, observation, err := health.Refresh(time.Now())
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
	}
	results = append(results, observationResults(observation)...)
	results = append(
		results,
		CheckResult{Name: "Undo", Status: undoStatus, OK: configured && integrationsConfigured},
	)
	results = append(results, integrationResults(observation.Integrations)...)

	return Report{Health: snapshot, Results: results}, nil
}

func observationResults(observation health.Observation) []CheckResult {
	return []CheckResult{
		appBundleResult(observation),
		launchAgentResult(observation),
		agentResult(observation.Socket),
		socketResult(observation.Socket),
		notificationResult(observation.Notifications),
	}
}

func appBundleResult(observation health.Observation) CheckResult {
	if observation.AppBundleReady {
		return CheckResult{Name: "Menu bar app", Status: observation.AppBundlePath, OK: true}
	}
	return CheckResult{Name: "Menu bar app", Status: "missing; run `make build`", OK: false}
}

func launchAgentResult(observation health.Observation) CheckResult {
	return CheckResult{
		Name:   "LaunchAgent",
		Status: observation.LaunchAgentStatus,
		OK:     observation.LaunchAgentPresent && observation.LaunchAgentLoaded,
	}
}

func integrationResults(integrations []health.IntegrationObservation) []CheckResult {
	results := make([]CheckResult, 0, len(integrations))
	for _, integration := range integrations {
		results = append(results, CheckResult{
			Name: integration.Name, Status: integration.Status, OK: integration.Ready,
		})
	}
	return results
}

func agentResult(status health.SocketStatus) CheckResult {
	if status == health.SocketAvailable {
		return CheckResult{Name: "Local agent", Status: "running", OK: true}
	}
	return CheckResult{Name: "Local agent", Status: "not running", OK: false}
}

func socketResult(status health.SocketStatus) CheckResult {
	switch status {
	case health.SocketAvailable:
		return CheckResult{Name: "Socket", Status: "available", OK: true}
	case health.SocketMissing:
		return CheckResult{Name: "Socket", Status: "not running", OK: false}
	case health.SocketInvalid:
		return CheckResult{Name: "Socket", Status: "path exists but is not a socket", OK: false}
	default:
		return CheckResult{Name: "Socket", Status: "present but not responding", OK: false}
	}
}

func notificationResult(status health.NotificationStatus) CheckResult {
	switch status {
	case health.NotificationsMissing:
		return CheckResult{
			Name: "Notifications", Status: "unknown; start Mews.app once", OK: false,
		}
	case health.NotificationsUnreadable:
		return CheckResult{Name: "Notifications", Status: "unreadable", OK: false}
	case health.NotificationsInvalid:
		return CheckResult{Name: "Notifications", Status: "invalid status file", OK: false}
	case health.NotificationsStale:
		return CheckResult{Name: "Notifications", Status: "stale; Mews.app is not refreshing it", OK: false}
	case health.NotificationsAuthorized:
		return CheckResult{Name: "Notifications", Status: "authorized", OK: true}
	case health.NotificationsDenied:
		return CheckResult{Name: "Notifications", Status: "denied in System Settings", OK: false}
	case health.NotificationsNotDetermined:
		return CheckResult{Name: "Notifications", Status: "permission not decided", OK: false}
	default:
		return CheckResult{Name: "Notifications", Status: "unknown", OK: false}
	}
}

func (r Report) HasFailures() bool {
	if r.Health.HasFailures() {
		return true
	}
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
	health.PrintSummary(w, r.Health)
	fmt.Fprintln(w)
	for _, result := range r.Results {
		fmt.Fprintf(w, "%-16s %s\n", result.Name, result.Status)
	}
}

func checkPath(name, path string) CheckResult {
	info, err := os.Lstat(path)
	if err != nil {
		return CheckResult{Name: name, Status: "missing", OK: false}
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return CheckResult{Name: name, Status: "symlink not allowed", OK: false}
	}
	if !info.IsDir() {
		return CheckResult{Name: name, Status: "missing", OK: false}
	}
	probe, err := os.CreateTemp(path, ".mews-write-test-*")
	if err != nil {
		return CheckResult{Name: name, Status: "not writable", OK: false}
	}
	probePath := probe.Name()
	if err := probe.Close(); err != nil {
		_ = os.Remove(probePath)
		return CheckResult{Name: name, Status: "close failed", OK: false}
	}
	if err := os.Remove(probePath); err != nil {
		return CheckResult{Name: name, Status: "writable, cleanup failed", OK: false}
	}
	return CheckResult{Name: name, Status: "writable", OK: true}
}

func checkFile(name, path string) CheckResult {
	info, err := os.Lstat(path)
	flags := os.O_APPEND | os.O_WRONLY | syscall.O_NOFOLLOW
	switch {
	case err == nil:
		if info.Mode()&os.ModeSymlink != 0 {
			return CheckResult{Name: name, Status: "symlink not allowed", OK: false}
		}
		if info.IsDir() {
			return CheckResult{Name: name, Status: "is a directory", OK: false}
		}
		if !info.Mode().IsRegular() {
			return CheckResult{Name: name, Status: "not a regular file", OK: false}
		}
	case !os.IsNotExist(err):
		return CheckResult{Name: name, Status: "unreadable", OK: false}
	default:
		flags |= os.O_CREATE | os.O_EXCL
	}

	file, err := os.OpenFile(path, flags, 0o600)
	if err != nil {
		return CheckResult{Name: name, Status: "not writable", OK: false}
	}
	if err := file.Close(); err != nil {
		return CheckResult{Name: name, Status: "close failed", OK: false}
	}
	return CheckResult{Name: name, Status: "ready", OK: true}
}
