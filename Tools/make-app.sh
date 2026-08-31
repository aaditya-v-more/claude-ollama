#!/usr/bin/env bash
# Assemble "Claude (Ollama).app" — a LSUIElement launcher whose only job is to
# give the wrapper a Dock icon and a double-clickable front door.
#
#   Tools/make-app.sh <destination-dir> [path-to-claude-ollama]
#
# The bundle carries no logic of its own. Its executable finds the wrapper and
# reports failures in a dialog, because LaunchServices gives it no terminal to
# print to. The second argument is baked in as the first place it looks.

set -euo pipefail

here=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dest=${1:?usage: make-app.sh <destination-dir> [path-to-claude-ollama]}
wrapper=${2:-}

bundle="$dest/Claude (Ollama).app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

cp "$here/app/Info.plist" "$bundle/Contents/Info.plist"
cp "$here/app/icon.icns" "$bundle/Contents/Resources/icon.icns"

# The real executable is a small accessory app that starts Claude and then sits
# in the menu bar showing what the proxy is doing. Where there is no Swift
# compiler — a checkout on a machine without the Xcode tools — the shell script
# stands in: it starts Claude the same way and exits, without the menu item.
if command -v swiftc >/dev/null 2>&1; then
  swiftc -O -target "$(uname -m)-apple-macos11" \
    -o "$bundle/Contents/MacOS/ClaudeOllama" "$here/app/StatusItem.swift"
  # arm64 refuses to run an unsigned binary at all, and the cask clears the
  # quarantine attribute rather than pretending this is notarised.
  codesign --force --sign - "$bundle" >/dev/null 2>&1 || true
  built=menu-bar
else
  cp "$here/app/launch" "$bundle/Contents/MacOS/ClaudeOllama"
  built=shell
fi
chmod 755 "$bundle/Contents/MacOS/ClaudeOllama"

if [ -n "$wrapper" ] && [ "$built" = shell ]; then
  # A literal replacement, so a prefix containing regex metacharacters — which
  # a Homebrew prefix on an unusual path can — is still substituted correctly.
  python3 - "$bundle/Contents/MacOS/ClaudeOllama" "$wrapper" <<'PY'
import sys
path, wrapper = sys.argv[1], sys.argv[2]
with open(path) as handle:
    text = handle.read()
with open(path, "w") as handle:
    handle.write(text.replace("@@WRAPPER@@", wrapper))
PY
fi

echo "$bundle"
[ "$built" = shell ] && echo "note: built without the menu bar item (no swiftc)" >&2
