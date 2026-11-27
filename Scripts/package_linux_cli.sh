#!/usr/bin/env bash
set -euo pipefail

swift build -c release --product codex-usage --static-swift-stdlib
bin_dir="$(swift build -c release --show-bin-path)"
asset="codex-usage-linux-x86_64"
mkdir -p dist
install -m 755 "$bin_dir/codex-usage" "dist/$asset"
(
    cd dist
    sha256sum "$asset" > "$asset.sha256"
    sha256sum -c "$asset.sha256"
)
