package doctor

import (
	"fmt"
	"io"
	"os"

	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/store"
)

type CheckResult struct {
	Name   string
	Status string
	OK     bool
}

type Report struct {
	Results []CheckResult
}

func Check() (Report, error) {
	paths, err := store.Ensure()
	if err != nil {
		return Report{}, err
	}
	state, configured, err := store.LoadSetupState()
	if err != nil {
		return Report{}, err
	}

	setupStatus := "not set up; run `mw setup`"
	undoStatus := "nothing to undo"
	copilotStatus, copilotOK := integrations.CopilotHookStatus()
	claudeStatus := "not installed by Mews"
	if configured {
		setupStatus = "configured"
		if state.UndoReady {
			undoStatus = "ready"
		}
		claudeStatus = state.Claude
	}

	results := []CheckResult{
		checkPath("Store", paths.AppSupport),
		checkPath("Logs", paths.Logs),
		{Name: "Setup", Status: setupStatus, OK: configured},
		{Name: "Menu bar agent", Status: "not packaged yet", OK: false},
		{Name: "Socket", Status: "disabled until agent ships", OK: false},
		{Name: "Copilot CLI", Status: copilotStatus, OK: copilotOK},
		{Name: "Claude Code", Status: claudeStatus, OK: claudeStatus == "enabled"},
		{Name: "Undo", Status: undoStatus, OK: configured},
	}

	return Report{Results: results}, nil
}

func (r Report) HasFailures() bool {
	for _, result := range r.Results {
		if !result.OK {
			return true
		}
	}
	return false
}

func (r Report) Print(w io.Writer) {
	fmt.Fprintln(w, "Mews Doctor")
	fmt.Fprintln(w)
	for _, result := range r.Results {
		fmt.Fprintf(w, "%-16s %s\n", result.Name, result.Status)
	}
}

func checkPath(name, path string) CheckResult {
	if info, err := os.Stat(path); err == nil && info.IsDir() {
		return CheckResult{Name: name, Status: "writable", OK: true}
	}
	return CheckResult{Name: name, Status: "missing", OK: false}
}
