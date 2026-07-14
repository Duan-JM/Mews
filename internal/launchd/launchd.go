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
	Label           string
	Program         string
	HomePath        string
	SocketNamespace string
	StdoutPath      string
	StderrPath      string
}

type LoadedJob struct {
	Program         string
	HomePath        string
	SocketNamespace string
	StdoutPath      string
	StderrPath      string
}

func PlistPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", Label+".plist"), nil
}

func Install(program, logsDir string) (string, error) {
	return InstallWithNamespace(program, logsDir, os.Getenv("MEWS_SOCKET_NAMESPACE"))
}

func InstallWithNamespace(program, logsDir, socketNamespace string) (string, error) {
	if program == "" {
		return "", errors.New("launchd program path is required")
	}
	if logsDir == "" {
		return "", errors.New("launchd logs directory is required")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return install(Job{
		Label:           Label,
		Program:         program,
		HomePath:        home,
		SocketNamespace: socketNamespace,
		StdoutPath:      filepath.Join(logsDir, "app.log"),
		StderrPath:      filepath.Join(logsDir, "app.log"),
	})
}

func InstallLoadedJob(job LoadedJob) (string, error) {
	return install(Job{
		Label:           Label,
		Program:         job.Program,
		HomePath:        job.HomePath,
		SocketNamespace: job.SocketNamespace,
		StdoutPath:      job.StdoutPath,
		StderrPath:      job.StderrPath,
	})
}

func install(job Job) (string, error) {
	if job.Program == "" {
		return "", errors.New("launchd program path is required")
	}
	if job.HomePath == "" {
		return "", errors.New("launchd HOME path is required")
	}
	if job.StdoutPath == "" || job.StderrPath == "" {
		return "", errors.New("launchd log paths are required")
	}
	for _, logPath := range []string{job.StdoutPath, job.StderrPath} {
		if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
			return "", err
		}
	}

	path, err := PlistPath()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}

	data, err := Render(job)
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

func Kickstart() error {
	return launchctl("kickstart", "-k", guiDomain()+"/"+Label)
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

func CurrentJob() (LoadedJob, bool, error) {
	output, err := runLaunchctl("print", guiDomain()+"/"+Label)
	if err != nil {
		text := strings.TrimSpace(string(output))
		if isLaunchctlNotLoadedText(text) {
			return LoadedJob{}, false, nil
		}
		if text == "" {
			text = err.Error()
		}
		return LoadedJob{}, false, fmt.Errorf("launchctl print %s/%s: %s", guiDomain(), Label, text)
	}
	var job LoadedJob
	for _, line := range strings.Split(string(output), "\n") {
		trimmed := strings.TrimSpace(line)
		if program, found := strings.CutPrefix(trimmed, "program = "); found {
			job.Program = strings.Trim(program, `"`)
		}
		if home, found := strings.CutPrefix(trimmed, "HOME => "); found {
			job.HomePath = strings.Trim(home, `"`)
		}
		if namespace, found := strings.CutPrefix(trimmed, "MEWS_SOCKET_NAMESPACE => "); found {
			job.SocketNamespace = strings.Trim(namespace, `"`)
		}
		if stdoutPath, found := strings.CutPrefix(trimmed, "stdout path = "); found {
			job.StdoutPath = strings.Trim(stdoutPath, `"`)
		}
		if stderrPath, found := strings.CutPrefix(trimmed, "stderr path = "); found {
			job.StderrPath = strings.Trim(stderrPath, `"`)
		}
	}
	if job.Program == "" {
		return LoadedJob{}, true, errors.New("loaded Mews LaunchAgent has no program path")
	}
	return job, true, nil
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
	return fmt.Errorf("launchctl %s: %s: %w", strings.Join(args, " "), text, err)
}

func IsBootstrapRace(err error) bool {
	var coded interface{ ExitCode() int }
	return errors.As(err, &coded) && coded.ExitCode() == 5
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
{{- if .SocketNamespace }}
    <key>MEWS_SOCKET_NAMESPACE</key>
    <string>{{plist .SocketNamespace}}</string>
{{- end }}
  </dict>
  <key>StandardOutPath</key>
  <string>{{plist .StdoutPath}}</string>
  <key>StandardErrorPath</key>
  <string>{{plist .StderrPath}}</string>
</dict>
</plist>
`))
