#!/bin/bash
# Builds DiffCode.app.
#
#   Scripts/build-app.sh                     the direct download, ad-hoc signed, into ./dist
#   Scripts/build-app.sh --install           …and copy it to /Applications, linking the `dif` command
#   EDITION=appstore Scripts/build-app.sh    the sandboxed Mac App Store edition (no Sparkle, no terminal), into ./dist/appstore
#   ARCH=x86_64 Scripts/build-app.sh         for Intel Macs only (ARCH=arm64: Apple Silicon only; unset: this Mac's)
#   UNIVERSAL=1 Scripts/build-app.sh         an arm64 + x86_64 binary
#   STRIP=0 Scripts/build-app.sh             keep the symbols in the binary (otherwise they go to DiffCode.app.dSYM)
#
# The release scripts (release/macos, release/appstore) call it with:
#   SIGN_IDENTITY="Developer ID Application: …"   sign with that certificate, inside out, never with --deep
#   HARDENED_RUNTIME=1                            hardened runtime and a secure timestamp (notarization needs both)
#   ENTITLEMENTS=path                             the app's entitlements ($(PRODUCT_BUNDLE_IDENTIFIER) is expanded)
#   PROVISIONING_PROFILE=path                     embedded as Contents/embedded.provisionprofile
#   OUTPUT_DIR=path                               where DiffCode.app goes
#
# Version and build number come from release/version.env. The direct download looks for updates only when
# SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY are set, from the environment or release/macos/AppInfo.local.env.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Values from a KEY=value file, without overriding what the environment already set.
load_defaults() {
    [ -f "$1" ] || return 0
    local line key
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            [ -z "${!key+x}" ] && export "$key=${BASH_REMATCH[2]}"
        fi
    done < "$1"
}

EDITION="${EDITION:-direct}"
case "$EDITION" in
    direct) PRODUCT="Dif"; DEFAULT_OUTPUT="$ROOT/dist" ;;
    appstore) PRODUCT="DifAppStore"; DEFAULT_OUTPUT="$ROOT/dist/appstore" ;;
    *) echo "error: EDITION must be direct or appstore" >&2; exit 1 ;;
esac
load_defaults "$ROOT/release/version.env"
[ "$EDITION" = direct ] && load_defaults "$ROOT/release/macos/AppInfo.local.env"

NAME="DiffCode"
BUNDLE_ID="com.nanshanbei.DiffCode"
VERSION="${VERSION:-${MARKETING_VERSION:-0.1.0}}"
BUILD="${BUILD_NUMBER:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT}"
APP="$OUTPUT_DIR/$NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
HARDENED_RUNTIME="${HARDENED_RUNTIME:-0}"
ENTITLEMENTS="${ENTITLEMENTS:-}"
# The App Store edition is nothing without its sandbox.
if [ "$EDITION" = appstore ] && [ -z "$ENTITLEMENTS" ]; then
    ENTITLEMENTS="$ROOT/release/appstore/DiffCode.entitlements"
fi
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
FEED_URL=""
PUBLIC_KEY=""
if [ "$EDITION" = direct ]; then
    FEED_URL="${SPARKLE_FEED_URL:-}"
    PUBLIC_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
fi

if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --product "$PRODUCT" --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c release --product "$PRODUCT" --arch arm64 --arch x86_64 --show-bin-path)"
elif [ -n "${ARCH:-}" ]; then
    case "$ARCH" in
        arm64|x86_64) ;;
        *) echo "error: ARCH must be arm64 or x86_64" >&2; exit 1 ;;
    esac
    swift build -c release --product "$PRODUCT" --arch "$ARCH"
    BIN_DIR="$(swift build -c release --product "$PRODUCT" --arch "$ARCH" --show-bin-path)"
