#!/bin/bash
# Explicit installation only. Does not change shell profiles or replace other tools.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDEBAR_CHANNEL="${1:-dev}"
source "$PROJECT_DIR/Sources/build-config.sh"
SOURCE="$APP_BUNDLE/Contents/Helpers/$CLI_EXECUTABLE"
[ -x "$SOURCE" ] || { echo "Build the matching application first" >&2; exit 1; }
# Check every destination before making any link, so a collision leaves both intact.
for COMMAND in "$CLI_EXECUTABLE" "$CLI_ALIAS"; do
    DESTINATION="$HOME/.local/bin/$COMMAND"
    if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
        if [ ! -L "$DESTINATION" ] || [ "$(readlink "$DESTINATION")" != "$SOURCE" ]; then
            echo "Refusing to replace an existing command: $DESTINATION" >&2
            exit 1
        fi
    fi
done
mkdir -p "$HOME/.local/bin"
for COMMAND in "$CLI_EXECUTABLE" "$CLI_ALIAS"; do
    ln -sfn "$SOURCE" "$HOME/.local/bin/$COMMAND"
    echo "Installed $HOME/.local/bin/$COMMAND"
done
echo 'If needed, add ~/.local/bin to PATH in your shell profile.'
