package health

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func Load(path string, now time.Time) (*Snapshot, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var snapshot Snapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return nil, err
	}
	if snapshot.Version != SnapshotVersion {
		return nil, fmt.Errorf("unsupported runtime health snapshot version %d", snapshot.Version)
	}
	if err := validateSnapshot(snapshot, now); err != nil {
		return nil, err
	}
	return &snapshot, nil
}

func validateSnapshot(snapshot Snapshot, now time.Time) error {
	if !knownState(snapshot.State) {
		return fmt.Errorf("invalid runtime health state %q", snapshot.State)
	}
	if snapshot.CheckedAt.IsZero() {
		return fmt.Errorf("invalid runtime health checked_at: missing")
	}
	if snapshot.CheckedAt.After(now.Add(SnapshotFutureTolerance)) {
		return fmt.Errorf("invalid runtime health checked_at: materially in the future")
	}
	if snapshot.ValidUntil.Before(snapshot.CheckedAt) {
		return fmt.Errorf("invalid runtime health validity: valid_until precedes checked_at")
	}
	if snapshot.ValidUntil.Sub(snapshot.CheckedAt) > SnapshotLifetime {
		return fmt.Errorf("invalid runtime health validity: window exceeds %s", SnapshotLifetime)
	}
	for index := range snapshot.Capabilities {
		if err := validateCapability(snapshot.Capabilities[index]); err != nil {
			return err
		}
	}
	if overallState(snapshot.Capabilities) != snapshot.State {
		return fmt.Errorf("invalid runtime health state: aggregate does not match capabilities")
	}
	return nil
}

func validateCapability(capability Capability) error {
	if !knownState(capability.State) {
		return fmt.Errorf("invalid runtime health capability %q state %q", capability.ID, capability.State)
	}
	if !knownKind(capability.Kind) {
		return fmt.Errorf("invalid runtime health capability %q kind %q", capability.ID, capability.Kind)
	}
	if capability.TransitionFrom != "" && !knownState(capability.TransitionFrom) {
		return fmt.Errorf(
			"invalid runtime health capability %q transition_from %q",
			capability.ID,
			capability.TransitionFrom,
		)
	}
	if capability.TransitionTarget != "" && !knownState(capability.TransitionTarget) {
		return fmt.Errorf(
			"invalid runtime health capability %q transition_target %q",
			capability.ID,
			capability.TransitionTarget,
		)
	}
	if capability.State == StateChecking {
		if capability.TransitionFrom == "" ||
			capability.TransitionTarget == "" ||
			capability.TransitionCount < 1 ||
			capability.TransitionCount >= TransitionConfirmations {
			return fmt.Errorf("invalid runtime health capability %q transition", capability.ID)
		}
	} else if capability.TransitionFrom != "" ||
		capability.TransitionTarget != "" ||
		capability.TransitionCount != 0 {
		return fmt.Errorf("invalid runtime health capability %q stable transition metadata", capability.ID)
	}
	return nil
}

func knownState(state State) bool {
	switch state {
	case StateChecking, StateReady, StateDegraded, StateBlocked:
		return true
	default:
		return false
	}
}

func knownKind(kind Kind) bool {
	return kind == KindConfiguration || kind == KindFunctional
}

func Save(path string, snapshot Snapshot) error {
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".runtime-health-*")
	if err != nil {
		return err
	}
	tempPath := file.Name()
	defer os.Remove(tempPath)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}

func PrintSummary(w io.Writer, snapshot Snapshot) {
	fmt.Fprintf(w, "Runtime health: %s — %s\n", title(snapshot.State), snapshot.Summary)
	affected := snapshot.AffectedCapabilities()
	for index := range affected {
		capability := &affected[index]
		fmt.Fprintf(
			w,
			"  %s (%s): %s — %s\n",
			capability.Name,
			capability.Kind,
			title(capability.State),
			capability.Message,
		)
		if capability.Recovery != "" {
			fmt.Fprintf(w, "    Recovery: %s\n", capability.Recovery)
		}
	}
}

func title(state State) string {
	value := string(state)
	if value == "" {
		return value
	}
	return strings.ToUpper(value[:1]) + value[1:]
}
