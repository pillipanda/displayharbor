#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
cd "$project_dir"

app_dir="$project_dir/dist/DisplayHarbor.app"
app_binary="$app_dir/Contents/MacOS/DisplayHarbor"
running_pid="$(pgrep -f "^${app_binary}$" | head -n 1 || true)"
if [[ -n "$running_pid" ]]; then
    echo "Stopping running DisplayHarbor ($running_pid)"
    kill "$running_pid"
    for _ in {1..100}; do
        kill -0 "$running_pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$running_pid" 2>/dev/null; then
        echo "DisplayHarbor did not stop gracefully; sending SIGKILL" >&2
        kill -KILL "$running_pid"
    fi
fi

swift build -c release

swift "$project_dir/Scripts/generate-app-icon.swift" "$project_dir/Resources/AppIcon.icns"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$project_dir/.build/arm64-apple-macosx/release/DisplayHarbor" "$app_dir/Contents/MacOS/DisplayHarbor"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
app_version="${DISPLAYHARBOR_VERSION:-0.1.1}"
app_version="${app_version#v}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${app_version//./}" "$app_dir/Contents/Info.plist"
set_plist_if_configured() {
    local key="$1"
    local value="$2"
    if [[ -n "$value" ]]; then
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$app_dir/Contents/Info.plist"
    fi
}
set_plist_if_configured MBDLicenseAppID "${DISPLAYHARBOR_LICENSE_APP_ID:-}"
set_plist_if_configured MBDLicensePublicKey "${DISPLAYHARBOR_LICENSE_PUBLIC_KEY:-}"
set_plist_if_configured MBDLicenseAPIBaseURL "${DISPLAYHARBOR_LICENSE_API_BASE_URL:-}"
set_plist_if_configured MBDLicensePurchaseURL "${DISPLAYHARBOR_LICENSE_PURCHASE_URL:-}"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp -R "$project_dir/Resources/"*.lproj "$app_dir/Contents/Resources/"

sparkle_framework="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
    sparkle_framework="$(find "$project_dir/.build" -type d -path '*/Sparkle.framework' -print -quit 2>/dev/null)"
fi
if [[ -z "$sparkle_framework" || ! -d "$sparkle_framework" ]]; then
    echo "Error: Sparkle.framework was not found. Run swift package resolve first." >&2
    exit 1
fi
mkdir -p "$app_dir/Contents/Frameworks"
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$app_binary" | grep -q '@loader_path/../Frameworks'; then
    install_name_tool -add_rpath '@loader_path/../Frameworks' "$app_binary"
fi

signing_identity="${DISPLAYHARBOR_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*\"\(Developer ID Application:.*\)\"/\1/p' \
        | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
    echo "Error: Developer ID Application identity not found." >&2
    exit 1
fi

codesign --force --deep --timestamp --options runtime --sign "$signing_identity" "$app_dir" >/dev/null
echo "Signed with $signing_identity"
echo "Built $app_dir"
