package doctor

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/Duan-JM/mews/internal/health"
)

func TestCheckCreatesWritableStore(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	report, err := Check()
	if err != nil {
		t.Fatalf("Check returned error: %v", err)
	}

	want := map[string]string{
		"Store":         "writable",
		"Logs":          "writable",
		"Events":        "ready",
		"LaunchAgent":   "not installed",
		"Local agent":   "not running",
		"Socket":        "not running",
		"Notifications": "unknown; start Mews.app once",
	}
	for _, result := range report.Results {
		if status, ok := want[result.Name]; ok && result.Status != status {
			t.Fatalf("%s status = %q, want %q", result.Name, result.Status, status)
		}
	}
}

func TestCheckNotificationsReportsDenied(t *testing.T) {
	result := notificationResult(health.NotificationsDenied)
	if result.OK || result.Status != "denied in System Settings" {
		t.Fatalf("notification result = %#v", result)
	}
}

func TestObservationResultsUseSingleRawProbe(t *testing.T) {
	observation := health.Observation{
		AppBundleReady:     true,
		AppBundlePath:      "/Applications/Mews.app",
		LaunchAgentPresent: true,
		LaunchAgentLoaded:  true,
		LaunchAgentStatus:  "loaded",
		Socket:             health.SocketUnresponsive,
		Notifications:      health.NotificationsStale,
		Integrations: []health.IntegrationObservation{
			{Name: "Codex", Status: "hooks not installed", Ready: false},
		},
	}

	results := append(observationResults(observation), integrationResults(observation.Integrations)...)
	want := map[string]string{
		"Menu bar app":  "/Applications/Mews.app",
		"LaunchAgent":   "loaded",
		"Local agent":   "not running",
		"Socket":        "present but not responding",
		"Notifications": "stale; Mews.app is not refreshing it",
		"Codex":         "hooks not installed",
	}
	seen := make(map[string]bool, len(want))
	for _, result := range results {
		status, ok := want[result.Name]
		if !ok {
			continue
		}
		seen[result.Name] = true
		if result.Status != status {
			t.Fatalf("%s status = %q, want %q", result.Name, result.Status, status)
		}
	}
	if len(seen) != len(want) {
		t.Fatalf("observation results missing rows: got %#v, want %#v", seen, want)
	}
}

func TestCheckPathReportsUnwritableLocation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "read-only")
	if err := os.Mkdir(path, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o700) })

	result := checkPath("Store", path)
	if result.OK || result.Status != "not writable" {
		t.Fatalf("path result = %#v", result)
	}
}

func TestCheckPathDoesNotFollowProbeOrDirectorySymlinks(t *testing.T) {
	directory := t.TempDir()
	externalRoot := t.TempDir()
	externalTarget := filepath.Join(externalRoot, "external")
	if err := os.WriteFile(externalTarget, []byte("sentinel"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(externalTarget, filepath.Join(directory, ".mews-write-test")); err != nil {
		t.Fatal(err)
	}

	result := checkPath("Store", directory)
	if !result.OK || result.Status != "writable" {
		t.Fatalf("checkPath result = %#v", result)
	}
	content, err := os.ReadFile(externalTarget)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "sentinel" {
		t.Fatalf("external probe target = %q, want untouched sentinel", content)
	}

	directoryLink := filepath.Join(t.TempDir(), "store-link")
	if err := os.Symlink(externalRoot, directoryLink); err != nil {
		t.Fatal(err)
	}
	result = checkPath("Store", directoryLink)
	if result.OK || result.Status != "symlink not allowed" {
		t.Fatalf("symlinked directory result = %#v", result)
	}
}

func TestCheckFileDoesNotFollowExternalSymlinks(t *testing.T) {
	root := t.TempDir()
	externalRoot := t.TempDir()
	existingTarget := filepath.Join(externalRoot, "events.jsonl")
	if err := os.WriteFile(existingTarget, []byte("sentinel"), 0o600); err != nil {
		t.Fatal(err)
	}
	existingLink := filepath.Join(root, "events-existing.jsonl")
	if err := os.Symlink(existingTarget, existingLink); err != nil {
		t.Fatal(err)
	}

	result := checkFile("Events", existingLink)
	if result.OK || result.Status != "symlink not allowed" {
		t.Fatalf("existing symlink result = %#v", result)
	}
	content, err := os.ReadFile(existingTarget)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "sentinel" {
		t.Fatalf("external events target = %q, want untouched sentinel", content)
	}

	danglingTarget := filepath.Join(externalRoot, "must-not-exist.jsonl")
	danglingLink := filepath.Join(root, "events-dangling.jsonl")
	if err := os.Symlink(danglingTarget, danglingLink); err != nil {
		t.Fatal(err)
	}
	result = checkFile("Events", danglingLink)
	if result.OK || result.Status != "symlink not allowed" {
		t.Fatalf("dangling symlink result = %#v", result)
	}
	if _, err := os.Stat(danglingTarget); !os.IsNotExist(err) {
		t.Fatalf("dangling external target was created or touched: %v", err)
	}
}

func TestReportHasFailuresIncludesDetailedChecks(t *testing.T) {
	report := Report{
		Health: health.Snapshot{State: health.StateReady},
		Results: []CheckResult{
			{Name: "Logs", Status: "not writable", OK: false},
		},
	}

	if !report.HasFailures() {
		t.Fatal("HasFailures returned false for a failed detailed check")
	}
}
