#!/bin/bash
# Developer / CI build script — not an end-user installer.
#
#   bash Sources/build.sh
#     → compile, sign with local "ClaudeBar Dev" cert (create if missing),
#       install to /Applications
#
#   CODESIGN_IDENTITY="-" bash Sources/build.sh
#     → force ad-hoc (CI default)
#
#   CLAUDEBAR_SKIP_INSTALL=1 bash Sources/build.sh
#     → compile only → .build/ClaudeBar.app (CI)
#
#   CLAUDEBAR_SKIP_INSTALL=1 CLAUDEBAR_PACKAGE=1 bash Sources/build.sh
#     → compile + release artifacts → .build/dist/*.dmg (+ .zip) + checksums
#
# End users install from GitHub Releases (DMG). See CONTRIBUTING.md.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES_DIR="$PROJECT_DIR/Sources/ClaudeBar"
WIDGET_DIR="$PROJECT_DIR/Sources/Widget"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="ClaudeBar"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

# Single canonical install location: /Applications. We no longer scatter
# copies onto ~/Desktop (which produced duplicate bundle IDs and confused
# LaunchServices / pluginkit widget registration).
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

VERSION_FILE="$PROJECT_DIR/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "Missing VERSION file at $VERSION_FILE" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "VERSION must be MAJOR.MINOR.PATCH, got: '$VERSION'" >&2
    exit 1
fi

MACOS_MIN="${MACOS_MIN:-15.0}"
MACOS_TARGET="arm64-apple-macos${MACOS_MIN}"

echo "=== Building $APP_NAME $VERSION (macOS ${MACOS_MIN}+) ==="

# --- Source coverage assertions ---
# Both targets are compiled by globbing `find … -name '*.swift'`, so a file
# that is missing, misnamed, or sitting in the wrong directory does not fail
# the build — it just silently is not in the binary (a whole feature can go
# missing without a single diagnostic). Assert the structural invariants that
# a glob cannot express.
require_file() {
    if [ ! -f "$1" ]; then
        echo "ERROR: expected source missing: $1" >&2
        exit 1
    fi
}
# The widget target compiles WidgetSnapshot.swift through a symlink into the
# app's Models directory; a broken link compiles *nothing* there and the
# widget would silently fail to decode every snapshot.
require_file "$SOURCES_DIR/Models/WidgetSnapshot.swift"
require_file "$SOURCES_DIR/Models/ProviderStore.swift"
require_file "$SOURCES_DIR/Theme/Theme.swift"
require_file "$WIDGET_DIR/WidgetViews.swift"
require_file "$WIDGET_DIR/WidgetProvider.swift"
if [ ! -e "$WIDGET_DIR/WidgetSnapshot.swift" ]; then
    echo "ERROR: $WIDGET_DIR/WidgetSnapshot.swift is a broken or missing symlink" >&2
    exit 1
fi
# The shared snapshot contract must be the SAME file on both sides, or the
# widget and the app drift apart with no compiler error to catch it.
if ! [ "$WIDGET_DIR/WidgetSnapshot.swift" -ef "$SOURCES_DIR/Models/WidgetSnapshot.swift" ]; then
    echo "ERROR: $WIDGET_DIR/WidgetSnapshot.swift no longer resolves to $SOURCES_DIR/Models/WidgetSnapshot.swift" >&2
    exit 1
fi

# Local builds use a stable self-signed identity so TCC (Screen Recording)
# survives rebuilds. CI / explicit "-" stay ad-hoc.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
elif [ -n "${CI:-}" ]; then
    SIGN_IDENTITY="-"
else
    SIGN_IDENTITY="$(bash "$PROJECT_DIR/Sources/ensure-dev-cert.sh")"
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Signing identity: ad-hoc"
else
    echo "Signing identity: $SIGN_IDENTITY"
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
        echo "ERROR: $SIGN_IDENTITY is not a trusted code-signing identity (CSSMERR_TP_NOT_TRUSTED)." >&2
        echo "TCC will treat the app as unsigned and ask for Screen Recording on every rebuild." >&2
        exit 1
    fi
fi

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$MACOS_DIR"
RESOURCES_DIR="$CONTENTS/Resources"
mkdir -p "$RESOURCES_DIR"
cp "$PROJECT_DIR/Sources/Licenses/Lucide.txt" "$RESOURCES_DIR/Lucide.txt"

# Copy app icon
ICONS_SOURCE="$PROJECT_DIR/Sources/AppIcon.icns"
if [ -f "$ICONS_SOURCE" ]; then
    cp "$ICONS_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
    echo "Icon copied to bundle"
