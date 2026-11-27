#!/usr/bin/env bash
set -euo pipefail

asset="codex-usage-linux"
mkdir -p dist
install -m 755 Sources/LinuxCLI/codex-usage "dist/$asset"
size="$(wc -c < "dist/$asset")"
printf 'Linux CLI size: %d bytes (limit: 1000000 bytes)\n' "$size"
if (( size > 1000000 )); then
    echo "Linux CLI exceeds the release size limit." >&2
    exit 1
fi
(
    cd dist
    sha256sum "$asset" > "$asset.sha256"
    sha256sum -c "$asset.sha256"
)
