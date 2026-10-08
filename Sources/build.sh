#!/bin/bash
# Safe default: development build only. See docs/DEVELOPMENT.md.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/Sources/build-config.sh"
SOURCES_DIR="$PROJECT_DIR/Sources/ClaudeBar"
WIDGET_DIR="$PROJECT_DIR/Sources/Widget"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

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

echo "=== Building $APP_NAME $VERSION [$CLAUDEBAR_CHANNEL] (macOS ${MACOS_MIN}+) ==="
mkdir -p "$BUILD_DIR"
BUILD_LOCK="$BUILD_DIR/.build-lock"
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    echo "Another $CLAUDEBAR_CHANNEL build is active. If it crashed, remove $BUILD_LOCK." >&2
    exit 1
fi
trap 'rmdir "$BUILD_LOCK"' EXIT

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
# The widget names CC / Codex with the bundled marks; a missing BrandAssets
# directory is a blank tile in the appex rather than a build error.
require_file "$PROJECT_DIR/Sources/BrandAssets/openai-dark.png"
# The app's own mark, for the 第三方 tally in the usage legend. Derived from the
# app icon by Tools/make-claudebar-mark.py; a missing pair draws the fallback
# glyph rather than failing the build, which is why it is guarded here.
require_file "$PROJECT_DIR/Sources/BrandAssets/claudebar-light.png"
# The detailed internal illustration is bundled for offline use.
require_file "$SOURCES_DIR/Resources/macbook-internals-illustration.png"
# The packed VPN core (see the mihomo block below). Committed so a release
# build does not re-run LZMA over 54 MB, and so the decoder has a fixture.
require_file "$SOURCES_DIR/Resources/mihomo-core.xz"
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
# survives rebuilds. **Both channels**, not just dev: the release app was ad-hoc
# signed and an ad-hoc signature has no certificate to identify it by, so its
# designated requirement degrades to `cdhash H"..."` — the hash of the whole
# binary. Every rebuild therefore landed in TCC as a brand-new app and re-asked
# for Screen Recording, which made the screenshot tool unusable for anyone
# building locally. Only CI and an explicit CODESIGN_IDENTITY stay ad-hoc; a
# Developer ID, when one is configured, is passed through the same variable.
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

