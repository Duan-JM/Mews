package store

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestPathsUsesShortSocketFallbackForLongHome(t *testing.T) {
	home := filepath.Join(t.TempDir(), strings.Repeat("long-home-", 12))
	t.Setenv("HOME", home)

	paths, err := Ensure()
	if err != nil {
		t.Fatalf("Ensure returned error: %v", err)
	}
	if len(paths.Socket) >= 100 {
		t.Fatalf("socket path is too long: %s", paths.Socket)
	}
	if paths.SocketDir == paths.AppSupport {
		t.Fatalf("long home did not use socket fallback: %s", paths.Socket)
	}
	info, err := os.Stat(paths.SocketDir)
	if err != nil {
		t.Fatalf("socket directory missing: %v", err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("socket directory mode = %o, want 700", info.Mode().Perm())
	}
	t.Cleanup(func() { _ = os.RemoveAll(paths.SocketDir) })
}

func TestSocketNamespacesUseDistinctFallbacks(t *testing.T) {
	home := filepath.Join(t.TempDir(), strings.Repeat("long-home-", 12))
	t.Setenv("HOME", home)
	t.Setenv("MEWS_SOCKET_NAMESPACE", "first")
	first, err := Paths()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("MEWS_SOCKET_NAMESPACE", "second")
	second, err := Paths()
	if err != nil {
		t.Fatal(err)
	}

	if first.SocketDir == second.SocketDir {
		t.Fatalf("distinct namespaces shared socket directory %s", first.SocketDir)
	}
}

func TestCopilotHookStateUsesOpaqueMarkersAndClearsPerSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	sessionID := "session/with/private-details"
	transcriptPath := "/private/path/to/subagent-transcript.jsonl"
	if err := StartCopilotSubagent(sessionID, transcriptPath); err != nil {
		t.Fatalf("StartCopilotSubagent returned error: %v", err)
	}
	if deferred, err := ProcessCopilotMainStop(
		sessionID,
		func() error { return nil },
		func(string, time.Time) error { return nil },
	); err != nil || !deferred {
		t.Fatalf("ProcessCopilotMainStop = %v, %v; want true, nil", deferred, err)
	}

	paths, err := Paths()
	if err != nil {
		t.Fatal(err)
	}
	err = filepath.Walk(paths.CopilotHooks, func(path string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if strings.Contains(path, sessionID) || strings.Contains(path, transcriptPath) {
			t.Fatalf("Copilot hook state exposed raw identifiers: %s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	if err := ClearCopilotHookSession(sessionID); err != nil {
		t.Fatalf("ClearCopilotHookSession returned error: %v", err)
	}
	if deferred, err := ProcessCopilotMainStop(
		sessionID,
		func() error { return nil },
		func(string, time.Time) error { return nil },
	); err != nil || deferred {
		t.Fatalf("ProcessCopilotMainStop after clear = %v, %v; want false, nil", deferred, err)
	}
}

func TestCopilotHookStateCompletesAfterFinalSubagent(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	for _, transcriptPath := range []string{"/tmp/first.jsonl", "/tmp/second.jsonl"} {
		if err := StartCopilotSubagent(sessionID, transcriptPath); err != nil {
			t.Fatal(err)
		}
	}
	if deferred, err := ProcessCopilotMainStop(
		sessionID,
		func() error { return nil },
		func(string, time.Time) error { return nil },
	); err != nil || !deferred {
		t.Fatalf("ProcessCopilotMainStop = %v, %v; want true, nil", deferred, err)
	}
	if complete, err := ProcessCopilotSubagentStop(
		sessionID,
		"/tmp/first.jsonl",
		func(string, time.Time) error { return nil },
	); err != nil || complete {
		t.Fatalf("first ProcessCopilotSubagentStop = %v, %v; want false, nil", complete, err)
	}
	if complete, err := ProcessCopilotSubagentStop(
		sessionID,
		"/tmp/second.jsonl",
		func(string, time.Time) error { return nil },
	); err != nil || !complete {
		t.Fatalf("final ProcessCopilotSubagentStop = %v, %v; want true, nil", complete, err)
	}
	if complete, err := ProcessCopilotSubagentStop(
		sessionID,
		"/tmp/second.jsonl",
		func(string, time.Time) error { return nil },
	); err != nil || complete {
		t.Fatalf("duplicate ProcessCopilotSubagentStop = %v, %v; want false, nil", complete, err)
	}
}

func TestCopilotHookStateSerializesConcurrentStops(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	transcripts := []string{"/tmp/first.jsonl", "/tmp/second.jsonl", "/tmp/third.jsonl"}
	for _, transcriptPath := range transcripts {
		if err := StartCopilotSubagent(sessionID, transcriptPath); err != nil {
			t.Fatal(err)
		}
	}
	if deferred, err := ProcessCopilotMainStop(
		sessionID,
		func() error { return nil },
		func(string, time.Time) error { return nil },
	); err != nil || !deferred {
		t.Fatalf("ProcessCopilotMainStop = %v, %v; want true, nil", deferred, err)
	}

	var wg sync.WaitGroup
	results := make(chan bool, len(transcripts))
	errors := make(chan error, len(transcripts))
	for _, transcriptPath := range transcripts {
		wg.Add(1)
		go func(path string) {
			defer wg.Done()
			complete, err := ProcessCopilotSubagentStop(
				sessionID,
				path,
				func(string, time.Time) error { return nil },
			)
			results <- complete
			errors <- err
		}(transcriptPath)
	}
	wg.Wait()
	close(results)
	close(errors)

	completions := 0
	for complete := range results {
		if complete {
			completions++
		}
	}
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	if completions != 1 {
		t.Fatalf("completion count = %d, want 1", completions)
	}
}

func TestCopilotHookStateRetriesStablePendingStop(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	if err := StartCopilotSubagent(sessionID, "/tmp/subagent.jsonl"); err != nil {
		t.Fatal(err)
	}
	if deferred, err := ProcessCopilotMainStop(
		sessionID,
		func() error { return nil },
		func(string, time.Time) error { return nil },
	); err != nil || !deferred {
		t.Fatalf("ProcessCopilotMainStop = %v, %v; want true, nil", deferred, err)
	}
	var firstID string
	var firstCompletionAt time.Time
	if complete, err := ProcessCopilotSubagentStop(
		sessionID,
		"/tmp/subagent.jsonl",
		func(id string, completionAt time.Time) error {
			firstID = id
			firstCompletionAt = completionAt
			return errors.New("delivery failed")
		},
	); err == nil || complete {
		t.Fatalf("failed ProcessCopilotSubagentStop = %v, %v; want false, error", complete, err)
	}
	var retryID string
	var retryCompletionAt time.Time
	if complete, err := ProcessCopilotSubagentStop(
		sessionID,
		"/tmp/subagent.jsonl",
		func(id string, completionAt time.Time) error {
			retryID = id
			retryCompletionAt = completionAt
			return nil
		},
	); err != nil || !complete {
		t.Fatalf("retried ProcessCopilotSubagentStop = %v, %v; want true, nil", complete, err)
	}
	if firstID == "" || retryID != firstID || !retryCompletionAt.Equal(firstCompletionAt) {
		t.Fatalf(
			"completion state = %q/%s, %q/%s; want one stable ID and timestamp",
			firstID,
			firstCompletionAt,
			retryID,
			retryCompletionAt,
		)
	}
}

func TestCopilotHookDeliveryHoldsSessionLock(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	if err := StartCopilotSubagent(sessionID, "/tmp/subagent.jsonl"); err != nil {
		t.Fatal(err)
	}
	checkLock := func() error {
		paths, err := Paths()
		if err != nil {
			return err
		}
		sessionKey, err := copilotHookKey("session_id", sessionID)
		if err != nil {
			return err
		}
		lock, err := os.OpenFile(
			filepath.Join(paths.CopilotHooks, sessionKey+".lock"),
			os.O_CREATE|os.O_RDWR,
			0o600,
		)
		if err != nil {
			return err
		}
		defer lock.Close()
		err = syscall.Flock(
			int(lock.Fd()),
			syscall.LOCK_EX|syscall.LOCK_NB,
		)
		if !errors.Is(err, syscall.EWOULDBLOCK) &&
			!errors.Is(err, syscall.EAGAIN) {
			return errors.New("Copilot delivery did not retain the session lock")
		}
		return nil
	}
	deferred, err := ProcessCopilotMainStop(
		sessionID,
		checkLock,
		func(string, time.Time) error { return checkLock() },
	)
	if err != nil || !deferred {
		t.Fatalf("ProcessCopilotMainStop = %v, %v; want true, nil", deferred, err)
	}
}

func TestCopilotImmediateCompletionHoldsSessionLock(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	delivered := false
	deferred, err := ProcessCopilotMainStop(
		sessionID,
		func() error {
			return errors.New("unexpected deferred delivery")
		},
		func(string, time.Time) error {
			delivered = true
			paths, err := Paths()
			if err != nil {
				return err
			}
			sessionKey, err := copilotHookKey("session_id", sessionID)
			if err != nil {
				return err
			}
			lock, err := os.OpenFile(
				filepath.Join(paths.CopilotHooks, sessionKey+".lock"),
				os.O_CREATE|os.O_RDWR,
				0o600,
			)
			if err != nil {
				return err
			}
			defer lock.Close()
			err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
			if !errors.Is(err, syscall.EWOULDBLOCK) &&
				!errors.Is(err, syscall.EAGAIN) {
				return errors.New("immediate completion did not retain the session lock")
			}
			return nil
		},
	)
	if err != nil || deferred || !delivered {
		t.Fatalf(
			"ProcessCopilotMainStop = %v, %v, delivered=%v; want false, nil, true",
			deferred,
			err,
			delivered,
		)
	}
}

func TestCopilotHookStatePrunesExpiredSubagents(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	if err := StartCopilotSubagent(sessionID, "/tmp/subagent.jsonl"); err != nil {
		t.Fatal(err)
	}
	paths, err := Paths()
	if err != nil {
		t.Fatal(err)
	}
	var activeMarker string
	err = filepath.Walk(paths.CopilotHooks, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasPrefix(info.Name(), "active-") {
			activeMarker = path
		}
		return nil
	})
	if err != nil || activeMarker == "" {
		t.Fatalf("active marker = %q, walk error = %v", activeMarker, err)
	}
	expired := time.Now().Add(-copilotSubagentLifetime - time.Minute)
	if err := os.Chtimes(activeMarker, expired, expired); err != nil {
		t.Fatal(err)
	}
	delivered := false
	deferred, err := ProcessCopilotMainStop(
		sessionID,
		func() error {
			t.Fatal("expired subagent deferred completion")
			return nil
		},
		func(string, time.Time) error {
			delivered = true
			return nil
		},
	)
	if err != nil || deferred || !delivered {
		t.Fatalf(
			"ProcessCopilotMainStop = %v, %v, delivered=%v; want false, nil, true",
			deferred,
			err,
			delivered,
		)
	}
}

func TestCopilotHookStateRefusesSymlinkDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	paths, err := Paths()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(paths.AppSupport, 0o700); err != nil {
		t.Fatal(err)
	}
	target := t.TempDir()
	if err := os.Symlink(target, paths.CopilotHooks); err != nil {
		t.Fatal(err)
	}

	err = StartCopilotSubagent("session-123", "/tmp/subagent.jsonl")
	if err == nil || !strings.Contains(err.Error(), "symbolic link") {
		t.Fatalf("StartCopilotSubagent error = %v, want symbolic-link refusal", err)
	}
	entries, err := os.ReadDir(target)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("Copilot hook state wrote through symlink: %#v", entries)
	}
}

func TestCopilotHookStateStaysDisabledAfterRemoval(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	if err := StartCopilotSubagent("session-123", "/tmp/subagent.jsonl"); err != nil {
		t.Fatal(err)
	}
	if err := RemoveCopilotHookState(); err != nil {
		t.Fatal(err)
	}
	err := StartCopilotSubagent("session-123", "/tmp/subagent.jsonl")
	if err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("StartCopilotSubagent after removal = %v, want disabled error", err)
	}
	if err := EnableCopilotHookState(); err != nil {
		t.Fatal(err)
	}
	if err := StartCopilotSubagent("session-123", "/tmp/subagent.jsonl"); err != nil {
		t.Fatalf("StartCopilotSubagent after enable returned error: %v", err)
	}
}
