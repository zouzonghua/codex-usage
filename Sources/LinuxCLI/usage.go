package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const usageURL = "https://chatgpt.com/backend-api/wham/usage"

var usageClient = &http.Client{
	Timeout: 20 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

type quotaWindow struct {
	Remaining int    `json:"remainingPercent"`
	ResetAt   string `json:"resetAt,omitempty"`
}

type quotaStatus struct {
	Account   string       `json:"account"`
	Primary   *quotaWindow `json:"primary,omitempty"`
	Secondary *quotaWindow `json:"secondary,omitempty"`
}

type httpStatus int

func (s httpStatus) Error() string { return fmt.Sprintf("quota request failed (HTTP %d)", s) }

func requestUsage(client *http.Client, account login) (quotaStatus, error) {
	request, err := http.NewRequest(http.MethodGet, usageURL, nil)
	if err != nil {
		return quotaStatus{}, err
	}
	request.Header.Set("Authorization", "Bearer "+account.token)
	request.Header.Set("User-Agent", "CodexUsage")
	request.Header.Set("Accept", "application/json")
	if account.workspace != "" {
		request.Header.Set("ChatGPT-Account-Id", account.workspace)
	}
	response, err := client.Do(request)
	if err != nil {
		return quotaStatus{}, errors.New("could not reach the quota service")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return quotaStatus{}, httpStatus(response.StatusCode)
	}
	var payload struct {
		Limits struct {
			Primary   rawWindow `json:"primary_window"`
			Secondary rawWindow `json:"secondary_window"`
		} `json:"rate_limit"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&payload); err != nil {
		return quotaStatus{}, errors.New("invalid quota response")
	}
	return quotaStatus{account.label("current"), payload.Limits.Primary.window(), payload.Limits.Secondary.window()}, nil
}

type rawWindow struct {
	Used  json.Number `json:"used_percent"`
	Reset json.Number `json:"reset_at"`
}

func (r rawWindow) window() *quotaWindow {
	if r.Used == "" && r.Reset == "" {
		return nil
	}
	used, _ := strconv.ParseFloat(string(r.Used), 64)
	window := &quotaWindow{Remaining: 100 - int(max(0, min(100, used)))}
	if seconds, err := r.Reset.Int64(); err == nil {
		if seconds > 100_000_000_000 {
			seconds /= 1000
		}
		window.ResetAt = time.Unix(seconds, 0).UTC().Format(time.RFC3339)
	}
	return window
}

func fetchQuota(s store, client *http.Client, refresh func(store, login) (login, error)) (quotaStatus, error) {
	data, err := readAuth(s.active)
	if err != nil {
		return quotaStatus{}, err
	}
	account, err := parseLogin(data)
	if err != nil {
		return quotaStatus{}, err
	}
	renewed := !account.expiry.IsZero() && !account.expiry.After(time.Now().Add(time.Minute))
	if renewed {
		account, err = refresh(s, account)
		if err != nil {
			return quotaStatus{}, err
		}
	}
	result, err := requestUsage(client, account)
	if err != httpStatus(401) || renewed {
		return result, err
	}
	account, err = refresh(s, account)
	if err != nil {
		return quotaStatus{}, err
	}
	return requestUsage(client, account)
}

func renew(s store, account login) (login, error) {
	directory, err := os.MkdirTemp("", "codex-usage-")
	if err != nil {
		return login{}, err
	}
	defer os.RemoveAll(directory)
	staged := filepath.Join(directory, "auth.json")
	if err := writeAuth(staged, account.data, nil); err != nil {
		return login{}, err
	}
	if err := runCodexRefresh(directory); err != nil {
		return login{}, err
	}
	data, err := readAuth(staged)
	if err != nil {
		return login{}, err
	}
	updated, err := parseLogin(data)
	if err != nil {
		return login{}, err
	}
	if !account.matches(updated) {
		return login{}, errors.New("renewed login belongs to a different account")
	}
	if updated.token == account.token || (!updated.expiry.IsZero() && !updated.expiry.After(time.Now())) {
		return login{}, errors.New("Codex did not return a refreshed access token; run codex login again")
	}
	if _, err := s.archive(updated); err != nil {
		return login{}, err
	}
	if err := writeAuth(s.active, updated.data, account.data); err != nil {
		return login{}, err
	}
	return updated, nil
}

func runCodexRefresh(directory string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "codex", "-c", `cli_auth_credentials_store="file"`, "app-server", "--listen", "stdio://")
	command.Dir = directory
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		switch key {
		case "CODEX_HOME", "CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY",
			"OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_FEDERATION_RULE_ID":
			continue
		}
		command.Env = append(command.Env, entry)
	}
	command.Env = append(command.Env, "CODEX_HOME="+directory)
	input, err := command.StdinPipe()
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	defer output.Close()
	stopClosing := context.AfterFunc(ctx, func() {
		_ = input.Close()
		_ = output.Close()
	})
	defer stopClosing()
	if err := command.Start(); err != nil {
		return errors.New("could not start the official Codex CLI to renew the login")
	}
	defer func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	}()
	if err := refreshProtocol(input, output); err != nil {
		return errors.New("Codex could not renew this login; run codex login again")
	}
	return nil
}

func refreshProtocol(input io.Writer, output io.Reader) error {
	encoder := json.NewEncoder(input)
	if err := encoder.Encode(map[string]any{
		"id": 1, "method": "initialize",
		"params": map[string]any{"clientInfo": map[string]string{"name": "codex_usage", "version": "1.0.0"}},
	}); err != nil {
		return err
	}
	expected := 1
	scanner := bufio.NewScanner(output)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	for scanner.Scan() {
		var message struct {
			ID     json.RawMessage
			Error  json.RawMessage
			Result *struct {
				Account struct{ Type string }
			}
		}
		if len(scanner.Bytes()) == 0 {
			continue
		}
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			return err
		}
		if string(message.ID) != strconv.Itoa(expected) {
			continue
		}
		if message.Result == nil || len(message.Error) > 0 {
			break
		}
		if expected == 2 {
			if message.Result.Account.Type == "chatgpt" {
				return nil
			}
			break
		}
		if err := encoder.Encode(map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
			return err
		}
		if err := encoder.Encode(map[string]any{"id": 2, "method": "account/read", "params": map[string]bool{"refreshToken": true}}); err != nil {
			return err
		}
		expected = 2
	}
	return errors.New("incomplete Codex refresh")
}
