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
cp "$here/app/launch" "$bundle/Contents/MacOS/launch"
chmod 755 "$bundle/Contents/MacOS/launch"

if [ -n "$wrapper" ]; then
  # A literal replacement, so a prefix containing regex metacharacters — which
  # a Homebrew prefix on an unusual path can — is still substituted correctly.
  python3 - "$bundle/Contents/MacOS/launch" "$wrapper" <<'PY'
import sys
path, wrapper = sys.argv[1], sys.argv[2]
with open(path) as handle:
    text = handle.read()
with open(path, "w") as handle:
    handle.write(text.replace("@@WRAPPER@@", wrapper))
PY
fi

echo "$bundle"
