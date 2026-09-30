#!/bin/bash
# Read-only preflight: never launches apps or alters network settings/keychains.
set -euo pipefail
cd "$(dirname "$0")/.."
failed=0
for tool in swiftc clang xcrun codesign python3 hdiutil; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'OK  %s\n' "$tool"
    else
        printf 'MISSING %s\n' "$tool"; failed=1
    fi
done
xcrun --show-sdk-path --sdk macosx || failed=1
swiftc --version || failed=1
for resource in Sources/ClaudeBar/Resources/mihomo-core.xz Sources/ClaudeBar/Resources/mihomo-core.version Sources/Widget/WidgetSnapshot.swift; do
    if [ -f "$resource" ]; then printf 'OK  %s\n' "$resource"; else printf 'MISSING %s\n' "$resource"; failed=1; fi
done
if [ -x .venv/bin/python ]; then TEST_PYTHON=.venv/bin/python; else TEST_PYTHON=python3; fi
"$TEST_PYTHON" -c 'import PIL, numpy; print("OK  test image dependencies")' || failed=1
exit "$failed"
