package health

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"time"

	"github.com/Duan-JM/mews/internal/app"
	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/ipc"
	"github.com/Duan-JM/mews/internal/launchd"
	"github.com/Duan-JM/mews/internal/store"
)

func Observe(now time.Time) (Observation, error) {
	paths, err := store.Ensure()
	if err != nil {
		return Observation{}, err
	}
	setupState, configured, err := store.LoadSetupState()
	if err != nil {
		return Observation{}, err
	}
	_, integrationsConfigured, err := store.LoadIntegrationState()
	if err != nil {
		return Observation{}, err
	}

	bundle, appErr := app.ResolveBundle()
	appBundlePath := ""
	if appErr == nil {
		appBundlePath = bundle.Path
	}
	launchAgentPresent, launchAgentLoaded, launchAgentStatus := observeLaunchAgent()

	integrationStatuses := integrations.Statuses()
	observedIntegrations := make([]IntegrationObservation, 0, len(integrationStatuses))
	for _, status := range integrationStatuses {
		observedIntegrations = append(observedIntegrations, IntegrationObservation{
			ID:     integrationID(status.Name),
			Name:   status.Name,
			Status: strings.TrimSuffix(status.Status, "."),
			Ready:  status.OK,
		})
	}

	return Observation{
		CheckedAt:          now,
		StoreReady:         storeFilesWritable(paths),
		SetupConfigured:    configured,
		RollbackReady:      setupState.UndoReady && integrationsConfigured,
		AppBundleReady:     appErr == nil,
		AppBundlePath:      appBundlePath,
		LaunchAgentPresent: launchAgentPresent,
		LaunchAgentLoaded:  launchAgentLoaded,
		LaunchAgentStatus:  launchAgentStatus,
		Socket:             observeSocket(paths.Socket),
		Notifications:      ReadNotificationStatus(paths.NotificationStatus, now),
		Integrations:       observedIntegrations,
	}, nil
}

func Refresh(now time.Time) (Snapshot, Observation, error) {
	paths, err := store.Paths()
	if err != nil {
		return Snapshot{}, Observation{}, err
	}
	previous, err := Load(paths.RuntimeHealth, now)
	if err != nil {
		return Snapshot{}, Observation{}, err
	}
	observation, err := Observe(now)
	if err != nil {
		return Snapshot{}, Observation{}, err
	}
	snapshot := Evaluate(observation, previous)
	if previous != nil && sameConclusion(*previous, snapshot) &&
		now.Before(previous.ValidUntil.Add(-snapshotRefreshMargin)) {
		return *previous, observation, nil
	}
	if err := Save(paths.RuntimeHealth, snapshot); err != nil {
		return Snapshot{}, Observation{}, err
	}
	return snapshot, observation, nil
}

func Monitor(interval time.Duration, done <-chan struct{}, reportError func(error)) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case checkedAt := <-ticker.C:
			if _, _, err := Refresh(checkedAt); err != nil && reportError != nil {
				reportError(err)
			}
		case <-done:
			return
		}
	}
}

func observeSocket(path string) SocketStatus {
	if err := ipc.Ping(path); err == nil {
		return SocketAvailable
	}
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return SocketMissing
	}
	if err != nil {
		return SocketUnresponsive
	}
	if info.Mode()&os.ModeSocket == 0 {
		return SocketInvalid
	}
	return SocketUnresponsive
}

func observeLaunchAgent() (bool, bool, string) {
	path, err := launchd.PlistPath()
	if err != nil {
		return false, false, fmt.Sprintf("path error: %v", err)
	}
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return false, false, "not installed"
	} else if err != nil {
		return false, false, "unreadable"
	}
	loaded, status := launchd.Loaded()
	return true, loaded, status
}

func storeFilesWritable(paths store.StorePaths) bool {
	return fileWritable(paths.Events) &&
		fileWritable(filepath.Join(paths.Logs, "agent.log"))
}

func fileWritable(path string) bool {
	info, err := os.Lstat(path)
	flags := os.O_APPEND | os.O_WRONLY | syscall.O_NOFOLLOW
	if os.IsNotExist(err) {
		flags |= os.O_CREATE | os.O_EXCL
	} else if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return false
	}

	file, err := os.OpenFile(path, flags, 0o600)
	if err != nil {
		return false
	}
	return file.Close() == nil
}

func integrationID(name string) string {
	return strings.ToLower(strings.ReplaceAll(name, " ", "-"))
}

func sameConclusion(left, right Snapshot) bool {
	return left.State == right.State &&
		left.Summary == right.Summary &&
		reflect.DeepEqual(left.Capabilities, right.Capabilities)
}
