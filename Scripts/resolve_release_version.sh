#!/bin/bash
set -euo pipefail

channel="${1:-}"
beta_number="${2:-}"

if [[ "$channel" != "beta" && "$channel" != "stable" ]]; then
    echo "Usage: $0 <beta|stable> [beta-number]" >&2
    exit 1
fi

if [[ "$channel" == "beta" && ! "$beta_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Beta releases require a positive numeric beta number." >&2
    exit 1
fi

initial_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

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

stable_tag_at_head="$(
    git tag --points-at HEAD |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
        sort -V |
        tail -n 1 || true
)"

if [[ "$channel" == "stable" && -n "$stable_tag_at_head" ]]; then
    write_output skip false
    write_output tag "$stable_tag_at_head"
    write_output marketing_version "${stable_tag_at_head#v}"
    exit 0
fi

if [[ "$channel" == "stable" ]]; then
    dev_merge_parent="$(git rev-parse --verify HEAD^2 2>/dev/null || true)"
    if [[ -z "$dev_merge_parent" ]]; then
        echo "Stable releases require merging dev into main with a merge commit." >&2
        exit 1
    fi

    beta_tag="$(
        git tag --points-at "$dev_merge_parent" |
            grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$' |
            sort -V |
            tail -n 1 || true
    )"
    if [[ -z "$beta_tag" ]]; then
        echo "The merged dev commit does not have a Beta tag." >&2
        exit 1
    fi

    target_version="${beta_tag#v}"
    target_version="${target_version%-beta.*}"
    write_output skip false
    write_output tag "v${target_version}"
    write_output marketing_version "$target_version"
    exit 0
fi

latest_stable_tag="$(
    git tag |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
        sort -V |
        tail -n 1 || true
)"

if [[ -z "$latest_stable_tag" ]]; then
    target_version="$initial_version"
else
    release_base=""
    if git merge-base --is-ancestor "$latest_stable_tag" HEAD; then
        release_base="$latest_stable_tag"
    else
        released_dev_parent="$(git rev-parse --verify "${latest_stable_tag}^2" 2>/dev/null || true)"
        if [[ -n "$released_dev_parent" ]] && git merge-base --is-ancestor "$released_dev_parent" HEAD; then
            release_base="$released_dev_parent"
        fi
    fi

    if [[ -z "$release_base" ]]; then
        echo "Latest stable release does not contain the current dev history." >&2
        exit 1
    fi

    commits="$(git log "${release_base}..HEAD" --format='%s%n%b')"

    if grep -Eq '^[a-zA-Z]+(\([^)]*\))?!:|^BREAKING[ -]CHANGE:' <<< "$commits"; then
        bump="major"
    elif grep -Eq '^feat(\([^)]*\))?:' <<< "$commits"; then
        bump="minor"
    elif grep -Eq '^(fix|perf)(\([^)]*\))?:' <<< "$commits"; then
        bump="patch"
    else
        write_output skip true
        exit 0
    fi

    version="${latest_stable_tag#v}"
    IFS=. read -r major minor patch <<< "$version"

    case "$bump" in
        major)
            target_version="$((major + 1)).0.0"
            ;;
        minor)
            target_version="${major}.$((minor + 1)).0"
            ;;
        patch)
            target_version="${major}.${minor}.$((patch + 1))"
            ;;
    esac
fi

if [[ "$channel" == "stable" ]]; then
    release_tag="v${target_version}"
else
    beta_tag_at_head="$(
        git tag --points-at HEAD |
            grep -E "^v${target_version//./\\.}-beta\.[0-9]+$" |
            sort -V |
            tail -n 1 || true
    )"

    if [[ -n "$beta_tag_at_head" ]]; then
        release_tag="$beta_tag_at_head"
    else
        release_tag="v${target_version}-beta.${beta_number}"
    fi
fi

write_output skip false
write_output tag "$release_tag"
write_output marketing_version "$target_version"
