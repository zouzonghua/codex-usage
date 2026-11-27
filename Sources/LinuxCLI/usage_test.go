package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func authFixture(tokenSuffix, email string) []byte {
	claims, _ := json.Marshal(map[string]string{"email": email})
	token := "fake." + base64.RawURLEncoding.EncodeToString(claims) + "." + tokenSuffix
	return []byte(fmt.Sprintf(`{"tokens":{"access_token":%q,"account_id":"workspace"}}`, token))
}

func TestQuotaRefreshRetriesOnce(t *testing.T) {
	for _, test := range []struct {
		name             string
		statuses         []int
		refreshes        int
		expectedHTTPFail httpStatus
	}{
		{"success", []int{200}, 0, 0},
		{"renew", []int{401, 200}, 1, 0},
		{"retry rejected", []int{401, 401}, 1, 401},
		{"forbidden", []int{403}, 0, 403},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			s := store{active: filepath.Join(dir, "auth.json"), root: dir}
			if err := writeAuth(s.active, authFixture("original", "user@example.test"), nil); err != nil {
				t.Fatal(err)
			}
			calls, refreshes := 0, 0
			client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
				if calls >= len(test.statuses) {
					t.Fatal("unexpected quota request")
				}
				suffix := ".original"
				if calls > 0 {
					suffix = ".updated"
				}
				if request.URL.String() != usageURL || request.Header.Get("ChatGPT-Account-Id") != "workspace" ||
					!strings.HasSuffix(request.Header.Get("Authorization"), suffix) {
					t.Fatal("unexpected quota request metadata")
				}
				code := test.statuses[calls]
				calls++
				body := `{"rate_limit":{"primary_window":{"used_percent":"25","reset_at":1800000000000},"secondary_window":{"used_percent":10}}}`
				return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body))}, nil
			})}
			result, err := fetchQuota(s, client, func(store, login) (login, error) {
				refreshes++
				return parseLogin(authFixture("updated", "user@example.test"))
			})
			if calls != len(test.statuses) || refreshes != test.refreshes {
				t.Fatalf("got %d requests and %d renewals", calls, refreshes)
			}
			if test.expectedHTTPFail != 0 {
				if err != test.expectedHTTPFail {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err != nil || result.Account != "user@example.test" ||
				result.Primary == nil || *result.Primary != (quotaWindow{75, "2027-01-15T08:00:00Z"}) ||
				result.Secondary == nil || result.Secondary.Remaining != 90 {
				t.Fatalf("unexpected quota: %+v, %v", result, err)
			}
		})
	}
}

func TestCodexRefreshValidatesBeforeWriting(t *testing.T) {
	for _, test := range []struct {
		name, suffix, email string
		success             bool
	}{
		{"renew", "updated", "user@example.test", true},
		{"unchanged token", "original", "user@example.test", false},
		{"different account", "updated", "other@example.test", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			s := store{active: filepath.Join(dir, "auth.json"), root: dir}
			original := authFixture("original", "user@example.test")
			updated := authFixture(test.suffix, test.email)
			if err := writeAuth(s.active, original, nil); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "updated.json"), updated, 0600); err != nil {
				t.Fatal(err)
			}
			fake := `#!/bin/sh
set -eu
test "$1" = '-c'
test "$2" = 'cli_auth_credentials_store="file"'
test "$3 $4 $5" = 'app-server --listen stdio://'
test -z "${OPENAI_API_KEY:-}"
test ! "$CODEX_HOME/auth.json" -ef "$ACTIVE_FIXTURE"
IFS= read -r request
case "$request" in (*'"method":"initialize"'*) ;; (*) exit 1 ;; esac
printf '%s\n' '{"id":1,"result":{}}'
IFS= read -r request
case "$request" in (*'"method":"initialized"'*) ;; (*) exit 1 ;; esac
IFS= read -r request
case "$request" in (*'"method":"account/read"'*'"refreshToken":true'*) ;; (*) exit 1 ;; esac
cp "$RENEWED_FIXTURE" "$CODEX_HOME/auth.json"
printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
`
			if err := os.WriteFile(filepath.Join(dir, "codex"), []byte(fake), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
			t.Setenv("OPENAI_API_KEY", "fixture-key")
			t.Setenv("ACTIVE_FIXTURE", s.active)
			t.Setenv("RENEWED_FIXTURE", filepath.Join(dir, "updated.json"))
			account, err := parseLogin(original)
			if err != nil {
				t.Fatal(err)
			}
			_, err = renew(s, account)
			if (err == nil) != test.success {
				t.Fatalf("unexpected renewal result: %v", err)
			}
			expected := original
			if test.success {
				expected = updated
			}
			data, err := readAuth(s.active)
			if err != nil || string(data) != string(expected) {
				t.Fatal("active credentials do not match expected contents")
			}
		})
	}
}