fi

MENUBAR_ICON="$PROJECT_DIR/Sources/MenuBarIcon.png"
if [ -f "$MENUBAR_ICON" ]; then
    cp "$MENUBAR_ICON" "$RESOURCES_DIR/MenuBarIcon.png"
fi

# Privileged fan helper: tiny C binary, run via osascript admin prompt.
FANCTL_SRC="$PROJECT_DIR/Sources/fanctl/fanctl.c"
if [ -f "$FANCTL_SRC" ]; then
    FANCTL_OUT="$RESOURCES_DIR/claudebar-fanctl"
    clang -O2 -arch arm64 -arch x86_64 \
        -framework IOKit -framework CoreFoundation \
        -o "$FANCTL_OUT" "$FANCTL_SRC" 2>/dev/null \
    && echo "Fan helper built: $FANCTL_OUT"
fi

# mihomo core for the VPN module — clash-verge-rev style prebuild: auto-fetch
# the latest mihomo release into vendor/mihomo, skip when the local copy is
# already up to date. Set MIHOMO_SKIP_DOWNLOAD=1 to build without the core.
MIHOMO_DIR="$PROJECT_DIR/vendor/mihomo"
MIHOMO_BIN="$MIHOMO_DIR/mihomo"
MIHOMO_VERSION_FILE="$MIHOMO_DIR/.version"
if [ "${MIHOMO_SKIP_DOWNLOAD:-0}" != "1" ]; then
    MIHOMO_VERSION_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/version.txt"
    MIHOMO_URL_PREFIX="https://github.com/MetaCubeX/mihomo/releases/download"
    # curl honors https_proxy / HTTPS_PROXY env vars when set.
    MIHOMO_LATEST="$(curl -fsSL --connect-timeout 10 "$MIHOMO_VERSION_URL" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$MIHOMO_LATEST" ]; then
        # Offline or blocked: fall back to whatever is vendored / cached.
        MIHOMO_LATEST="$(cat "$MIHOMO_VERSION_FILE" 2>/dev/null || true)"
        if [ -z "$MIHOMO_LATEST" ]; then
            echo "WARN: cannot reach github.com for mihomo version; building without core update."
        fi
    fi
    if [ -n "$MIHOMO_LATEST" ] && [ ! -f "$MIHOMO_VERSION_FILE" -o "$(cat "$MIHOMO_VERSION_FILE" 2>/dev/null)" != "$MIHOMO_LATEST" -o ! -f "$MIHOMO_BIN" ]; then
        echo "Fetching mihomo core $MIHOMO_LATEST (darwin-arm64)…"
        mkdir -p "$MIHOMO_DIR"
        MIHOMO_ASSET="mihomo-darwin-arm64-$MIHOMO_LATEST"
        if curl -fSL --connect-timeout 15 -o "$MIHOMO_DIR/mihomo.gz" \
            "$MIHOMO_URL_PREFIX/v$MIHOMO_LATEST/$MIHOMO_ASSET.gz" 2>/dev/null \
           || curl -fSL --connect-timeout 15 -o "$MIHOMO_DIR/mihomo.gz" \
            "$MIHOMO_URL_PREFIX/$MIHOMO_LATEST/$MIHOMO_ASSET.gz" 2>/dev/null; then
            gunzip -f "$MIHOMO_DIR/mihomo.gz" && mv "$MIHOMO_DIR/mihomo" "$MIHOMO_BIN" \
                && chmod +x "$MIHOMO_BIN" \
                && echo "$MIHOMO_LATEST" > "$MIHOMO_VERSION_FILE" \
                && echo "mihomo core $MIHOMO_LATEST fetched."
        else
            echo "WARN: mihomo download failed; keeping existing core (if any)."
        fi
    fi
fi
MIHOMO_SRC="$MIHOMO_BIN"
if [ -f "$MIHOMO_SRC" ]; then
    cp "$MIHOMO_SRC" "$RESOURCES_DIR/mihomo-core"
    chmod +x "$RESOURCES_DIR/mihomo-core"
    # Strip quarantine from the vendored copy so Gatekeeper lets it run.
    xattr -c "$RESOURCES_DIR/mihomo-core" 2>/dev/null || true
    echo "mihomo core bundled: $RESOURCES_DIR/mihomo-core"
else
    echo "NOTE: no mihomo core available — VPN core will not be bundled."
fi

# Compile Swift sources
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
echo "Using SDK: $SDK_PATH"

