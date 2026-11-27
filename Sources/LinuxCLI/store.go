package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var profileID = regexp.MustCompile(`(?i)^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$`)

type login struct {
	data                          []byte
	token, workspace, user, email string
	expiry, refreshed             time.Time
}

func parseLogin(data []byte) (login, error) {
	var auth struct {
		APIKey string `json:"OPENAI_API_KEY"`
		Tokens struct {
			Access        string `json:"access_token"`
			ID            string `json:"id_token"`
			Account       string `json:"account_id"`
			AccessLegacy  string `json:"accessToken"`
			IDLegacy      string `json:"idToken"`
			AccountLegacy string `json:"accountId"`
		}
		LastRefresh string `json:"last_refresh"`
	}
	if data == nil {
		return login{}, errors.New("no file-based login; run codex login with file credential storage")
	}
	if json.Unmarshal(data, &auth) != nil || auth.APIKey != "" {
		return login{}, errors.New("expected a ChatGPT OAuth auth.json")
	}
	token := first(auth.Tokens.Access, auth.Tokens.AccessLegacy)
	if token == "" {
		return login{}, errors.New("invalid ChatGPT auth.json")
	}
	access := tokenClaims(token)
	identity := tokenClaims(first(auth.Tokens.ID, auth.Tokens.IDLegacy))
	if identity == nil {
		identity = access
	}
	workspace, _ := identity["https://api.openai.com/auth"].(map[string]any)
	profile, _ := identity["https://api.openai.com/profile"].(map[string]any)
	refreshed, _ := time.Parse(time.RFC3339Nano, auth.LastRefresh)
	var expiry time.Time
	if seconds, ok := access["exp"].(float64); ok {
		expiry = time.Unix(int64(seconds), 0)
	}
	return login{
		data: data, token: token, refreshed: refreshed, expiry: expiry,
		workspace: first(auth.Tokens.Account, auth.Tokens.AccountLegacy, claim(workspace, "chatgpt_account_id"), claim(identity, "chatgpt_account_id")),
		user:      first(claim(workspace, "chatgpt_user_id"), claim(identity, "sub")),
		email:     first(claim(identity, "email"), claim(profile, "email")),
	}, nil
}

func first(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func claim(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return value
}

func tokenClaims(token string) map[string]any {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return nil
	}
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		// Older local fixtures and archives may use standard base64.
		payload, err = base64.RawStdEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	}
	var claims map[string]any
	if err != nil || json.Unmarshal(payload, &claims) != nil {
		return nil
	}
	return claims
}

func (l login) matches(other login) bool {
	if l.workspace == "" || l.workspace != other.workspace {
		return false
	}
	if l.user != "" && other.user != "" {
		return l.user == other.user
	}
	return l.email != "" && strings.EqualFold(l.email, other.email)
}

func (l login) olderThan(other login) bool {
	if !l.refreshed.IsZero() && !other.refreshed.IsZero() {
		return l.refreshed.Before(other.refreshed)
	}
	return !l.expiry.IsZero() && !other.expiry.IsZero() && l.expiry.Before(other.expiry)
}

func (l login) label(fallback string) string {
	return strings.Join(strings.Fields(first(l.email, fallback)), " ")
}

type store struct {
	active, root string
}

func newStore() (store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return store{}, err
	}
	dataHome := os.Getenv("XDG_DATA_HOME")
	if !filepath.IsAbs(dataHome) {
		dataHome = filepath.Join(home, ".local", "share")
	}
	return store{
		active: filepath.Join(first(os.Getenv("CODEX_HOME"), filepath.Join(home, ".codex")), "auth.json"),
		root:   filepath.Join(dataHome, "CodexUsage"),
	}, nil
}

func (s store) lock() (*os.File, error) {
	if err := os.MkdirAll(s.root, 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(s.root, "credentials.lock"), os.O_WRONLY|os.O_CREATE|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err == nil && !info.Mode().IsRegular() {
		err = errors.New("invalid credential lock file")
	}
	if err == nil {
		lock := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: io.SeekStart}
		for {
			err = syscall.FcntlFlock(file.Fd(), syscall.F_SETLKW, &lock)
			if err != syscall.EINTR {
				break
			}
		}
	}
	if err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

func readAuth(path string) ([]byte, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	const maxAuthSize = 1 << 20
	if !info.Mode().IsRegular() || info.Size() > maxAuthSize {
		return nil, errors.New("invalid credential file")
	}
	data, err := io.ReadAll(io.LimitReader(file, maxAuthSize+1))
	if len(data) > maxAuthSize {
		return nil, errors.New("invalid credential file")
	}
	return data, err
}

func writeAuth(path string, data, expected []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(dir, ".auth-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return errors.Join(err, closeErr)
	}
	current, err := readAuth(path)
	if err != nil {
		return err
	}
	if (current == nil) != (expected == nil) || !bytes.Equal(current, expected) {
		return errors.New("credentials changed during the operation; retry")
	}
	return os.Rename(file.Name(), path)
}

type savedLogin struct {
	id string
	login
}

func (s store) saved() ([]savedLogin, error) {
	entries, err := os.ReadDir(filepath.Join(s.root, "accounts"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var accounts []savedLogin
	for _, entry := range entries {
		if !entry.IsDir() || !profileID.MatchString(entry.Name()) {
			continue
		}
		data, err := readAuth(s.profilePath(entry.Name()))
		if err != nil {
			continue
		}
		if account, err := parseLogin(data); err == nil {
			accounts = append(accounts, savedLogin{entry.Name(), account})
		}
	}
	return accounts, nil
}

func (s store) profilePath(id string) string {
	return filepath.Join(s.root, "accounts", id, "auth.json")
}

func (s store) archive(account login) (string, error) {
	if account.workspace == "" || (account.user == "" && account.email == "") {
		return "", errors.New("the login does not identify a ChatGPT account and workspace")
	}
	saved, err := s.saved()
	if err != nil {
		return "", err
	}
	for _, candidate := range saved {
		if account.matches(candidate.login) {
			if !bytes.Equal(account.data, candidate.data) && !account.olderThan(candidate.login) {
				if err := writeAuth(s.profilePath(candidate.id), account.data, candidate.data); err != nil {
					return "", err
				}
			}
			return candidate.id, nil
		}
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	random[6] = random[6]&0x0f | 0x40
	random[8] = random[8]&0x3f | 0x80
	id := fmt.Sprintf("%x-%x-%x-%x-%x", random[:4], random[4:6], random[6:8], random[8:10], random[10:])
	return id, writeAuth(s.profilePath(id), account.data, nil)
}

func (s store) activate(id string) (login, error) {
	current, err := readAuth(s.active)
	if err != nil {
		return login{}, err
	}
	if id == "system" {
		return parseLogin(current)
	}
	saved, err := s.saved()
	if err != nil {
		return login{}, err
	}
	for _, selected := range saved {
		if selected.id != id {
			continue
		}
		if current != nil {
			active, err := parseLogin(current)
			if err != nil {
				return login{}, err
			}
			if active.matches(selected.login) {
				return active, nil
			}
			if _, err := s.archive(active); err != nil {
				return login{}, err
			}
		}
		return selected.login, writeAuth(s.active, selected.data, current)
	}
	return login{}, errors.New("unknown account ID; run accounts to list IDs")
}
