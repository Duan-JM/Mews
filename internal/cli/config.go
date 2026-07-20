package cli

import (
	"fmt"
	"io"

	"github.com/Duan-JM/mews/internal/store"
	"github.com/Duan-JM/mews/internal/terminal"
)

func runConfig(args []string, stdout, stderr io.Writer) int {
	if len(args) > 2 || (len(args) > 0 && args[0] != "terminal") {
		printConfigUsage(stderr)
		return 2
	}

	state, configured, err := store.LoadSetupState()
	if err != nil {
		fmt.Fprintf(stderr, "Could not read Mews config: %v\n", err)
		return 1
	}
	if len(args) < 2 {
		current, err := terminal.ParseProfile(state.Terminal)
		if err != nil {
			fmt.Fprintf(stderr, "Invalid terminal preference in config: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "Terminal preference: %s\n", terminal.Description(current))
		return 0
	}
	if !configured {
		fmt.Fprintln(stderr, "Mews is not set up yet. Run `mw setup --yes` first.")
		return 1
	}

	profile, err := terminal.ParseProfile(args[1])
	if err != nil {
		fmt.Fprintf(stderr, "%v. Choose one of: %s\n", err, terminal.Choices())
		return 2
	}
	state.Terminal = string(profile)
	if err := store.SaveSetupState(state); err != nil {
		fmt.Fprintf(stderr, "Could not save terminal preference: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Terminal preference saved: %s\n", terminal.Description(profile))
	return 0
}

func printConfigUsage(w io.Writer) {
	fmt.Fprintf(w, "Usage: mw config terminal [%s]\n", terminal.Choices())
}
