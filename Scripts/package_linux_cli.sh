#!/usr/bin/env bash
set -euo pipefail

asset="codex-usage-linux"
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.linux-cli.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
(
    cd Sources/LinuxCLI
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$staging/$asset" .
)
format="$(file -b "$staging/$asset")"
printf '%s\n' "$format"
[[ "$format" == ELF\ 64-bit* && "$format" == *x86-64* && "$format" == *statically\ linked* ]]
printf 'Linux CLI size: %d bytes\n' "$(wc -c < "$staging/$asset")"
(
    cd "$staging"
    sha256sum "$asset" > "$asset.sha256"
    sha256sum -c "$asset.sha256"
)
mv "$staging/$asset" "$staging/$asset.sha256" dist/
