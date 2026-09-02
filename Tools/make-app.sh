#!/usr/bin/env bash
# Assemble "Claude (Ollama).app" — everything this tool installs, in one bundle.
#
#   Tools/make-app.sh <destination-dir> [path-to-claude-ollama]
#
# The launcher and the pacing proxy ride inside the bundle, in
# Contents/Resources/bin, alongside the menu bar item. That is what makes
# updating possible: Sparkle replaces a bundle, and anything installed outside
# one would be left behind at the version it arrived at, so an updated app would
# be driving last month's proxy. The cask symlinks the two commands out of here
# into Homebrew's prefix, so `claude-ollama` on the PATH is always the copy that
# came with the app that is installed now.
#
# The second argument is baked into the shell fallback as the first place it
# looks for the launcher. The compiled menu bar item looks inside its own bundle
# first and has no need of it.

set -euo pipefail

here=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dest=${1:?usage: make-app.sh <destination-dir> [path-to-claude-ollama]}
wrapper=${2:-}
version=$(tr -d '[:space:]' < "$here/VERSION")

bundle="$dest/Claude (Ollama).app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/bin"

cp "$here/app/Info.plist" "$bundle/Contents/Info.plist"
# The one place the version is written down is the VERSION file; every copy of
# it downstream is stamped from there. Sparkle compares these two against the
# feed, so a bundle left at the placeholder would refuse every update there is.
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $version" \
  -c "Set :CFBundleVersion $version" \
  "$bundle/Contents/Info.plist" >/dev/null

cp "$here/app/icon.icns" "$bundle/Contents/Resources/icon.icns"
install -m 755 "$here/bin/claude-ollama" "$here/bin/claude-ollama-pace" \
  "$bundle/Contents/Resources/bin/"

# The real executable is a small accessory app that starts Claude and then sits
# in the menu bar showing what the proxy is doing. Where there is no Swift
# compiler — a checkout on a machine without the Xcode tools — the shell script
# stands in: it starts Claude the same way and exits, without the menu item.
if command -v swiftc >/dev/null 2>&1; then
  # Without the framework the app still builds; `#if canImport(Sparkle)` leaves
  # the updater out of it. Worth having, because this is the script a checkout
  # with no network runs, and an app that cannot update itself beats no app.
  sparkle=""
  if "$here/Tools/fetch-sparkle.sh" >&2; then
    sparkle="$here/vendor/Sparkle.framework"
  else
    echo "note: building without Sparkle; this app will not update itself" >&2
  fi

  swift_args=(-O)
  if [ -n "$sparkle" ]; then
    swift_args+=(-F "$here/vendor" -framework Sparkle
                 -Xlinker -rpath -Xlinker "@executable_path/../Frameworks")
  fi

  # Both architectures, from either kind of Mac. One archive has to serve
  # everyone — and with an update feed in the picture a single slice is worse
  # than it looks: generate_appcast reads the slices out of the bundle and
  # stamps a hardware requirement onto the entry, so an Intel Mac would not just
  # be running a translated app, it would never be offered an update again.
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  slices=()
  for arch in arm64 x86_64; do
    if swiftc "${swift_args[@]}" -target "$arch-apple-macos11" \
         -o "$work/$arch" "$here/app/StatusItem.swift" 2>/dev/null; then
      slices+=("$work/$arch")
    else
      echo "note: no $arch slice; this build will not run on that Mac" >&2
    fi
  done
  if [ "${#slices[@]}" -eq 0 ]; then
    # Again, with the errors this time: there is nothing to ship without it.
    swiftc "${swift_args[@]}" -target "$(uname -m)-apple-macos11" \
      -o "$work/native" "$here/app/StatusItem.swift"
    exit 1
  elif [ "${#slices[@]}" -eq 1 ]; then
    mv "${slices[0]}" "$bundle/Contents/MacOS/ClaudeOllama"
  else
    lipo -create "${slices[@]}" -output "$bundle/Contents/MacOS/ClaudeOllama"
  fi

  if [ -n "$sparkle" ]; then
    framework="$bundle/Contents/Frameworks/Sparkle.framework"
    mkdir -p "$bundle/Contents/Frameworks"
    ditto "$sparkle" "$framework"
    # Nothing here is sandboxed, so Sparkle's XPC services do nothing for it,
    # and removing them avoids the nested-entitlements dance a --deep sign runs
    # into. The version letter is globbed because Sparkle has not always used B.
    rm -rf "$framework"/Versions/*/XPCServices
    rm -f "$framework/XPCServices"
    # --deep here and not on the bundle below: the framework's own helpers —
    # Autoupdate, Updater.app — need signing first, so that the app's signature
    # seals a framework that has already settled.
    codesign --force --deep --sign - "$framework" >/dev/null 2>&1 || true
  fi

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

if [ "$built" = shell ]; then
  echo "note: built without the menu bar item (no swiftc)" >&2
fi

echo "$bundle"