else
    swift build -c release --product "$PRODUCT"
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$NAME"
# Back-deployment libraries come from the system; the toolchain's own folder means nothing on another Mac.
while IFS= read -r rpath; do
    case "$rpath" in
        /usr/lib/swift|@loader_path|@executable_path/*) ;;
        *) install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/$NAME" ;;
    esac
# (A universal binary lists each path once per architecture; one delete removes it from all of them.)
done < <(otool -l "$APP/Contents/MacOS/$NAME" | awk '/LC_RPATH/ { getline; getline; print $2 }' | sort -u)
# Symbols stay beside the app, not in it: the dSYM turns crash reports back into function names, and the stripped
# binary is about half the size (7.3 → 3.4 MB on arm64). STRIP=0 keeps them in, e.g. to profile a local build.
DSYM="$OUTPUT_DIR/$NAME.app.dSYM"
rm -rf "$DSYM"
if [ "${STRIP:-1}" = "1" ]; then
    dsymutil "$APP/Contents/MacOS/$NAME" -o "$DSYM" >/dev/null || echo "warning: no dSYM for $PRODUCT; crash reports will show addresses only" >&2
    strip -rSTx "$APP/Contents/MacOS/$NAME"
fi
if [ "$EDITION" = direct ]; then
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
fi
# Third-party notices: the MIT licenses of SwiftTerm and Sparkle ask for their text to go with every copy. Taken from
# the resolved packages, so they always match the versions linked in; the About panel shows them (Acknowledgements).
# No license, no build: an app without them must not ship.
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
copy_license() {
    [ -s "$2" ] || { echo "error: the license of $1 is missing ($2); run 'swift package resolve'" >&2; exit 1; }
    cp "$2" "$LICENSES/$1.txt"
}
copy_license SwiftTerm "$ROOT/.build/checkouts/SwiftTerm/LICENSE"
if [ "$EDITION" = direct ]; then
    copy_license Sparkle "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE"
fi
# The `dif` command links into /usr/local/bin, which the App Store edition can neither do nor offer.
if [ "$EDITION" = direct ]; then
    cp "$ROOT/Scripts/dif" "$APP/Contents/Resources/dif"
    chmod +x "$APP/Contents/Resources/dif"
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# A smaller heap for the app's own process (see AppEnvironment.ownProcessOnlyKeys; git and the terminal do not get
# it): measured on a 4,800-file repository, 30 instead of 38 MB at launch and 49 instead of 74 MB after browsing the
# Log, the graph and a search, for about 2 ms more to open a 7,700-line diff. LaunchServices applies it, so it holds
# for Finder, the Dock, `open` and the `dif` command, not for the binary run directly.
EXTRA_KEYS="    <key>LSEnvironment</key><dict><key>MallocSpaceEfficient</key><string>1</string></dict>
"
# Keys that only one edition has.
if [ -n "$FEED_URL" ] && [ -n "$PUBLIC_KEY" ]; then
    EXTRA_KEYS+="    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
"
fi
if [ "$EDITION" = appstore ]; then
    # What Xcode records about the build; App Store Connect checks the SDK and toolchain from these.
    SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
    SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
    XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode/ { print $2 }')"
    XCODE_BUILD="$(xcodebuild -version | awk '/^Build version/ { print $3 }')"
    XCODE_NUMBER="$(printf '%s' "$XCODE_VERSION" | awk -F. '{ printf "%02d%d%d", $1, $2, $3 }')"
    EXTRA_KEYS+="    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>DTPlatformVersion</key><string>$SDK_VERSION</string>
    <key>DTPlatformBuild</key><string>$SDK_BUILD</string>
    <key>DTSDKName</key><string>macosx$SDK_VERSION</string>
    <key>DTSDKBuild</key><string>$SDK_BUILD</string>
    <key>DTXcode</key><string>$XCODE_NUMBER</string>
    <key>DTXcodeBuild</key><string>$XCODE_BUILD</string>
    <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
    <key>BuildMachineOSBuild</key><string>$(sw_vers -buildVersion)</string>
"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) DiffCode</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
$EXTRA_KEYS    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>diffcode</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

if [ -n "$PROVISIONING_PROFILE" ]; then
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

# Signing, inside out. Never --deep: it would sign Sparkle's helpers with the app's entitlements.
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$HARDENED_RUNTIME" = "1" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
if [ "$EDITION" = direct ]; then
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign "${SIGN_ARGS[@]}" "$SPARKLE/XPCServices/Installer.xpc"
    codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
    codesign "${SIGN_ARGS[@]}" "$SPARKLE/Autoupdate"
    codesign "${SIGN_ARGS[@]}" "$SPARKLE/Updater.app"
    codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
fi
APP_SIGN_ARGS=("${SIGN_ARGS[@]}")
if [ -n "$ENTITLEMENTS" ]; then
    EXPANDED="$(mktemp -t dif-entitlements)"
    sed "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" "$ENTITLEMENTS" > "$EXPANDED"
    APP_SIGN_ARGS+=(--entitlements "$EXPANDED")
fi
codesign "${APP_SIGN_ARGS[@]}" "$APP"
[ -n "$ENTITLEMENTS" ] && rm -f "$EXPANDED"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($EDITION, $VERSION ($BUILD), $(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
    [ "$EDITION" = direct ] || { echo "error: --install is for the direct download" >&2; exit 1; }
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" "/Applications/$NAME.app"
    echo "Installed /Applications/$NAME.app"
    # The app was called Dif before; a copy under the old name has the same identifier and would compete with this one.
    [ -d "/Applications/Dif.app" ] && echo "note: /Applications/Dif.app is the same app under its old name; delete it."
    BIN_DIR="${DIF_BIN_DIR:-/usr/local/bin}"
    if [ -w "$BIN_DIR" ] || mkdir -p "$BIN_DIR" 2>/dev/null; then
        ln -sf "/Applications/$NAME.app/Contents/Resources/dif" "$BIN_DIR/dif"
        echo "Linked $BIN_DIR/dif"
    else
        echo "To get the \`dif\` command:  sudo ln -sf /Applications/$NAME.app/Contents/Resources/dif $BIN_DIR/dif"
    fi
fi
