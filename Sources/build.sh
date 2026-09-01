#!/bin/bash
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

echo "=== Building $APP_NAME ==="

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$MACOS_DIR"
RESOURCES_DIR="$CONTENTS/Resources"
mkdir -p "$RESOURCES_DIR"

# Copy app icon
ICONS_SOURCE="$PROJECT_DIR/Sources/AppIcon.icns"
if [ -f "$ICONS_SOURCE" ]; then
    cp "$ICONS_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
    echo "Icon copied to bundle"
fi

# Copy bundled fonts (LXGW WenKai GB — CJK display face). Custom fonts are
# loaded at runtime via CTFontManager, so they must ship inside the bundle.
FONT_SOURCE_DIR="$PROJECT_DIR/Sources/Resources/Fonts"
if [ -d "$FONT_SOURCE_DIR" ]; then
    mkdir -p "$RESOURCES_DIR/Fonts"
    cp "$FONT_SOURCE_DIR"/*.ttf "$RESOURCES_DIR/Fonts/"
    echo "Fonts copied to bundle"
fi

# Compile Swift sources
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
echo "Using SDK: $SDK_PATH"

swift_files=$(find "$SOURCES_DIR" -name "*.swift" | sort)

swiftc \
    -o "$MACOS_DIR/$APP_NAME" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macos26.0 \
    -framework SwiftUI \
    -framework AppKit \
    -framework WidgetKit \
    -framework CryptoKit \
    -framework CoreServices \
    -lsqlite3 \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -rpath -Xlinker "$SDK_PATH/System/Library/Frameworks" \
    $swift_files

echo "Binary created: $MACOS_DIR/$APP_NAME"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Axon</string>
    <key>CFBundleDisplayName</key>
    <string>Axon</string>
    <key>CFBundleIdentifier</key>
    <string>com.claudebar.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeBar</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
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

swiftc \
    -o "$APPEX_CONTENTS/MacOS/ClaudeBarWidget" \
    -module-name ClaudeBarWidget \
    -parse-as-library \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macos26.0 \
    -framework SwiftUI \
    -framework WidgetKit \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -application_extension \
    -Xlinker -e -Xlinker _NSExtensionMain \
    $widget_files

echo "Widget binary: $APPEX_CONTENTS/MacOS/ClaudeBarWidget"

# Widget Info.plist (inside Contents/)
cat > "$APPEX_CONTENTS/Info.plist" << 'WPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.claudebar.app.widget</string>
    <key>CFBundleName</key>
    <string>ClaudeBarWidget</string>
    <key>CFBundleDisplayName</key>
    <string>Axon Widget</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeBarWidget</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
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
codesign --force --sign - --options runtime --entitlements "$ENT_DIR/widget.plist" \
    "$APPEX_DIR/Contents/MacOS/ClaudeBarWidget"
codesign --force --sign - --options runtime --entitlements "$ENT_DIR/widget.plist" \
    "$APPEX_DIR"
codesign --force --sign - --options runtime --entitlements "$ENT_DIR/app.plist" \
    "$MACOS_DIR/$APP_NAME"
# IMPORTANT: pass --entitlements on the bundle wrapper too. Signing a bundle
# re-seals the main executable; without --entitlements here codesign strips
# the entitlements that were just embedded, leaving the main app with none.
codesign --force --sign - --options runtime --entitlements "$ENT_DIR/app.plist" \
    "$APP_BUNDLE"
echo "Signed OK"

# --- Install to /Applications (single canonical copy) ---
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
