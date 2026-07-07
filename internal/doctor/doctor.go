package doctor

import (
	"fmt"
	"io"
	"os"

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

	results := []CheckResult{
		checkPath("Store", paths.AppSupport),
		checkPath("Logs", paths.Logs),
		{Name: "Agent", Status: "not installed", OK: false},
		{Name: "Socket", Status: "not running", OK: false},
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