swift_files=$(find "$SOURCES_DIR" -name "*.swift" | sort)
if [ -z "$swift_files" ]; then
    echo "ERROR: no app sources found under $SOURCES_DIR" >&2
    exit 1
fi

# -O + -whole-module-optimization: without any optimization flag swiftc
# defaults to -Onone, which leaves every layout witness thunk, value witness
# and cross-file call uninlined. The app is an always-resident menu-bar
# process whose SwiftUI layout path is the hot loop, so the 1.5x difference is
# measurable in the profile (see docs/technical/08-performance.md).
# All sources are passed in one invocation, so WMO is free here.
swiftc -O -whole-module-optimization \
    -o "$MACOS_DIR/$APP_NAME" \
    -sdk "$SDK_PATH" \
    -target "$MACOS_TARGET" \
    -framework Metal \
    -framework SwiftUI \
    -framework AppKit \
    -framework WidgetKit \
    -framework CryptoKit \
    -framework CoreServices \
    -framework IOKit \
    -framework Carbon \
    -framework ScreenCaptureKit \
    -framework CoreLocation \
    -framework CoreWLAN \
    -framework IOBluetooth \
    -framework ServiceManagement \
    -lsqlite3 \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -rpath -Xlinker "$SDK_PATH/System/Library/Frameworks" \
    $swift_files

# Drop local symbols from the shipped binary (16 MB → 7 MB). `-x` keeps the
# global/undefined symbols the dynamic linker needs. Must run before codesign.
strip -x "$MACOS_DIR/$APP_NAME" 2>/dev/null || true

echo "Binary created: $MACOS_DIR/$APP_NAME"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeBar</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.claudebar.app</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeBar</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MACOS_MIN}</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>区域截图需要屏幕录制权限，用于将选中区域复制到剪贴板。</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>用于在资源条中显示蓝牙开关状态。</string>
    <key>NSLocationUsageDescription</key>
    <string>用于显示当前 Wi-Fi 网络名称，不采集地理位置。</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>用于在连接卡片中显示当前 Wi-Fi 网络名称与信号强度。macOS 将 Wi-Fi 名称视为可用于定位的信息，因此读取它需要此授权；ClaudeBar 只读取名称与信号，不会定位。</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# === Widget Extension ===
echo "=== Building Widget ==="

APPEX_DIR="$CONTENTS/PlugIns/ClaudeBarWidget.appex"
APPEX_CONTENTS="$APPEX_DIR/Contents"
mkdir -p "$APPEX_CONTENTS/MacOS"

# Compile the widget directly into the appex (no intermediate binary in MacOS/,
# which previously left a stray ClaudeBarWidget binary alongside the main app
# executable and made codesign --deep sign an extra artifact).
widget_files=$(find "$WIDGET_DIR" -name "*.swift" | sort)
if [ -z "$widget_files" ]; then
    echo "ERROR: no widget sources found under $WIDGET_DIR" >&2
    exit 1
fi

swiftc -O -whole-module-optimization \
    -o "$APPEX_CONTENTS/MacOS/ClaudeBarWidget" \
    -module-name ClaudeBarWidget \
    -parse-as-library \
    -sdk "$SDK_PATH" \
    -target "$MACOS_TARGET" \
    -framework SwiftUI \
    -framework WidgetKit \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -application_extension \
    -Xlinker -e -Xlinker _NSExtensionMain \
    $widget_files

strip -x "$APPEX_CONTENTS/MacOS/ClaudeBarWidget" 2>/dev/null || true

echo "Widget binary: $APPEX_CONTENTS/MacOS/ClaudeBarWidget"

# Widget Info.plist (inside Contents/)
cat > "$APPEX_CONTENTS/Info.plist" << WPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.claudebar.app.widget</string>
    <key>CFBundleName</key>
    <string>ClaudeBarWidget</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeBar Widget</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeBarWidget</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MACOS_MIN}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
        <key>NSExtensionPrincipalClass</key>
        <string>ClaudeBarWidget.ClaudeBarWidget</string>
    </dict>
</dict>
</plist>
WPLIST

# --- Entitlements ---
# Both targets declare the same App Group so the non-sandboxed main app and the
# sandboxed widget agree on the shared container. macOS 26 registers widget
# extensions only when the app group is consistent across host + extension.
ENT_DIR="$PROJECT_DIR/.build/entitlements"
mkdir -p "$ENT_DIR"

# Widget appex: sandbox ON + app group + network.
cat > "$ENT_DIR/widget.plist" << 'WENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>com.claudebar.app.widget</string>
    </array>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
