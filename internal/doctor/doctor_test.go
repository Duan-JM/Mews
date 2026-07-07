package doctor

import "testing"

func TestCheckCreatesWritableStore(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	report, err := Check()
	if err != nil {
		t.Fatalf("Check returned error: %v", err)
	}

	want := map[string]string{
		"Store":  "writable",
		"Logs":   "writable",
		"Events": "ready",
		"Agent":  "not installed",
		"Socket": "not running",
	}
	for _, result := range report.Results {
		if status, ok := want[result.Name]; ok && result.Status != status {
			t.Fatalf("%s status = %q, want %q", result.Name, result.Status, status)
		}
	}
}
