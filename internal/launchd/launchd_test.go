package launchd

import (
	"strings"
	"testing"
)

func TestRenderPlist(t *testing.T) {
	data, err := Render(Job{
		Label:      Label,
		Program:    "/Applications/Mews.app/Contents/MacOS/Mews",
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
		StdoutPath: "/tmp/mews&app.log",
		StderrPath: "/tmp/mews&app.log",
	})
	if err != nil {
		t.Fatalf("Render returned error: %v", err)
	}
	content := string(data)
	for _, want := range []string{
		"/tmp/Mews &amp; Friends.app/Contents/MacOS/Mews",
		"/tmp/mews&amp;app.log",
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("plist missing escaped %q: %s", want, content)
		}
	}
}
