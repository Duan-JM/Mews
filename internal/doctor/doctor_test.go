package doctor

import (
	"os"
	"path/filepath"
	"testing"
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
	path := filepath.Join(t.TempDir(), "notification-status.json")
	if err := os.WriteFile(path, []byte(`{"status":"denied"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	result := checkNotifications(path)
	if result.OK || result.Status != "denied in System Settings" {
		t.Fatalf("notification result = %#v", result)
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
