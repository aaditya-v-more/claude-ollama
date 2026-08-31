#!/usr/bin/env bash
# Build the archive the Homebrew cask installs from.
#
#   Tools/make-payload.sh <output-dir>
#
# Lays the app bundle and the two scripts out at the archive root, which is
# where the cask's `app` and `binary` stanzas expect to find them. The bundle is
# built without a baked-in wrapper path on purpose: the cask symlinks the
# scripts into the Homebrew prefix, and the launcher already searches both the
# Apple Silicon and Intel prefixes, so one archive serves either.

set -euo pipefail

here=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
out=${1:?usage: make-payload.sh <output-dir>}
version=$(cat "$here/VERSION")

mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/bin"
install -m 755 "$here/bin/claude-ollama" "$here/bin/claude-ollama-pace" "$stage/bin/"
"$here/Tools/make-app.sh" "$stage" >/dev/null

archive="$out/ClaudeOllama-$version.zip"
rm -f "$archive"
xattr -cr "$stage"
# zip rather than ditto: ditto writes an AppleDouble header beside every file —
# either scattered through the bundle or in a __MACOSX directory — and Homebrew
# unpacks with unzip, which would stage them as real files. Plain zip records
# the permission bits in the external attributes, which is all the bundle needs.
( cd "$stage" && zip -qry -X "$archive" . -x '.DS_Store' '*/.DS_Store' )

echo "$archive"
