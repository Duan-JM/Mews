package launchd

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"text/template"
)

const Label = "dev.mews.agent"

var runLaunchctl = func(args ...string) ([]byte, error) {
	return exec.Command("launchctl", args...).CombinedOutput()
}

type Job struct {
	Label      string
	Program    string
	HomePath   string
	StdoutPath string
	StderrPath string
}

func PlistPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", Label+".plist"), nil
}

func Install(program, logsDir string) (string, error) {
	if program == "" {
		return "", errors.New("launchd program path is required")
	}
	if logsDir == "" {
		return "", errors.New("launchd logs directory is required")
	}
	if err := os.MkdirAll(logsDir, 0o700); err != nil {
		return "", err
	}

	path, err := PlistPath()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	data, err := Render(Job{
		Label:      Label,
		Program:    program,
		HomePath:   home,
		StdoutPath: filepath.Join(logsDir, "app.log"),
		StderrPath: filepath.Join(logsDir, "app.log"),
	})
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	return path, nil
}

func Render(job Job) ([]byte, error) {
	var buf bytes.Buffer
	if err := plistTemplate.Execute(&buf, job); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func Bootstrap() error {
	path, err := PlistPath()
	if err != nil {
		return err
	}
	return launchctl("bootstrap", guiDomain(), path)
}

func Bootout() error {
	path, err := PlistPath()
	if err != nil {
		return err
	}
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	loaded, status, err := loadedStatus()
	if err != nil {
		if isLaunchctlNotLoadedText(status) {
			return nil
		}
		return fmt.Errorf("launchctl print %s/%s: %s", guiDomain(), Label, status)
	}
	if !loaded {
		return nil
	}
	if err := launchctl("bootout", guiDomain()+"/"+Label); err != nil && !isLaunchctlNotLoaded(err) {
		return err
	}
	return nil
}

func RemovePlist() error {
	path, err := PlistPath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func Loaded() (bool, string) {
	loaded, status, _ := loadedStatus()
	return loaded, status
}

func loadedStatus() (bool, string, error) {
	output, err := runLaunchctl("print", guiDomain()+"/"+Label)
	if err != nil {
		text := strings.TrimSpace(string(output))
		if text == "" {
			text = "not loaded"
		}
		return false, text, err
	}
	return true, "loaded", nil
}

func launchctl(args ...string) error {
	output, err := runLaunchctl(args...)
	if err == nil {
		return nil
	}
	text := strings.TrimSpace(string(output))
	if text == "" {
		text = err.Error()
	}
	return fmt.Errorf("launchctl %s: %s", strings.Join(args, " "), text)
}

func guiDomain() string {
	return fmt.Sprintf("gui/%d", os.Getuid())
}

func isLaunchctlNotLoaded(err error) bool {
	return isLaunchctlNotLoadedText(err.Error())
}

func isLaunchctlNotLoadedText(text string) bool {
	return strings.Contains(text, "Could not find service") ||
		strings.Contains(text, "No such process") ||
		strings.Contains(text, "not found")
}

func escapePlistString(value string) string {
	var buf bytes.Buffer
	if err := xml.EscapeText(&buf, []byte(value)); err != nil {
		return value
	}
	return buf.String()
}

var plistTemplate = template.Must(template.New("launchd-plist").Funcs(template.FuncMap{
	"plist": escapePlistString,
}).Parse(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{{plist .Label}}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{{plist .Program}}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>{{plist .HomePath}}</string>
  </dict>
  <key>StandardOutPath</key>
  <string>{{plist .StdoutPath}}</string>
  <key>StandardErrorPath</key>
  <string>{{plist .StderrPath}}</string>
</dict>
</plist>
`))
