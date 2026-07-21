package health

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Duan-JM/mews/internal/store"
)

func TestSwiftFixtureMatchesGoSnapshotJSON(t *testing.T) {
	checkedAt := time.Date(2026, 7, 21, 4, 0, 0, 123456789, time.UTC)
	snapshot := Snapshot{
		Version:    SnapshotVersion,
		State:      StateChecking,
		Summary:    "Mews is confirming runtime health changes.",
		CheckedAt:  checkedAt,
		ValidUntil: checkedAt.Add(SnapshotLifetime),
		Capabilities: []Capability{
			{
				ID:               "notifications",
				Name:             "Notifications",
				Kind:             KindFunctional,
				State:            StateChecking,
				Message:          "Confirming notifications change from ready to degraded (1/2).",
				Recovery:         "Allow Mews notifications in System Settings.",
				TransitionFrom:   StateReady,
				TransitionTarget: StateDegraded,
				TransitionCount:  1,
			},
		},
	}

	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		t.Fatalf("MarshalIndent returned error: %v", err)
	}
	data = append(data, '\n')
	fixture, err := os.ReadFile("testdata/runtime-health-go.json")
	if err != nil {
		t.Fatalf("ReadFile returned error: %v", err)
	}
	if string(data) != string(fixture) {
		t.Fatalf("Swift fixture does not match Go JSON\nwant:\n%s\ngot:\n%s", data, fixture)
	}
}

func TestRefreshPreservesInvalidSnapshot(t *testing.T) {
	tests := []struct {
		name    string
		content string
		wantErr string
	}{
		{name: "unsupported", content: `{"version":99}`, wantErr: "unsupported runtime health snapshot version"},
		{name: "corrupt", content: `{`, wantErr: "unexpected end of JSON input"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			paths, err := store.Ensure()
			if err != nil {
				t.Fatal(err)
			}
			original := []byte(test.content)
			if err := os.WriteFile(paths.RuntimeHealth, original, 0o600); err != nil {
				t.Fatal(err)
			}

			if _, _, err := Refresh(time.Now()); err == nil ||
				!strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("Refresh error = %v, want containing %q", err, test.wantErr)
			}
			after, err := os.ReadFile(paths.RuntimeHealth)
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(original) {
				t.Fatalf("snapshot was overwritten: got %q, want %q", after, original)
			}
			matches, err := filepath.Glob(filepath.Join(paths.AppSupport, ".runtime-health-*"))
			if err != nil {
				t.Fatal(err)
			}
			if len(matches) != 0 {
				t.Fatalf("Refresh left temporary snapshots: %v", matches)
			}
		})
	}
}

func TestRefreshPreservesSnapshotsWithInvalidContracts(t *testing.T) {
	now := healthyObservation().CheckedAt
	tests := []struct {
		name    string
		mutate  func(*Snapshot)
		wantErr string
	}{
		{
			name: "overlong validity",
			mutate: func(snapshot *Snapshot) {
				snapshot.ValidUntil = snapshot.CheckedAt.Add(365 * 24 * time.Hour)
			},
			wantErr: "validity: window exceeds",
		},
		{
			name: "future checked at",
			mutate: func(snapshot *Snapshot) {
				snapshot.CheckedAt = now.Add(SnapshotFutureTolerance + time.Second)
				snapshot.ValidUntil = snapshot.CheckedAt.Add(SnapshotLifetime)
			},
			wantErr: "checked_at: materially in the future",
		},
		{
			name: "unknown top level state",
			mutate: func(snapshot *Snapshot) {
				snapshot.State = State("unknown")
			},
			wantErr: `state "unknown"`,
		},
		{
			name: "unknown capability state",
			mutate: func(snapshot *Snapshot) {
				snapshot.Capabilities[0].State = State("unknown")
			},
			wantErr: `state "unknown"`,
		},
		{
			name: "unknown capability kind",
			mutate: func(snapshot *Snapshot) {
				snapshot.Capabilities[0].Kind = Kind("unknown")
			},
			wantErr: `kind "unknown"`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			snapshot := Evaluate(healthyObservation(), nil)
			test.mutate(&snapshot)
			original, err := json.MarshalIndent(snapshot, "", "  ")
			if err != nil {
				t.Fatal(err)
			}
			original = append(original, '\n')
			paths, err := store.Ensure()
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(paths.RuntimeHealth, original, 0o600); err != nil {
				t.Fatal(err)
			}

			if _, _, err := Refresh(now); err == nil ||
				!strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("Refresh error = %v, want containing %q", err, test.wantErr)
			}
			after, err := os.ReadFile(paths.RuntimeHealth)
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(original) {
				t.Fatalf("invalid snapshot was overwritten:\ngot:\n%s\nwant:\n%s", after, original)
			}
		})
	}
}
