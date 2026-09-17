#!/bin/bash
set -euo pipefail

beta_number="${1:-}"

if [[ ! "$beta_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Beta releases require a positive numeric beta number." >&2
    exit 1
fi

initial_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo "0.1.0")"

if [[ ! "$initial_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid initial version: $initial_version" >&2
    exit 1
fi

write_output() {
    local key="$1"
    local value="$2"

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "$key=$value" >> "$GITHUB_OUTPUT"
    else
        echo "$key=$value"
    fi
}

# 查找当前仓库最新的正式 tag (vX.Y.Z)
latest_stable_tag="$(
    git tag |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
        sort -V |
        tail -n 1 || true
)"

if [[ -z "$latest_stable_tag" ]]; then
    target_version="$initial_version"
    release_base=""
else
    target_version="${latest_stable_tag#v}"
    release_base="$latest_stable_tag"
fi

# 获取自上次正式 tag (或最开端) 以来的所有 commit
if [[ -n "$release_base" ]] && git merge-base --is-ancestor "$release_base" HEAD; then
    commits="$(git log "${release_base}..HEAD" --format='%s%n%b')"
else
    commits="$(git log HEAD --format='%s%n%b')"
fi

# 判断版本升级类型
if grep -Eq '^[a-zA-Z]+(\([^)]*\))?!:|^BREAKING[ -]CHANGE:' <<< "$commits"; then
    bump="major"
elif grep -Eq '^feat(\([^)]*\))?:' <<< "$commits"; then
    bump="minor"
elif grep -Eq '^(fix|perf)(\([^)]*\))?:' <<< "$commits"; then
    bump="patch"
else
    # 没有触发版本的改动（如纯 docs、chore），跳过 Beta 构建
    write_output skip true
    exit 0
fi

IFS=. read -r major minor patch <<< "$target_version"

case "$bump" in
    major)
        next_version="$((major + 1)).0.0"
        ;;
    minor)
        next_version="${major}.$((minor + 1)).0"
        ;;
    patch)
        next_version="${major}.${minor}.$((patch + 1))"
        ;;
esac

beta_tag_at_head="$(
    git tag --points-at HEAD |
        grep -E "^v${next_version//./\\.}-beta\.[0-9]+$" |
        sort -V |
        tail -n 1 || true
)"

if [[ -n "$beta_tag_at_head" ]]; then
    release_tag="$beta_tag_at_head"
else
    release_tag="v${next_version}-beta.${beta_number}"
fi

write_output skip false
write_output tag "$release_tag"
write_output marketing_version "$next_version"
