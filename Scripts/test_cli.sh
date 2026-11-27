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
[[ "$("$fixture/cu" status --help)" == 'usage: cu status'* ]]
[[ "$("$fixture/cu" help switch)" == 'usage: cu switch'* ]]
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

# Exercise successful quota decoding and JSON output without a real login or network.
python3 - "$cli" <<'PYTEST'
import contextlib
import io
import json
import runpy
import sys
from unittest.mock import patch

entry = runpy.run_path(sys.argv[1])
with patch("urllib.request.build_opener") as opener:
    opener.return_value.open.return_value = io.BytesIO(b"""{
        "rate_limit": {
            "primary_window": {"used_percent": 25, "reset_at": 1800000000},
            "secondary_window": {"used_percent": 10}
        }
    }""")
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert entry["main"](["status", "--json"]) == 0
    request, = opener.return_value.open.call_args.args
    assert request.full_url == "https://chatgpt.com/backend-api/wham/usage"
    assert request.get_header("Chatgpt-account-id") == "alpha"
    assert json.loads(output.getvalue()) == {
        "account": "alpha@example.test",
        "primary": {"remainingPercent": 75, "resetAt": "2027-01-15T08:00:00Z"},
        "secondary": {"remainingPercent": 90},
    }
PYTEST


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

# Simulate Codex app-server and a single retry after a 401 response.
mkdir "$fixture/bin"
cat > "$fixture/bin/codex" <<'PYCODEX'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

assert sys.argv[1:] == ["-c", 'cli_auth_credentials_store="file"', "app-server", "--listen", "stdio://"]
assert json.loads(input())["method"] == "initialize"
print(json.dumps({"id": 1, "result": {}}), flush=True)
assert json.loads(input())["method"] == "initialized"
assert json.loads(input()) == {"id": 2, "method": "account/read", "params": {"refreshToken": True}}
path = Path(os.environ["CODEX_HOME"]) / "auth.json"
assert path.parent.resolve() == Path.cwd()
auth = json.loads(path.read_bytes())
if os.environ.get("TEST_UNCHANGED_LOGIN") != "1":
    auth["tokens"]["access_token"] += "-renewed"
path.write_text(json.dumps(auth))
print(json.dumps({"id": 2, "result": {"account": {"type": "chatgpt"}}}), flush=True)
PYCODEX
chmod +x "$fixture/bin/codex"
PATH="$fixture/bin:$PATH" python3 - "$cli" <<'PYTEST'
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import sys
from unittest.mock import patch
from urllib.error import HTTPError

entry = runpy.run_path(sys.argv[1])
with patch("urllib.request.build_opener") as opener:
    request = opener.return_value.open
    request.side_effect = [HTTPError("", 401, "", {}, None), io.BytesIO(b'{"rate_limit": {}}')]
    with contextlib.redirect_stdout(io.StringIO()):
        assert entry["main"](["status", "--json"]) == 0
    assert request.call_count == 2
    retry = request.call_args.args[0]
    assert retry.get_header("Authorization").endswith("-renewed")
active = Path(os.environ["CODEX_HOME"]) / "auth.json"
before = active.read_bytes()
assert json.loads(before)["tokens"]["access_token"].endswith("-renewed")

with patch.dict(os.environ, {"TEST_UNCHANGED_LOGIN": "1"}), patch("urllib.request.build_opener") as opener:
    request = opener.return_value.open
    request.side_effect = HTTPError("", 401, "", {}, None)
    errors = io.StringIO()
    with contextlib.redirect_stderr(errors):
        assert entry["main"](["status", "--json"]) == 1
    assert "did not return a refreshed access token" in errors.getvalue()
    assert request.call_count == 1
assert active.read_bytes() == before

with patch("urllib.request.build_opener") as opener:
    request = opener.return_value.open
    request.side_effect = HTTPError("", 403, "", {}, None)
    errors = io.StringIO()
    with contextlib.redirect_stderr(errors):
        assert entry["main"](["status", "--json"]) == 1
    assert "HTTP 403" in errors.getvalue()
    assert request.call_count == 1
assert active.read_bytes() == before
PYTEST
