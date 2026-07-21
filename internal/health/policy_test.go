package health

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMissingSocketBlocksEventDelivery(t *testing.T) {
	observation := healthyObservation()
	observation.Socket = SocketMissing
	observation.LaunchAgentPresent = false
	observation.LaunchAgentLoaded = false

	snapshot := Evaluate(observation, nil)

	assertCapability(t, snapshot, "event_delivery", StateBlocked, "agent socket is missing")
	if snapshot.State != StateBlocked {
		t.Fatalf("state = %q, want %q", snapshot.State, StateBlocked)
	}
	if !strings.Contains(snapshot.Summary, "1 blocked capability and 1 other affected") {
		t.Fatalf("summary = %q, want precise blocked and degraded counts", snapshot.Summary)
	}
}

func TestUnwritableStoreBlocksLocalState(t *testing.T) {
	observation := healthyObservation()
	observation.StoreReady = false

	snapshot := Evaluate(observation, nil)

	assertCapability(t, snapshot, "local_store", StateBlocked, "cannot be written")
}

func TestIncompleteRollbackStateDegradesConfiguration(t *testing.T) {
	observation := healthyObservation()
	observation.RollbackReady = false

	snapshot := Evaluate(observation, nil)

	assertCapability(t, snapshot, "rollback", StateDegraded, "rollback state is incomplete")
	assertOnlyAffected(t, snapshot, "rollback")
}

func TestStoppedAgentIsDistinctFromLaunchAgentConfiguration(t *testing.T) {
	observation := healthyObservation()
	observation.Socket = SocketMissing

	snapshot := Evaluate(observation, nil)

	assertCapability(t, snapshot, "event_delivery", StateBlocked, "local agent is stopped")
	capability := requireCapability(t, snapshot, "automatic_start")
	if capability.State != StateReady {
		t.Fatalf("automatic start = %#v, want ready while functional IPC is blocked", capability)
	}
}

func TestUnresponsiveSocketReportsFunctionalFailure(t *testing.T) {
	observation := healthyObservation()
	observation.Socket = SocketUnresponsive

	snapshot := Evaluate(observation, nil)

	assertCapability(t, snapshot, "event_delivery", StateBlocked, "does not respond")
}

func TestNotificationDenialOnlyDegradesNotifications(t *testing.T) {
	observation := healthyObservation()
	observation.Notifications = NotificationsDenied

	snapshot := Evaluate(observation, nil)

	assertCapability(t, snapshot, "notifications", StateDegraded, "menu bar status still works")
	assertOnlyAffected(t, snapshot, "notifications")
}

func TestMissingLaunchAgentOnlyDegradesAutomaticStart(t *testing.T) {
	observation := healthyObservation()
	observation.LaunchAgentPresent = false
	observation.LaunchAgentLoaded = false

	snapshot := Evaluate(observation, nil)

	assertCapability(t, snapshot, "automatic_start", StateDegraded, "not installed")
	assertOnlyAffected(t, snapshot, "automatic_start")
}

func TestIntegrationDriftNamesAffectedTool(t *testing.T) {
	observation := healthyObservation()
	observation.Integrations[1].Ready = false
	observation.Integrations[1].Status = "Mews notify integration not installed"

	snapshot := Evaluate(observation, nil)

	assertCapability(t, snapshot, "integration_codex", StateDegraded, "Codex events are affected")
	assertOnlyAffected(t, snapshot, "integration_codex")
}

func TestRecoveryRequiresTwoHealthyChecks(t *testing.T) {
	failed := healthyObservation()
	failed.Socket = SocketMissing
	blocked := Evaluate(failed, nil)

	first := Evaluate(healthyObservation(), &blocked)
	assertCapability(t, first, "event_delivery", StateChecking, "blocked to ready (1/2)")
	if first.State != StateChecking {
		t.Fatalf("first recovery state = %q, want checking", first.State)
	}

	second := Evaluate(healthyObservation(), &first)
	assertCapability(t, second, "event_delivery", StateReady, "accepts IPC events")
	if second.State != StateReady {
		t.Fatalf("second recovery state = %q, want ready", second.State)
	}
}

func TestFailureRequiresTwoMatchingChecks(t *testing.T) {
	ready := Evaluate(healthyObservation(), nil)
	failed := healthyObservation()
	failed.Socket = SocketMissing

	first := Evaluate(failed, &ready)
	capability := requireCapability(t, first, "event_delivery")
	if capability.State != StateChecking ||
		capability.TransitionFrom != StateReady ||
		capability.TransitionTarget != StateBlocked ||
		capability.TransitionCount != 1 {
		t.Fatalf("first failure transition = %#v", capability)
	}

	second := Evaluate(failed, &first)
	assertCapability(t, second, "event_delivery", StateBlocked, "local agent is stopped")
}

func TestSingleBadProbeIsCancelledByStableObservation(t *testing.T) {
	ready := Evaluate(healthyObservation(), nil)
	failed := healthyObservation()
	failed.Socket = SocketMissing
	checking := Evaluate(failed, &ready)

	cancelled := Evaluate(healthyObservation(), &checking)
	capability := requireCapability(t, cancelled, "event_delivery")
	if capability.State != StateReady ||
		capability.TransitionCount != 0 ||
		capability.TransitionTarget != "" {
		t.Fatalf("cancelled transition = %#v, want stable ready", capability)
	}
}

