package health

import (
	"fmt"
	"strings"
)

func Evaluate(observation Observation, previous *Snapshot) Snapshot {
	capabilities := observedCapabilities(observation)
	previousExpired := previous != nil && observation.CheckedAt.After(previous.ValidUntil)
	for index := range capabilities {
		applyTransition(&capabilities[index], previous, previousExpired)
	}

	state := overallState(capabilities)
	return Snapshot{
		Version:      SnapshotVersion,
		State:        state,
		Summary:      summary(state, capabilities),
		CheckedAt:    observation.CheckedAt,
		ValidUntil:   observation.CheckedAt.Add(SnapshotLifetime),
		Capabilities: capabilities,
	}
}

func observedCapabilities(observation Observation) []Capability {
	capabilities := []Capability{
		storeCapability(observation.StoreReady),
		setupCapability(observation.SetupConfigured),
		appCapability(observation.AppBundleReady),
	}
	if observation.SetupConfigured {
		capabilities = append(
			capabilities,
			rollbackCapability(observation.RollbackReady),
			eventDeliveryCapability(observation.Socket, observation.LaunchAgentLoaded),
			automaticStartCapability(
				observation.LaunchAgentPresent,
				observation.LaunchAgentLoaded,
			),
			notificationCapability(observation.Notifications),
		)
		for _, integration := range observation.Integrations {
			capabilities = append(capabilities, integrationCapability(integration))
		}
	}
	return capabilities
}

func rollbackCapability(ready bool) Capability {
	if ready {
		return readyCapability(
			"rollback",
			"Rollback",
			KindConfiguration,
			"Mews-owned integration changes can be undone.",
		)
	}
	return Capability{
		ID:       "rollback",
		Name:     "Rollback",
		Kind:     KindConfiguration,
		State:    StateDegraded,
		Message:  "Recorded rollback state is incomplete.",
		Recovery: "Run `mw setup --yes` to restore Mews-owned integration and rollback state.",
	}
}

func storeCapability(ready bool) Capability {
	if ready {
		return readyCapability("local_store", "Local store", KindFunctional, "Local state is writable.")
	}
	return Capability{
		ID:       "local_store",
		Name:     "Local store",
		Kind:     KindFunctional,
		State:    StateBlocked,
		Message:  "Local state cannot be written.",
		Recovery: "Check permissions for ~/Library/Application Support/Mews.",
	}
}

func setupCapability(configured bool) Capability {
	if configured {
		return readyCapability("setup", "Setup", KindConfiguration, "Mews is configured.")
	}
	return Capability{
		ID:       "setup",
		Name:     "Setup",
		Kind:     KindConfiguration,
		State:    StateBlocked,
		Message:  "Mews has not been set up.",
		Recovery: "Run `mw setup --yes`.",
	}
}

func appCapability(ready bool) Capability {
	if ready {
		return readyCapability("menu_bar_app", "Menu bar app", KindFunctional, "Mews.app is available.")
	}
	return Capability{
		ID:       "menu_bar_app",
		Name:     "Menu bar app",
		Kind:     KindFunctional,
		State:    StateBlocked,
		Message:  "Mews.app is missing.",
		Recovery: "Reinstall Mews or run `make build` from a source checkout.",
	}
}

func eventDeliveryCapability(status SocketStatus, launchAgentLoaded bool) Capability {
	switch status {
	case SocketAvailable:
		return readyCapability(
			"event_delivery",
			"Event delivery",
			KindFunctional,
			"The local agent accepts IPC events.",
		)
	case SocketUnresponsive:
		return Capability{
			ID:       "event_delivery",
			Name:     "Event delivery",
			Kind:     KindFunctional,
			State:    StateBlocked,
			Message:  "The agent socket exists but does not respond.",
			Recovery: "Run `mw start`; Mews.app will keep retrying the local agent.",
		}
	case SocketInvalid:
		return Capability{
			ID:       "event_delivery",
			Name:     "Event delivery",
			Kind:     KindFunctional,
			State:    StateBlocked,
			Message:  "The configured agent socket path is not a Unix socket.",
			Recovery: "Remove the conflicting path, then run `mw start`.",
		}
	default:
		message := "The agent socket is missing."
		if launchAgentLoaded {
			message = "The LaunchAgent is loaded, but the local agent is stopped and its socket is missing."
		}
		return Capability{
			ID:       "event_delivery",
			Name:     "Event delivery",
			Kind:     KindFunctional,
			State:    StateBlocked,
			Message:  message,
			Recovery: "Run `mw start`; Mews.app will keep retrying the local agent.",
		}
	}
}

func automaticStartCapability(present, loaded bool) Capability {
	if present && loaded {
		return readyCapability(
			"automatic_start",
			"Automatic start",
			KindConfiguration,
			"The Mews LaunchAgent is installed and loaded.",
		)
	}
	message := "The Mews LaunchAgent is not installed."
	if present {
		message = "The Mews LaunchAgent is installed but not loaded."
	}
	return Capability{
		ID:       "automatic_start",
		Name:     "Automatic start",
		Kind:     KindConfiguration,
		State:    StateDegraded,
		Message:  message,
		Recovery: "Run `mw start` to restore automatic startup.",
	}
}