# A no-change build reuses the signed bundle, but always verifies it before use.
BUILD_FINGERPRINT="$(python3 "$PROJECT_DIR/Tools/build-cache.py" fingerprint "$SIGN_IDENTITY" "$MACOS_TARGET" "${SWIFT_FLAGS[*]}")"
STAMP_FILE="$BUILD_DIR/build.fingerprint"
if [ "${CLAUDEBAR_FORCE_REBUILD:-0}" != 1 ] && [ "${MIHOMO_UPDATE:-0}" != 1 ] \
   && [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$BUILD_FINGERPRINT" ] \
   && python3 -E -s "$PROJECT_DIR/Tools/check-bundle.py" "$APP_BUNDLE" "$CLAUDEBAR_CHANNEL"; then
    echo "=== Up to date: reusing verified $APP_NAME ==="
else
# Clean previous build
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$MACOS_DIR"
RESOURCES_DIR="$CONTENTS/Resources"
mkdir -p "$RESOURCES_DIR"
cp "$PROJECT_DIR/Sources/Licenses/Lucide.txt" "$RESOURCES_DIR/Lucide.txt"
# The icons the app draws, and the licence that covers them. The directory's
# README is *not* copied: it is maintainer notes for the LobeHub pin (provenance,
# the 3:1 ink floor, which asset came from which URL), and `cp -R` shipped it to
# every user. It stays in the repo, where the next person to add an asset reads it.
mkdir -p "$RESOURCES_DIR/ProviderIcons"
# The licence rides on the same copy as the marks it covers, so it is guarded
# rather than swallowed: an unguarded glob here exits 1 when any one pattern
# matches nothing (`*.ico` today) and `|| true` would hide a *missing licence*
# as well as the glob it was written for.
for icon in "$PROJECT_DIR/Sources/ProviderIcons"/*.png "$PROJECT_DIR/Sources/ProviderIcons"/*.ico; do
    [ -e "$icon" ] || continue
    cp "$icon" "$RESOURCES_DIR/ProviderIcons/"
done
require_file "$PROJECT_DIR/Sources/ProviderIcons/LICENSE-LobeHub.txt"
cp "$PROJECT_DIR/Sources/ProviderIcons/LICENSE-LobeHub.txt" "$RESOURCES_DIR/ProviderIcons/"
# Normalised CC / Codex tile glyphs for ProductBrandMark; generated by
# Tools/gen-brand-marks.py from the ProviderIcons above.
cp -R "$PROJECT_DIR/Sources/BrandAssets" "$RESOURCES_DIR/BrandAssets"
# The greeting's selectable script faces (SIL OFL 1.1 / Apache 2.0), each with
# its licence beside it; loaded by GreetingScript from Resources/Fonts.
mkdir -p "$RESOURCES_DIR/Fonts"
cp -R "$PROJECT_DIR/Sources/Fonts/." "$RESOURCES_DIR/Fonts/"
# Offline internal illustration and its provenance.
cp "$SOURCES_DIR/Resources/macbook-internals-illustration.png" "$RESOURCES_DIR/"
cp "$SOURCES_DIR/Resources/ASSET-LICENSES.md" "$RESOURCES_DIR/"

# Copy app icon
ICONS_SOURCE="$PROJECT_DIR/Sources/AppIcon.icns"
if [ "$CLAUDEBAR_CHANNEL" = dev ]; then ICONS_SOURCE="$PROJECT_DIR/Sources/AppIcon-Dev.icns"; fi
require_file "$ICONS_SOURCE"
if [ -f "$ICONS_SOURCE" ]; then
    cp "$ICONS_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
    echo "Icon copied to bundle"
fi

# Battery controller: fail the build if the required safety monitor cannot compile.
BATTERYCTL_OUT="$RESOURCES_DIR/claudebar-batteryctl"
clang -Wall -Wextra -Werror -O2 -arch arm64 -arch x86_64 \
    -framework IOKit -framework CoreFoundation \
    "$PROJECT_DIR/Sources/batteryctl/batteryctl.c" -o "$BATTERYCTL_OUT"

# Privileged fan helper: tiny C binary, run via osascript admin prompt.
FANCTL_SRC="$PROJECT_DIR/Sources/fanctl/fanctl.c"
if [ -f "$FANCTL_SRC" ]; then
    FANCTL_OUT="$RESOURCES_DIR/claudebar-fanctl"
    clang -O2 -arch arm64 -arch x86_64 \
        -framework IOKit -framework CoreFoundation \
        -o "$FANCTL_OUT" "$FANCTL_SRC"
    echo "Fan helper built: $FANCTL_OUT"
fi

# Use the committed, versioned archive by default (offline and reproducible).
# MIHOMO_UPDATE=1 explicitly opts into fetching a newer core; commit both files.
MIHOMO_DIR="$PROJECT_DIR/vendor/mihomo"
MIHOMO_BIN="$MIHOMO_DIR/mihomo"
MIHOMO_VERSION_FILE="$MIHOMO_DIR/.version"
if [ "${MIHOMO_UPDATE:-0}" = "1" ] && [ "${MIHOMO_SKIP_DOWNLOAD:-0}" != "1" ]; then
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
            gunzip -f "$MIHOMO_DIR/mihomo.gz" \
                && chmod +x "$MIHOMO_BIN" \
                && echo "$MIHOMO_LATEST" > "$MIHOMO_VERSION_FILE" \
                && echo "mihomo core $MIHOMO_LATEST fetched."
        else
            echo "WARN: mihomo download failed; keeping existing core (if any)."
        fi
    fi
fi
MIHOMO_SRC="$MIHOMO_BIN"
MIHOMO_VERSION="$(cat "$MIHOMO_VERSION_FILE" 2>/dev/null || true)"
if [ "${MIHOMO_UPDATE:-0}" != "1" ]; then
    cp "$SOURCES_DIR/Resources/mihomo-core.xz" "$RESOURCES_DIR/mihomo-core.xz"
    echo "Bundled pinned mihomo archive ($(cat "$SOURCES_DIR/Resources/mihomo-core.version"))"
elif [ -f "$MIHOMO_SRC" ]; then
    # Ship the core as an `.xz` — the same archive that is committed at
    # `Sources/ClaudeBar/Resources/mihomo-core.xz`, which is what lets a release
    # build pack it in 17 s instead of re-running LZMA over 54 MB.
    #
    # The numbers behind that: raw the binary is 54 MB that deflate cannot touch
    # (Go's own tables are already dense, so the GitHub release `.zip` carries
    # 20 MB of it), and `.xz` brings the same bytes to 13 MB. `XZArchive`
    # unpacks it in-app in 0.6 s on first run. It is the single largest thing the
    # app ships, so this is most of the download.
    #
    # Reusing the archive is safe because the packed size travels with the
    # version: when the vendored binary stops matching what was packed, the
    # archived copy is stale and gets rebuilt here rather than shipped as the
    # wrong kernel. `xz` is only needed for that rebuild.
    MIHOMO_XZ="$RESOURCES_DIR/mihomo-core.xz"
    ARCHIVED="$SOURCES_DIR/Resources/mihomo-core.xz"
    ARCHIVE_VERSION_FILE="$SOURCES_DIR/Resources/mihomo-core.version"
    ARCHIVE_VERSION="$(cat "$ARCHIVE_VERSION_FILE" 2>/dev/null || true)"
    if [ -f "$ARCHIVED" ] && [ -n "$MIHOMO_VERSION" ] && [ "$ARCHIVE_VERSION" = "$MIHOMO_VERSION" ]; then
        cp "$ARCHIVED" "$MIHOMO_XZ"
        echo "mihomo core bundled: $MIHOMO_XZ (reusing the archive for $MIHOMO_VERSION, $(du -h "$MIHOMO_XZ" | cut -f1))"
    elif command -v xz >/dev/null 2>&1 \
       && xz -9 --lzma2=dict=16MiB -T0 -c "$MIHOMO_SRC" > "$MIHOMO_XZ" 2>/dev/null; then
        cp "$MIHOMO_XZ" "$ARCHIVED"
        printf '%s\n' "$MIHOMO_VERSION" > "$ARCHIVE_VERSION_FILE"
        echo "mihomo core packed: $ARCHIVED ($MIHOMO_VERSION, $(du -h "$MIHOMO_XZ" | cut -f1)) — commit it"
    else
        # Neither the archive nor an `xz` to build one: ship the binary raw, which
        # the same reader copies verbatim. A 54 MB bundle is worse than a 13 MB
        # one, but far better than no VPN core.
        rm -f "$MIHOMO_XZ"
        cp "$MIHOMO_SRC" "$RESOURCES_DIR/mihomo-core"
        chmod +x "$RESOURCES_DIR/mihomo-core"
        echo "NOTE: no archived core and no xz — bundling the raw core ($(du -h "$RESOURCES_DIR/mihomo-core" | cut -f1))"
    fi
    # Strip quarantine so Gatekeeper lets the unpacked copy run.
    xattr -c "$MIHOMO_XZ" "$RESOURCES_DIR/mihomo-core" 2>/dev/null || true
else
    cp "$SOURCES_DIR/Resources/mihomo-core.xz" "$RESOURCES_DIR/mihomo-core.xz"
    echo "Bundled pinned mihomo archive ($(cat "$SOURCES_DIR/Resources/mihomo-core.version"))"
fi

# Compile Swift sources
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
echo "Using SDK: $SDK_PATH"

swift_files=()
while IFS= read -r file; do swift_files+=("$file"); done < <(find "$SOURCES_DIR" -name "*.swift" | sort)
if [ "${#swift_files[@]}" = 0 ]; then
    echo "ERROR: no app sources found under $SOURCES_DIR" >&2
    exit 1
fi

# Development uses per-file optimization plus the Swift driver's dependency graph.
# Release keeps WMO. Object/dependency caches survive bundle reconstruction.
APP_MAP_FLAGS=()
if [ "$CLAUDEBAR_CHANNEL" = dev ]; then
    APP_MAP="$(python3 "$PROJECT_DIR/Tools/build-cache.py" filemap "$BUILD_DIR/objects/app" "$PROJECT_DIR/Sources/Shared/BuildChannel.swift" "$PROJECT_DIR/Sources/Shared/CLISnapshot.swift" "$PROJECT_DIR/Sources/Shared/CLIControl.swift" "$PROJECT_DIR/Sources/Shared/AppPresentation.swift" "${swift_files[@]}")"
    APP_MAP_FLAGS=(-emit-executable -emit-module-path "$BUILD_DIR/objects/app/$APP_EXECUTABLE.swiftmodule" -output-file-map "$APP_MAP")
fi
swiftc "${SWIFT_FLAGS[@]}" ${APP_MAP_FLAGS[@]+"${APP_MAP_FLAGS[@]}"} \
    -o "$MACOS_DIR/$APP_EXECUTABLE" \
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
    "$PROJECT_DIR/Sources/Shared/BuildChannel.swift" \
    "$PROJECT_DIR/Sources/Shared/CLISnapshot.swift" "$PROJECT_DIR/Sources/Shared/CLIControl.swift" "$PROJECT_DIR/Sources/Shared/AppPresentation.swift" \
    "${swift_files[@]}"

# Drop local symbols from the shipped binary (16 MB → 7 MB). `-x` keeps the
# global/undefined symbols the dynamic linker needs. Must run before codesign.
if [ "$CLAUDEBAR_CHANNEL" = release ]; then strip -x "$MACOS_DIR/$APP_EXECUTABLE"; fi

# Native terminal client is nested code, signed before the containing bundle.
CLI_OUT="$CONTENTS/Helpers/$CLI_EXECUTABLE"
bash "$PROJECT_DIR/Sources/build-cli.sh" "$CLI_OUT"

echo "Binary created: $MACOS_DIR/$APP_EXECUTABLE"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_EXECUTABLE}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MACOS_MIN}</string>
    <key>LSUIElement</key>
    <true/>
    <key>ClaudeBarBuildChannel</key>
    <string>${CLAUDEBAR_CHANNEL}</string>
    <key>CFBundleURLTypes</key>
    <array><dict><key>CFBundleURLSchemes</key><array><string>${URL_SCHEME}</string></array></dict></array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>区域截图需要屏幕录制权限，用于将选中区域复制到剪贴板。</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>用于在资源条中显示蓝牙开关状态。</string>
    <key>NSLocationUsageDescription</key>
    <string>用于在你打开「当前位置」后为概览显示当地天气，以及在打开「Wi-Fi 名称」后显示当前网络名称。</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>用于在你打开「当前位置」后为概览显示当地天气，以及在打开「Wi-Fi 名称」后显示当前网络名称。未打开对应开关时不会读取位置。</string>
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

# The appex draws the CC / Codex marks too (`WidgetViews`' `sectionHeader`), and
# `ProductBrandMark` decodes them from *its own* bundle — an extension has a
# different `Bundle.main` from the host app, so the app's copy is not visible
# here. Without this the widget would silently draw the missing-asset fallback
# glyph and look, to every reader, exactly like a deliberate change.
APPEX_RESOURCES="$APPEX_CONTENTS/Resources"
mkdir -p "$APPEX_RESOURCES"
cp -R "$PROJECT_DIR/Sources/BrandAssets" "$APPEX_RESOURCES/BrandAssets"

# Compile the widget directly into the appex (no intermediate binary in MacOS/,
# which previously left a stray ClaudeBarWidget binary alongside the main app
# executable and made codesign --deep sign an extra artifact).
widget_files=()
while IFS= read -r file; do widget_files+=("$file"); done < <(find "$WIDGET_DIR" -name "*.swift" | sort)
if [ "${#widget_files[@]}" = 0 ]; then
    echo "ERROR: no widget sources found under $WIDGET_DIR" >&2
    exit 1
fi

WIDGET_MAP_FLAGS=()
if [ "$CLAUDEBAR_CHANNEL" = dev ]; then
    WIDGET_MAP="$(python3 "$PROJECT_DIR/Tools/build-cache.py" filemap "$BUILD_DIR/objects/widget" "$PROJECT_DIR/Sources/Shared/BuildChannel.swift" "${widget_files[@]}")"
    WIDGET_MAP_FLAGS=(-emit-executable -emit-module-path "$BUILD_DIR/objects/widget/ClaudeBarWidget.swiftmodule" -output-file-map "$WIDGET_MAP")
fi
swiftc "${SWIFT_FLAGS[@]}" ${WIDGET_MAP_FLAGS[@]+"${WIDGET_MAP_FLAGS[@]}"} \
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
    "$PROJECT_DIR/Sources/Shared/BuildChannel.swift" \
    "${widget_files[@]}"

if [ "$CLAUDEBAR_CHANNEL" = release ]; then strip -x "$APPEX_CONTENTS/MacOS/ClaudeBarWidget"; fi

echo "Widget binary: $APPEX_CONTENTS/MacOS/ClaudeBarWidget"

# Widget Info.plist (inside Contents/)
cat > "$APPEX_CONTENTS/Info.plist" << WPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${APP_GROUP_ID}</string>
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
ENT_DIR="$BUILD_DIR/entitlements"
mkdir -p "$ENT_DIR"

# Widget appex: sandbox ON + app group + network.
cat > "$ENT_DIR/widget.plist" << WENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>${APP_GROUP_ID}</string>
    </array>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
WENT

# Main app: sandbox OFF (needs ~/.claude) + app group + network + files.
cat > "$ENT_DIR/app.plist" << AENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>${APP_GROUP_ID}</string>
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
codesign --force --sign "$SIGN_IDENTITY" --options runtime --identifier "$BUNDLE_ID.cli" "$CLI_OUT"

# `--identifier` is pinned on both helpers: without it codesign derives the
# identifier from the output **filename** plus the Mach-O uuid it just embedded
# ("claudebar-batteryctl-<uuid>"). That uuid changes every compile and the
# identifier therefore changed with it, so the helper's CDHash never matched the
# installed copy and `BatteryHelperInstaller.isInstalled()` was false after every
# rebuild — re-asking for the admin password and re-applying the charge limit.
# A fixed identifier makes the signed CDHash reproducible across rebuilds.
codesign --force --sign "$SIGN_IDENTITY" --options runtime \
    --identifier claudebar-batteryctl "$BATTERYCTL_OUT"
if [ -f "${FANCTL_OUT:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --identifier claudebar-fanctl "$FANCTL_OUT"
fi

# Sign bottom-up (no --deep): appex binary -> appex bundle -> main binary.
# The main binary is signed explicitly so its entitlements are embedded
# before the bundle wrapper is sealed.
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENT_DIR/widget.plist" \
    "$APPEX_DIR/Contents/MacOS/ClaudeBarWidget"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENT_DIR/widget.plist" \
    "$APPEX_DIR"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENT_DIR/app.plist" \
    "$MACOS_DIR/$APP_EXECUTABLE"
# IMPORTANT: pass --entitlements on the bundle wrapper too. Signing a bundle
# re-seals the main executable; without --entitlements here codesign strips
# the entitlements that were just embedded, leaving the main app with none.
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENT_DIR/app.plist" \
    "$APP_BUNDLE"
python3 -E -s "$PROJECT_DIR/Tools/check-bundle.py" "$APP_BUNDLE" "$CLAUDEBAR_CHANNEL"
echo "Signed OK ($SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "Screen Recording TCC is bound to this certificate — rebuilds should not ask again."
fi

# Write the stamp only after successful compilation, signing and validation.
printf '%s\n' "$BUILD_FINGERPRINT" > "$STAMP_FILE"
fi

# --- Release artifacts (DMG + zip) for GitHub Releases ---
mkdir -p "$BUILD_DIR/bin"
ln -sfn "../$APP_NAME.app/Contents/Helpers/$CLI_EXECUTABLE" "$BUILD_DIR/bin/$CLI_EXECUTABLE"
ln -sfn "$CLI_EXECUTABLE" "$BUILD_DIR/bin/$CLI_ALIAS"

if [ "${CLAUDEBAR_PACKAGE:-}" = "1" ]; then
    DIST_DIR="$PROJECT_DIR/.build/dist"
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
        echo "Package:     $PROJECT_DIR/.build/dist/ClaudeBar-${VERSION}-macOS-arm64.dmg"
        echo "             $PROJECT_DIR/.build/dist/ClaudeBar-${VERSION}-macOS-arm64.zip"
    fi
else
    echo "=== Installing ==="
    # Refuse to replace a running app. Never kill a production process or VPN.
    if pgrep -x "$APP_EXECUTABLE" >/dev/null 2>&1; then
        echo "Quit $APP_NAME normally before installing (VPN cleanup must finish)." >&2
        exit 1
    fi
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALLED_APP"
    cp -R "$APP_BUNDLE" "$INSTALLED_APP"
    # The cp re-introduces xattrs; strip them again post-copy so the installed
    # bundle stays clean (matches the signed state).
    xattr -cr "$INSTALLED_APP"

    # Force LaunchServices + pluginkit to re-index the widget extension and mark
    # it enabled. Without this the gallery can lag behind a rebuild by one launch.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$INSTALLED_APP"
    pluginkit -e use -i "$WIDGET_ID" 2>/dev/null || true

    echo "=== Build complete ==="
    echo "Installed:   $INSTALLED_APP"
    echo "Build cache:  $APP_BUNDLE"
    echo ""
    echo "Run with: open $INSTALLED_APP"
fi
