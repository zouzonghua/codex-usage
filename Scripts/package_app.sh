#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_configuration="${BUILD_CONFIGURATION:-release}"
build_number="${BUILD_NUMBER:-1}"
artifact_label="${ARTIFACT_LABEL:-$build_number}"
marketing_version="${MARKETING_VERSION:-}"
bin_dir="${BIN_DIR:-$(swift build -c "$build_configuration" --show-bin-path)}"
dist_dir="${DIST_DIR:-$project_root/dist}"
app_dir="$dist_dir/CodexUsage.app"
dmg_staging_dir="$dist_dir/CodexUsage-dmg"
dmg_path="$dist_dir/CodexUsage-$artifact_label.dmg"

if [[ ! "$artifact_label" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid artifact label: $artifact_label" >&2
    exit 1
fi

if [[ -n "$marketing_version" && ! "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid marketing version: $marketing_version" >&2
    exit 1
fi

rm -rf "$app_dir" "$dmg_staging_dir" "$dmg_path"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CodexUsage" "$app_dir/Contents/MacOS/CodexUsage"
cp "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
resource_bundle="$bin_dir/CodexUsage_CodexUsage.bundle"
if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$app_dir/Contents/Resources/"
fi
xcrun actool \
    "$project_root/Resources/Assets.xcassets" \
    --compile "$app_dir/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$dist_dir/AppIcon-Info.plist" \
    >/dev/null
/usr/libexec/PlistBuddy -c "Merge $dist_dir/AppIcon-Info.plist" "$app_dir/Contents/Info.plist"
rm -f "$dist_dir/AppIcon-Info.plist"

if [[ -n "$marketing_version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$app_dir/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir" >/dev/null
codesign --verify --deep --strict --verbose=1 "$app_dir" >/dev/null

mkdir -p "$dmg_staging_dir"
ditto "$app_dir" "$dmg_staging_dir/CodexUsage.app"
ln -s /Applications "$dmg_staging_dir/Applications"
/usr/bin/hdiutil create \
    -volname "CodexUsage" \
    -srcfolder "$dmg_staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path" >/dev/null
rm -rf "$dmg_staging_dir"

echo "Created $dmg_path"
