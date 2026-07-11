package app

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

const BundleName = "Mews.app"

var ErrNotFound = errors.New("Mews.app bundle not found")

type Bundle struct {
	Path       string
	Executable string
}

func ResolveBundle() (Bundle, error) {
	if path := os.Getenv("MEWS_APP_PATH"); path != "" {
		return bundleAt(path)
	}

	executable, err := os.Executable()
	if err != nil {
		return Bundle{}, err
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}

	executables := []string{StableInstalledPath(executable)}
	if executables[0] != executable {
		executables = append(executables, executable)
	}
	var candidates []string
	for _, executable := range executables {
		exeDir := filepath.Dir(executable)
		candidates = append(candidates,
			filepath.Join(exeDir, "..", "lib", BundleName),
			filepath.Join(exeDir, "..", "libexec", BundleName),
			filepath.Join(exeDir, BundleName),
		)
	}
	for _, candidate := range candidates {
		if bundle, err := bundleAt(filepath.Clean(candidate)); err == nil {
			return bundle, nil
		}
	}
	return Bundle{}, ErrNotFound
}

func StableInstalledPath(path string) string {
	const cellarMarker = "/Cellar/mews/"
	index := strings.Index(path, cellarMarker)
	if index < 0 {
		return path
	}
	remainder := path[index+len(cellarMarker):]
	versionEnd := strings.IndexByte(remainder, '/')
	if versionEnd < 0 || versionEnd == len(remainder)-1 {
		return path
	}
	return filepath.Join(path[:index], "opt", "mews", remainder[versionEnd+1:])
}

func bundleAt(path string) (Bundle, error) {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Bundle{}, ErrNotFound
		}
		return Bundle{}, err
	}
	if !info.IsDir() {
		return Bundle{}, ErrNotFound
	}

	executable := filepath.Join(path, "Contents", "MacOS", "Mews")
	if info, err := os.Stat(executable); err != nil {
		if os.IsNotExist(err) {
			return Bundle{}, ErrNotFound
		}
		return Bundle{}, err
	} else if info.IsDir() {
		return Bundle{}, ErrNotFound
	}
	return Bundle{Path: path, Executable: executable}, nil
}
