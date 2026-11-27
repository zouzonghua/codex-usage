package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const helpText = `Usage: %s <command>

  status [--json]       Query the active login's quota
  accounts              List account IDs; * marks the active login
  import [codex-home]   Save a ChatGPT login from auth.json
  switch <id>           Activate a saved login
  help [command]        Show general or command-specific help

For automation, use status --json and accounts to find switch IDs.
`

var commandHelp = map[string]string{
	"status":   "status [--json]\nQuery remaining quota and reset times. Use --json for automation.",
	"accounts": "accounts\nList IDs and account names. A leading * marks the active login.",
	"import":   "import [codex-home]\nImport the directory's auth.json. Defaults to CODEX_HOME or ~/.codex.",
	"switch":   "switch <id>\nActivate an ID from accounts, then start a new Codex session.",
}

func main() {
	name := filepath.Base(os.Args[0])
	if err := run(name, os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", name, err)
		os.Exit(1)
	}
}

func run(name string, args []string) error {
	if len(args) == 0 || (len(args) == 1 && (args[0] == "help" || helpFlag(args[0]))) {
		fmt.Printf(helpText, name)
		return nil
	}
	command := args[0]
	if len(args) == 2 && (command == "help" || helpFlag(args[1])) {
		topic := command
		if command == "help" {
			topic = args[1]
		}
		if page, ok := commandHelp[topic]; ok {
			fmt.Printf("Usage: %s %s\n", name, page)
			return nil
		}
		return errors.New("unknown help topic; run --help")
	}
	if err := validateArgs(args); err != nil {
		return err
	}
	s, err := newStore()
	if err != nil {
		return err
	}
	lock, err := s.lock()
	if err != nil {
		return err
	}
	defer lock.Close()

	switch command {
	case "status":
		status, err := fetchQuota(s, usageClient, renew)
		if err != nil {
			return err
		}
		if len(args) == 2 {
			return json.NewEncoder(os.Stdout).Encode(status)
		}
		fmt.Printf("Account: %s\n", status.Account)
		printWindow("5-hour", status.Primary)
		printWindow("Weekly", status.Secondary)
	case "accounts":
		return printAccounts(s)
	case "import":
		path := s.active
		if len(args) == 2 {
			path = filepath.Join(args[1], "auth.json")
		}
		data, err := readAuth(path)
		if err != nil {
			return err
		}
		account, err := parseLogin(data)
		if err != nil {
			return err
		}
		id, err := s.archive(account)
		if err != nil {
			return err
		}
		fmt.Printf("Saved %s\n", account.label(id))
	case "switch":
		account, err := s.activate(args[1])
		if err != nil {
			return err
		}
		fmt.Printf("Active file-based login: %s. Start a new Codex session.\n", account.label(args[1]))
	}
	return nil
}

func helpFlag(value string) bool { return value == "--help" || value == "-h" }

func validateArgs(args []string) error {
	switch args[0] {
	case "status":
		if len(args) == 1 || (len(args) == 2 && args[1] == "--json") {
			return nil
		}
	case "accounts":
		if len(args) == 1 {
			return nil
		}
	case "import":
		if len(args) <= 2 {
			return nil
		}
	case "switch":
		if len(args) == 2 {
			return nil
		}
	}
	return errors.New("invalid command or arguments; run --help")
}

func printAccounts(s store) error {
	data, err := readAuth(s.active)
	if err != nil {
		return err
	}
	var current login
	if data != nil {
		current, err = parseLogin(data)
		if err != nil {
			return err
		}
	}
	saved, err := s.saved()
	if err != nil {
		return err
	}
	if data != nil {
		fmt.Printf("* system\t%s\n", current.label("current"))
	}
	for _, account := range saved {
		if !current.matches(account.login) {
			fmt.Printf("  %s\t%s\n", account.id, account.label(account.id))
		}
	}
	return nil
}

func printWindow(name string, window *quotaWindow) {
	if window == nil {
		fmt.Printf("%s: unavailable\n", name)
		return
	}
	fmt.Printf("%s: %d%% remaining (resets: %s)\n", name, window.Remaining, first(window.ResetAt, "unknown"))
}
