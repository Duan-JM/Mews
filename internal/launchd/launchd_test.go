package launchd

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRenderPlist(t *testing.T) {
	data, err := Render(Job{
		Label:      Label,
		Program:    "/Applications/Mews.app/Contents/MacOS/Mews",
		HomePath:   "/Users/tester",
		StdoutPath: "/tmp/mews-app.log",
		StderrPath: "/tmp/mews-app.log",
	})
	if err != nil {
		t.Fatalf("Render returned error: %v", err)
	}
	content := string(data)
	for _, want := range []string{
		"<string>dev.mews.agent</string>",
		"<string>/Applications/Mews.app/Contents/MacOS/Mews</string>",
		"<key>RunAtLoad</key>",
		"<key>HOME</key>",
		"<string>/Users/tester</string>",
		"<string>/tmp/mews-app.log</string>",
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("plist missing %q: %s", want, content)
		}
	}
}

func TestRenderPlistEscapesPaths(t *testing.T) {
	data, err := Render(Job{
		Label:      Label,
		Program:    "/tmp/Mews & Friends.app/Contents/MacOS/Mews",
		HomePath:   "/tmp/Mews & Friends",
		StdoutPath: "/tmp/mews&app.log",
		StderrPath: "/tmp/mews&app.log",
	})
	if err != nil {
		t.Fatalf("Render returned error: %v", err)
	}
	content := string(data)
	for _, want := range []string{
		"/tmp/Mews &amp; Friends.app/Contents/MacOS/Mews",
		"/tmp/Mews &amp; Friends",
		"/tmp/mews&amp;app.log",
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("plist missing escaped %q: %s", want, content)
		}
	}
}

func TestRenderPlistIncludesSocketNamespace(t *testing.T) {
	data, err := Render(Job{
		Label:           Label,
		Program:         "/Applications/Mews.app/Contents/MacOS/Mews",
		HomePath:        "/Users/tester",
		SocketNamespace: "package-smoke",
		StdoutPath:      "/tmp/mews-app.log",
		StderrPath:      "/tmp/mews-app.log",
	})
	if err != nil {
		t.Fatalf("Render returned error: %v", err)
	}
	content := string(data)
	for _, want := range []string{
		"<key>MEWS_SOCKET_NAMESPACE</key>",
		"<string>package-smoke</string>",
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("plist missing %q: %s", want, content)
		}
	}
}

func TestBootoutSkipsUnloadedLaunchAgent(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, "Library", "LaunchAgents", Label+".plist")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("plist"), 0o600); err != nil {
		t.Fatal(err)
	}

	original := runLaunchctl
	t.Cleanup(func() { runLaunchctl = original })
	var calls [][]string
	runLaunchctl = func(args ...string) ([]byte, error) {
		calls = append(calls, append([]string(nil), args...))
		return []byte("Could not find service"), errors.New("exit status 1")
	}

	if err := Bootout(); err != nil {
		t.Fatalf("Bootout returned error: %v", err)
	}
	want := [][]string{{"print", guiDomain() + "/" + Label}}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("launchctl calls = %#v, want %#v", calls, want)
	}
}

func TestBootoutPropagatesUnknownLaunchctlFailure(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, "Library", "LaunchAgents", Label+".plist")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("plist"), 0o600); err != nil {
		t.Fatal(err)
	}

	original := runLaunchctl
	t.Cleanup(func() { runLaunchctl = original })
	runLaunchctl = func(args ...string) ([]byte, error) {
		return []byte("operation not permitted"), errors.New("exit status 1")
	}

	err := Bootout()
	if err == nil || !strings.Contains(err.Error(), "operation not permitted") {
		t.Fatalf("Bootout error = %v", err)
	}
}

func TestBootoutUsesLoadedServiceLabel(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, "Library", "LaunchAgents", Label+".plist")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("plist"), 0o600); err != nil {
		t.Fatal(err)
	}

	original := runLaunchctl
	t.Cleanup(func() { runLaunchctl = original })
	var calls [][]string
	runLaunchctl = func(args ...string) ([]byte, error) {
		calls = append(calls, append([]string(nil), args...))
		return nil, nil
	}

	if err := Bootout(); err != nil {
		t.Fatalf("Bootout returned error: %v", err)
	}
	want := [][]string{
		{"print", guiDomain() + "/" + Label},
		{"bootout", guiDomain() + "/" + Label},
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("launchctl calls = %#v, want %#v", calls, want)
	}
}

func TestKickstartRestartsLoadedService(t *testing.T) {
	original := runLaunchctl
	t.Cleanup(func() { runLaunchctl = original })
	var calls [][]string
	runLaunchctl = func(args ...string) ([]byte, error) {
		calls = append(calls, append([]string(nil), args...))
		return nil, nil
	}

	if err := Kickstart(); err != nil {
		t.Fatalf("Kickstart returned error: %v", err)
	}
	want := [][]string{{"kickstart", "-k", guiDomain() + "/" + Label}}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("launchctl calls = %#v, want %#v", calls, want)
	}
}

func TestCurrentJobReadsLaunchctlConfiguration(t *testing.T) {
	original := runLaunchctl
	t.Cleanup(func() { runLaunchctl = original })
	runLaunchctl = func(args ...string) ([]byte, error) {
		return []byte(
			"gui/501/dev.mews.agent = {\n" +
				"\tprogram = /Applications/Mews.app/Contents/MacOS/Mews\n" +
				"\tstdout path = /Users/tester/Library/Logs/Mews/app.log\n" +
				"\tstderr path = /Users/tester/Library/Logs/Mews/app.log\n" +
				"\tenvironment = {\n" +
				"\t\tHOME => /Users/tester\n" +
				"\t\tMEWS_SOCKET_NAMESPACE => package-smoke\n" +
				"\t}\n" +
				"}\n",
		), nil
	}

	job, loaded, err := CurrentJob()
	if err != nil {
		t.Fatalf("CurrentJob returned error: %v", err)
	}
	if !loaded ||
		job.Program != "/Applications/Mews.app/Contents/MacOS/Mews" ||
		job.HomePath != "/Users/tester" ||
		job.SocketNamespace != "package-smoke" ||
		job.StdoutPath != "/Users/tester/Library/Logs/Mews/app.log" ||
		job.StderrPath != "/Users/tester/Library/Logs/Mews/app.log" {
		t.Fatalf("CurrentJob = %#v, %v; want loaded job configuration", job, loaded)
	}
}

func TestCurrentJobReportsUnloadedService(t *testing.T) {
	original := runLaunchctl
	t.Cleanup(func() { runLaunchctl = original })
	runLaunchctl = func(args ...string) ([]byte, error) {
		return []byte("Could not find service"), errors.New("exit status 1")
	}

	job, loaded, err := CurrentJob()
	if err != nil {
		t.Fatalf("CurrentJob returned error: %v", err)
	}
	if loaded || job != (LoadedJob{}) {
		t.Fatalf("CurrentJob = %#v, %v; want unloaded", job, loaded)
	}
}
