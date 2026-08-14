package health

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Duan-JM/mews/internal/store"
)

func TestReadNotificationStatusClassifiesFreshFractionalRecord(t *testing.T) {
	now := time.Date(2026, 7, 21, 4, 0, 30, 0, time.UTC)
	path := writeNotificationFixture(
		t,
		`{"status":"denied","checked_at":"2026-07-21T04:00:00.123456789Z"}`,
	)

	if status := ReadNotificationStatus(path, now); status != NotificationsDenied {
		t.Fatalf("status = %q, want denied", status)
	}
}

func TestReadNotificationStatusClassifiesFileFailures(t *testing.T) {
	now := time.Date(2026, 7, 21, 4, 0, 0, 0, time.UTC)
	missing := filepath.Join(t.TempDir(), "missing.json")
	if status := ReadNotificationStatus(missing, now); status != NotificationsMissing {
		t.Fatalf("missing status = %q", status)
	}

	directory := t.TempDir()
	if status := ReadNotificationStatus(directory, now); status != NotificationsUnreadable {
		t.Fatalf("unreadable status = %q", status)
	}

	invalid := writeNotificationFixture(t, `{"status":"authorized"}`)
	if status := ReadNotificationStatus(invalid, now); status != NotificationsInvalid {
		t.Fatalf("invalid status = %q", status)
	}
}

func TestReadNotificationStatusClassifiesStaleAndFutureRecords(t *testing.T) {
	now := time.Date(2026, 7, 21, 4, 2, 0, 0, time.UTC)
	stale := writeNotificationFixture(
		t,
		`{"status":"authorized","checked_at":"2026-07-21T04:00:29Z"}`,
	)
	if status := ReadNotificationStatus(stale, now); status != NotificationsStale {
		t.Fatalf("stale status = %q", status)
	}

	future := writeNotificationFixture(
		t,
		`{"status":"authorized","checked_at":"2026-07-21T04:08:00Z"}`,
	)
	if status := ReadNotificationStatus(future, now); status != NotificationsInvalid {
		t.Fatalf("future status = %q", status)
	}
}

func TestStoreFilesWritableChecksProductionFiles(t *testing.T) {
	root := t.TempDir()
	logs := filepath.Join(root, "logs")
	if err := os.Mkdir(logs, 0o700); err != nil {
		t.Fatal(err)
	}
	paths := store.StorePaths{
		Events: filepath.Join(root, "events.jsonl"),
		Logs:   logs,
	}
	if !storeFilesWritable(paths) {
		t.Fatal("storeFilesWritable returned false for writable paths")
	}

	invalidEvents := filepath.Join(root, "events-directory")
	if err := os.Mkdir(invalidEvents, 0o700); err != nil {
		t.Fatal(err)
	}
	paths.Events = invalidEvents
	if storeFilesWritable(paths) {
		t.Fatal("storeFilesWritable returned true when events path is a directory")
	}
}

func TestFileWritableRejectsSymlinksWithoutTouchingTargets(t *testing.T) {
	root := t.TempDir()
	externalRoot := t.TempDir()
	existingTarget := filepath.Join(externalRoot, "existing.log")
	if err := os.WriteFile(existingTarget, []byte("sentinel"), 0o600); err != nil {
		t.Fatal(err)
	}
	existingLink := filepath.Join(root, "existing-link")
	if err := os.Symlink(existingTarget, existingLink); err != nil {
		t.Fatal(err)
	}

	if fileWritable(existingLink) {
		t.Fatal("fileWritable accepted a symlink to an existing external file")
	}
	content, err := os.ReadFile(existingTarget)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "sentinel" {
		t.Fatalf("external target content = %q, want untouched sentinel", content)
	}

	danglingTarget := filepath.Join(externalRoot, "must-not-exist.log")
	danglingLink := filepath.Join(root, "dangling-link")
	if err := os.Symlink(danglingTarget, danglingLink); err != nil {
		t.Fatal(err)
	}
	if fileWritable(danglingLink) {
		t.Fatal("fileWritable accepted a dangling symlink")
	}
	if _, err := os.Stat(danglingTarget); !os.IsNotExist(err) {
		t.Fatalf("dangling external target was created or touched: %v", err)
	}
}

func writeNotificationFixture(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "notification-status.json")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