WENT

# Main app: sandbox OFF (needs ~/.claude) + app group + network + files.
cat > "$ENT_DIR/app.plist" << 'AENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>com.claudebar.app.widget</string>
    </array>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.personal-information.location</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
AENT

# --- Code-sign ---
# Clear ALL extended attributes (FinderInfo, provenance, quarantine) BEFORE
# signing, top to bottom. Leaving FinderInfo on the .appex made
# `codesign --deep --strict` fail with "resource fork / Finder information
# or similar detritus not allowed" and can prevent the widget from loading.
echo "=== Code-signing ==="
xattr -cr "$APP_BUNDLE"

# Sign bottom-up (no --deep): appex binary -> appex bundle -> main binary.
# The main binary is signed explicitly so its entitlements are embedded
# before the bundle wrapper is sealed.
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENT_DIR/widget.plist" \
    "$APPEX_DIR/Contents/MacOS/ClaudeBarWidget"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENT_DIR/widget.plist" \
    "$APPEX_DIR"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENT_DIR/app.plist" \
    "$MACOS_DIR/$APP_NAME"
# IMPORTANT: pass --entitlements on the bundle wrapper too. Signing a bundle
# re-seals the main executable; without --entitlements here codesign strips
# the entitlements that were just embedded, leaving the main app with none.
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENT_DIR/app.plist" \
    "$APP_BUNDLE"
echo "Signed OK ($SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "Screen Recording TCC is bound to this certificate — rebuilds should not ask again."
fi

# --- Release artifacts (DMG + zip) for GitHub Releases ---
if [ "${CLAUDEBAR_PACKAGE:-}" = "1" ]; then
    DIST_DIR="$BUILD_DIR/dist"
    mkdir -p "$DIST_DIR"
    ARTIFACT_BASE="ClaudeBar-${VERSION}-macOS-arm64"

    ZIP_NAME="${ARTIFACT_BASE}.zip"
    ZIP_PATH="$DIST_DIR/$ZIP_NAME"
    DMG_NAME="${ARTIFACT_BASE}.dmg"
    DMG_PATH="$DIST_DIR/$DMG_NAME"
    DMG_STAGING="$BUILD_DIR/dmg-staging"

    rm -f "$ZIP_PATH" "$ZIP_PATH.sha256" "$DMG_PATH" "$DMG_PATH.sha256"
    rm -rf "$DMG_STAGING"

    echo "=== Packaging ${DMG_NAME} ==="
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_BUNDLE" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"
    hdiutil create -volname "ClaudeBar" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
    rm -rf "$DMG_STAGING"
    (cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256")

    echo "=== Packaging ${ZIP_NAME} ==="
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    (cd "$DIST_DIR" && shasum -a 256 "$ZIP_NAME" | tee "$ZIP_NAME.sha256")

    echo "Release artifacts:"
    ls -lh "$DMG_PATH" "$ZIP_PATH"
fi

# --- Install to /Applications (single canonical copy) ---
if [ "${CLAUDEBAR_SKIP_INSTALL:-}" = "1" ]; then
    echo "=== Skipping install (CLAUDEBAR_SKIP_INSTALL=1) ==="
    echo "Build cache: $APP_BUNDLE"
    if [ "${CLAUDEBAR_PACKAGE:-}" = "1" ]; then
        echo "Package:     $BUILD_DIR/dist/ClaudeBar-${VERSION}-macOS-arm64.dmg"
        echo "             $BUILD_DIR/dist/ClaudeBar-${VERSION}-macOS-arm64.zip"
    fi
else
    echo "=== Installing ==="
    pkill -9 "$APP_NAME" 2>/dev/null || true
    rm -rf "$INSTALLED_APP"
    cp -R "$APP_BUNDLE" "$INSTALLED_APP"
    # The cp re-introduces xattrs; strip them again post-copy so the installed
    # bundle stays clean (matches the signed state).
    xattr -cr "$INSTALLED_APP"

    # Force LaunchServices + pluginkit to re-index the widget extension and mark
    # it enabled. Without this the gallery can lag behind a rebuild by one launch.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$INSTALLED_APP"
    pluginkit -e use -i com.claudebar.app.widget 2>/dev/null || true
    killall widgetkitd 2>/dev/null || true

    echo "=== Build complete ==="
    echo "Installed:   $INSTALLED_APP"
    echo "Build cache:  $APP_BUNDLE"
    echo ""
    echo "Run with: open $INSTALLED_APP"
fi
