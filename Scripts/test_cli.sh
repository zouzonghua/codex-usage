#!/usr/bin/env bash
set -euo pipefail

cli="${1:?Pass the path to codex-usage}"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export CODEX_HOME="$fixture/current"
export XDG_DATA_HOME="$fixture/data"
export XDG_CONFIG_HOME="$fixture/config"
export CFFIXED_USER_HOME="$fixture"
mkdir -p "$CODEX_HOME" "$fixture/other"

"$cli" --help
install -m 755 "$cli" "$fixture/cu"
[[ "$("$fixture/cu" status --help)" == 'Usage: cu status [--json]'* ]]
[[ "$("$fixture/cu" help switch)" == 'Usage: cu switch <id>'* ]]
if "$cli" status --json; then
    echo 'Expected status to fail with no login' >&2
    exit 1
fi

make_login() {
    local name="$1" directory="$2" claims
    claims="$(printf '{"email":"%s@example.test"}' "$name" | base64 | tr -d '=\n')"
    printf '{"tokens":{"access_token":"fake.%s.fake","account_id":"%s"}}\n' "$claims" "$name" > "$directory/auth.json"
}

make_login alpha "$CODEX_HOME"
make_login beta "$fixture/other"
cp "$CODEX_HOME/auth.json" "$fixture/alpha.json"

"$cli" import "$fixture/other"
beta_id="$("$cli" accounts | awk '$2 == "beta@example.test" {print $1}')"
"$cli" switch "$beta_id"
cmp "$CODEX_HOME/auth.json" "$fixture/other/auth.json"

alpha_id="$("$cli" accounts | awk '$2 == "alpha@example.test" {print $1}')"
"$cli" switch "$alpha_id"
cmp "$CODEX_HOME/auth.json" "$fixture/alpha.json"
"$cli" accounts | awk '$1 == "*" && $2 == "system" && $3 == "alpha@example.test" { found = 1 } END { exit !found }'

file_mode() {
    if [[ "$(uname -s)" == Linux ]]; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

test "$(file_mode "$CODEX_HOME/auth.json")" = 600
if [[ "$(uname -s)" == Linux ]]; then
    for id in "$alpha_id" "$beta_id"; do
        test "$(file_mode "$XDG_DATA_HOME/CodexUsage/accounts/$id/auth.json")" = 600
    done
fi

# A dangling link is readable by neither root nor an ordinary user.
mv "$CODEX_HOME/auth.json" "$fixture/last-active.json"
ln -s "$fixture/missing.json" "$CODEX_HOME/auth.json"
if "$cli" switch "$beta_id"; then
    echo 'Expected switch to reject an unreadable active credential' >&2
    exit 1
fi
test -L "$CODEX_HOME/auth.json"
rm "$CODEX_HOME/auth.json"
"$cli" switch "$beta_id"
cmp "$CODEX_HOME/auth.json" "$fixture/other/auth.json"
"$cli" import
