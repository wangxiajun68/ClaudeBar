#!/bin/bash
# Sourced by build.sh and tooling. No filesystem or process mutations here.
CLAUDEBAR_CHANNEL="${CLAUDEBAR_CHANNEL:-dev}"
case "$CLAUDEBAR_CHANNEL" in
    dev)
        APP_NAME="ClaudeBar Dev"
        APP_EXECUTABLE="ClaudeBarDev"
        BUNDLE_ID="com.claudebar.app.dev"
        URL_SCHEME="claudebar-dev"
        SWIFT_FLAGS=(-O -g -incremental -enable-batch-mode -j "${CLAUDEBAR_BUILD_JOBS:-4}" -D CLAUDEBAR_DEV)
        INSTALL_DIR="$HOME/Applications"
        ;;
    release)
        APP_NAME="ClaudeBar"
        APP_EXECUTABLE="ClaudeBar"
        BUNDLE_ID="com.claudebar.app"
        URL_SCHEME="claudebar"
        SWIFT_FLAGS=(-O -whole-module-optimization -D CLAUDEBAR_RELEASE)
        INSTALL_DIR="/Applications"
        ;;
    *) echo "Invalid CLAUDEBAR_CHANNEL: $CLAUDEBAR_CHANNEL (dev/release)" >&2; exit 1 ;;
esac
WIDGET_ID="${BUNDLE_ID}.widget"
APP_GROUP_ID="$WIDGET_ID"
BUILD_DIR="$PROJECT_DIR/.build/$CLAUDEBAR_CHANNEL"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
CLAUDEBAR_SKIP_INSTALL="${CLAUDEBAR_SKIP_INSTALL:-1}"
case "$CLAUDEBAR_SKIP_INSTALL" in
    0|1) ;;
    *) echo "CLAUDEBAR_SKIP_INSTALL must be 0 or 1" >&2; exit 1 ;;
esac
# Packaging must never implicitly install, or mistake a dev build for a release.
if [ "${CLAUDEBAR_PACKAGE:-0}" = 1 ]; then
    if [ "$CLAUDEBAR_CHANNEL" != release ] || [ "$CLAUDEBAR_SKIP_INSTALL" != 1 ]; then
        echo "Packaging requires CLAUDEBAR_CHANNEL=release and CLAUDEBAR_SKIP_INSTALL=1" >&2
        exit 1
    fi
fi