func notificationCapability(status NotificationStatus) Capability {
	switch status {
	case NotificationsAuthorized:
		return readyCapability(
			"notifications",
			"Notifications",
			KindFunctional,
			"Native notifications are authorized.",
		)
	case NotificationsDenied:
		return Capability{
			ID:       "notifications",
			Name:     "Notifications",
			Kind:     KindFunctional,
			State:    StateDegraded,
			Message:  "Native notifications are disabled; menu bar status still works.",
			Recovery: "Allow Mews notifications in System Settings.",
		}
	case NotificationsNotDetermined:
		return Capability{
			ID:       "notifications",
			Name:     "Notifications",
			Kind:     KindFunctional,
			State:    StateDegraded,
			Message:  "Notification permission has not been decided.",
			Recovery: "Open Mews.app and respond to the notification permission prompt.",
		}
	case NotificationsInvalid:
		return Capability{
			ID:       "notifications",
			Name:     "Notifications",
			Kind:     KindFunctional,
			State:    StateDegraded,
			Message:  "The notification status file is invalid.",
			Recovery: "Open Mews.app to refresh notification status.",
		}
	case NotificationsStale:
		return Capability{
			ID:       "notifications",
			Name:     "Notifications",
			Kind:     KindFunctional,
			State:    StateDegraded,
			Message:  "Notification status is stale; menu bar status still works.",
			Recovery: "Keep Mews.app running; it refreshes notification permission every 30 seconds.",
		}
	case NotificationsUnreadable:
		return Capability{
			ID:       "notifications",
			Name:     "Notifications",
			Kind:     KindFunctional,
			State:    StateDegraded,
			Message:  "The notification status file is unreadable.",
			Recovery: "Check Mews Application Support permissions, then reopen Mews.app.",
		}
	case NotificationsMissing:
		return Capability{
			ID:       "notifications",
			Name:     "Notifications",
			Kind:     KindFunctional,
			State:    StateDegraded,
			Message:  "Notification capability has not been checked yet.",
			Recovery: "Open Mews.app once to check notification permission.",
		}
	default:
		return Capability{
			ID:       "notifications",
			Name:     "Notifications",
			Kind:     KindFunctional,
			State:    StateDegraded,
			Message:  "Notification authorization is unknown.",
			Recovery: "Keep Mews.app running so it can refresh notification permission.",
		}
	}
}

func integrationCapability(observation IntegrationObservation) Capability {
	id := "integration_" + strings.ReplaceAll(observation.ID, "-", "_")
	if observation.Ready {
		return readyCapability(
			id,
			observation.Name,
			KindConfiguration,
			observation.Name+" integration is configured.",
		)
	}
	return Capability{
		ID:       id,
		Name:     observation.Name,
		Kind:     KindConfiguration,
		State:    StateDegraded,
		Message:  fmt.Sprintf("%s events are affected: %s.", observation.Name, observation.Status),
		Recovery: fmt.Sprintf("Run `mw setup --yes` to repair the %s integration.", observation.Name),
	}
}

func readyCapability(id, name string, kind Kind, message string) Capability {
	return Capability{ID: id, Name: name, Kind: kind, State: StateReady, Message: message}
}

func applyTransition(capability *Capability, previous *Snapshot, previousExpired bool) {
	if previous == nil {
		return
	}
	previousCapability, found := findCapability(previous.Capabilities, capability.ID)
	if !found {
		return
	}

	stableState := previousCapability.State
	if previousCapability.State == StateChecking {
		stableState = previousCapability.TransitionFrom
	}
	targetState := capability.State
	if targetState == stableState {
		return
	}

	count := 1
	if previousCapability.State == StateChecking &&
		previousCapability.TransitionTarget == targetState &&
		!previousExpired {
		count = previousCapability.TransitionCount + 1
	}
	if count >= TransitionConfirmations {
		return
	}

	capability.State = StateChecking
	capability.Message = fmt.Sprintf(
		"Confirming %s change from %s to %s (%d/%d).",
		strings.ToLower(capability.Name),
		stableState,
		targetState,
		count,
		TransitionConfirmations,
	)
	if targetState == StateReady {
		capability.Recovery = "Keep Mews running; the capability will re-enable after the next matching check."
	}
	capability.TransitionFrom = stableState
	capability.TransitionTarget = targetState
	capability.TransitionCount = count
}

func findCapability(capabilities []Capability, id string) (Capability, bool) {
	for index := range capabilities {
		capability := &capabilities[index]
		if capability.ID == id {
			return *capability, true
		}
	}
	return Capability{}, false
}

func overallState(capabilities []Capability) State {
	state := StateReady
	for index := range capabilities {
		capability := &capabilities[index]
		switch capability.State {
		case StateBlocked:
			return StateBlocked
		case StateDegraded:
			state = StateDegraded
		case StateChecking:
			if state == StateReady {
				state = StateChecking
			}
		}
	}
	return state
}

func summary(state State, capabilities []Capability) string {
	affected := 0
	blocked := 0
	for index := range capabilities {
		capability := &capabilities[index]
		if capability.State != StateReady {
			affected++
		}
		if capability.State == StateBlocked {
			blocked++
		}
	}
	switch state {
	case StateReady:
		return "All configured runtime capabilities are available."
	case StateChecking:
		return "Mews is confirming runtime health changes."
	case StateDegraded:
		return fmt.Sprintf("Mews is running with %d affected %s.", affected, plural(affected))
	default:
		return blockedSummary(blocked, affected-blocked)
	}
}

func blockedSummary(blocked, other int) string {
	if other == 0 {
		return fmt.Sprintf("Mews cannot provide all core functions; %d blocked %s.", blocked, plural(blocked))
	}
	return fmt.Sprintf(
		"Mews cannot provide all core functions; %d blocked %s and %d other affected.",
		blocked,
		plural(blocked),
		other,
	)
}

func plural(count int) string {
	if count == 1 {
		return "capability"
	}
	return "capabilities"
}