func TestRecoveryConfirmationResetsAfterFlap(t *testing.T) {
	failed := healthyObservation()
	failed.Socket = SocketMissing
	blocked := Evaluate(failed, nil)
	checking := Evaluate(healthyObservation(), &blocked)

	flapped := Evaluate(failed, &checking)
	assertCapability(t, flapped, "event_delivery", StateBlocked, "socket is missing")

	recoveringAgain := Evaluate(healthyObservation(), &flapped)
	capability := requireCapability(t, recoveringAgain, "event_delivery")
	if capability.TransitionCount != 1 ||
		capability.TransitionFrom != StateBlocked ||
		capability.TransitionTarget != StateReady {
		t.Fatalf("recovery transition = %#v, want blocked to ready count 1", capability)
	}
}

func TestTransitionTargetChangeRestartsConfirmation(t *testing.T) {
	previous := Snapshot{
		Capabilities: []Capability{
			{
				ID:               "probe",
				State:            StateChecking,
				TransitionFrom:   StateReady,
				TransitionTarget: StateBlocked,
				TransitionCount:  1,
			},
		},
	}
	capability := Capability{
		ID:      "probe",
		Name:    "Probe",
		Kind:    KindFunctional,
		State:   StateDegraded,
		Message: "degraded",
	}

	applyTransition(&capability, &previous, false)

	if capability.State != StateChecking ||
		capability.TransitionFrom != StateReady ||
		capability.TransitionTarget != StateDegraded ||
		capability.TransitionCount != 1 {
		t.Fatalf("changed target transition = %#v", capability)
	}
}

func TestExpiredPendingTransitionRestartsAtOne(t *testing.T) {
	failed := healthyObservation()
	failed.Socket = SocketMissing
	blocked := Evaluate(failed, nil)

	firstObservation := healthyObservation()
	firstObservation.CheckedAt = blocked.CheckedAt.Add(time.Second)
	first := Evaluate(firstObservation, &blocked)
	secondObservation := healthyObservation()
	secondObservation.CheckedAt = first.ValidUntil.Add(time.Second)
	restarted := Evaluate(secondObservation, &first)

	capability := requireCapability(t, restarted, "event_delivery")
	if capability.State != StateChecking ||
		capability.TransitionFrom != StateBlocked ||
		capability.TransitionTarget != StateReady ||
		capability.TransitionCount != 1 {
		t.Fatalf("expired transition = %#v, want restarted blocked-to-ready count 1", capability)
	}

	thirdObservation := healthyObservation()
	thirdObservation.CheckedAt = secondObservation.CheckedAt.Add(time.Second)
	confirmed := Evaluate(thirdObservation, &restarted)
	assertCapability(t, confirmed, "event_delivery", StateReady, "accepts IPC events")
}

func TestConfirmedDegradationOutranksPendingTransition(t *testing.T) {
	degradedObservation := healthyObservation()
	degradedObservation.Notifications = NotificationsDenied
	degraded := Evaluate(degradedObservation, nil)

	pendingObservation := degradedObservation
	pendingObservation.CheckedAt = degraded.CheckedAt.Add(time.Second)
	pendingObservation.Socket = SocketMissing
	pending := Evaluate(pendingObservation, &degraded)

	if pending.State != StateDegraded {
		t.Fatalf("state = %q, want confirmed degraded to outrank checking", pending.State)
	}
	assertCapability(t, pending, "event_delivery", StateChecking, "ready to blocked (1/2)")
}

func TestSnapshotRoundTripAndAffectedSummary(t *testing.T) {
	observation := healthyObservation()
	observation.Notifications = NotificationsDenied
	snapshot := Evaluate(observation, nil)
	path := filepath.Join(t.TempDir(), "runtime-health.json")

	if err := Save(path, snapshot); err != nil {
		t.Fatalf("Save returned error: %v", err)
	}
	loaded, err := Load(path, observation.CheckedAt)
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if loaded == nil || loaded.State != StateDegraded {
		t.Fatalf("loaded snapshot = %#v", loaded)
	}

	var output bytes.Buffer
	PrintSummary(&output, *loaded)
	text := output.String()
	if !strings.Contains(text, "Runtime health: Degraded") ||
		!strings.Contains(text, "Notifications (functional)") ||
		strings.Contains(text, "Setup (configuration)") {
		t.Fatalf("unexpected summary:\n%s", text)
	}
}

func healthyObservation() Observation {
	return Observation{
		CheckedAt:          time.Date(2026, 7, 21, 4, 0, 0, 0, time.UTC),
		StoreReady:         true,
		SetupConfigured:    true,
		RollbackReady:      true,
		AppBundleReady:     true,
		LaunchAgentPresent: true,
		LaunchAgentLoaded:  true,
		Socket:             SocketAvailable,
		Notifications:      NotificationsAuthorized,
		Integrations: []IntegrationObservation{
			{ID: "claude-code", Name: "Claude Code", Status: "configured", Ready: true},
			{ID: "codex", Name: "Codex", Status: "configured", Ready: true},
			{ID: "copilot-cli", Name: "Copilot CLI", Status: "configured", Ready: true},
		},
	}
}

func assertOnlyAffected(t *testing.T, snapshot Snapshot, id string) {
	t.Helper()
	affected := snapshot.AffectedCapabilities()
	if len(affected) != 1 || affected[0].ID != id {
		t.Fatalf("affected capabilities = %#v, want only %q", affected, id)
	}
}

func assertCapability(t *testing.T, snapshot Snapshot, id string, state State, message string) {
	t.Helper()
	capability := requireCapability(t, snapshot, id)
	if capability.State != state || !strings.Contains(capability.Message, message) {
		t.Fatalf("capability %q = %#v, want state %q containing %q", id, capability, state, message)
	}
}

func requireCapability(t *testing.T, snapshot Snapshot, id string) Capability {
	t.Helper()
	capability, found := findCapability(snapshot.Capabilities, id)
	if !found {
		t.Fatalf("capability %q missing from %#v", id, snapshot.Capabilities)
	}
	return capability
}
