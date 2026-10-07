#!/bin/bash
# Standalone CLI build; also used to embed the exact same binary in the app.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/Sources/build-config.sh"
OUTPUT="${1:-$BUILD_DIR/bin/$CLI_EXECUTABLE}"
mkdir -p "$(dirname "$OUTPUT")" "$BUILD_DIR/cli"
# Only standalone builds publish the alias; app builds publish after bundle signing.
publish_alias() {
    if [ "$OUTPUT" = "$BUILD_DIR/bin/$CLI_EXECUTABLE" ]; then
        ln -sfn "$CLI_EXECUTABLE" "$BUILD_DIR/bin/$CLI_ALIAS"
    fi
}
LOCK="$BUILD_DIR/cli/.build-lock"
if ! mkdir "$LOCK" 2>/dev/null; then echo "Another CLI build is active: $LOCK" >&2; exit 1; fi
STAGED="$OUTPUT.tmp.$$"
trap 'rm -f "$STAGED"; rmdir "$LOCK"' EXIT
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION" >&2; exit 1; }
VERSION_SOURCE="$(printf 'enum CLIVersion { static let value = "%s" }' "$VERSION")"
if [ ! -f "$BUILD_DIR/cli/CLIVersion.swift" ] || [ "$(cat "$BUILD_DIR/cli/CLIVersion.swift")" != "$VERSION_SOURCE" ]; then
    printf '%s\n' "$VERSION_SOURCE" > "$BUILD_DIR/cli/CLIVersion.swift"
fi
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
files=("$PROJECT_DIR/Sources/Shared/BuildChannel.swift" "$PROJECT_DIR/Sources/Shared/CLISnapshot.swift"
       "$BUILD_DIR/cli/CLIVersion.swift" "$PROJECT_DIR"/Sources/CLI/*.swift)
FINGERPRINT="$(python3 - "$OUTPUT" "$SDK_PATH:arm64-apple-macos${MACOS_MIN:-15.0}" "${SWIFT_FLAGS[*]}" "${files[@]}" <<'PYCLI'
import hashlib
from pathlib import Path
import subprocess
import sys
digest = hashlib.sha256('\0'.join(sys.argv[1:4]).encode())
digest.update(subprocess.check_output(['swiftc', '--version']))
for path in sys.argv[4:]:
    digest.update(path.encode())
    digest.update(Path(path).read_bytes())
# The script also controls flags/signing/cache, so include it explicitly.
digest.update(Path(sys.argv[4]).parents[1].joinpath('build-cli.sh').read_bytes())
print(digest.hexdigest())
PYCLI
)"
STAMP="$BUILD_DIR/cli/build.fingerprint"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$FINGERPRINT" ] && [ -x "$OUTPUT" ] \
    && codesign --verify --strict "$OUTPUT" 2>/dev/null; then
    publish_alias
    echo "CLI up to date: $OUTPUT"
    exit 0
fi
MAP_FLAGS=()
if [ "$CLAUDEBAR_CHANNEL" = dev ]; then
    MAP="$(python3 "$PROJECT_DIR/Tools/build-cache.py" filemap "$BUILD_DIR/objects/cli" "${files[@]}")"
    MAP_FLAGS=(-emit-executable -emit-module-path "$BUILD_DIR/objects/cli/ClaudeBarCLI.swiftmodule" -output-file-map "$MAP")
fi
swiftc "${SWIFT_FLAGS[@]}" ${MAP_FLAGS[@]+"${MAP_FLAGS[@]}"} -parse-as-library -module-name ClaudeBarCLI \
    -sdk "$SDK_PATH" -target "arm64-apple-macos${MACOS_MIN:-15.0}" \
    -framework AppKit -framework IOKit "${files[@]}" -o "$STAGED"
# Standalone output is ad-hoc signed; the embedding build re-signs with its identity.
codesign --force --sign - --identifier "$BUNDLE_ID.cli" "$STAGED"
codesign --verify --strict "$STAGED"
mv -f "$STAGED" "$OUTPUT"
printf '%s\n' "$FINGERPRINT" > "$STAMP"
publish_alias
echo "CLI ready: $OUTPUT ($CLI_ALIAS)"
