#!/usr/bin/env bash
# Build the archive the Homebrew cask installs from.
#
#   Tools/make-payload.sh <output-dir>
#
# The archive holds one thing: the app bundle, with the two commands inside it
# at Contents/Resources/bin. That is what the cask's `app` stanza installs and
# what its `binary` stanzas symlink into the Homebrew prefix — and, because a
# Sparkle enclosure is a zipped bundle and nothing else, it is also exactly what
# the update feed serves. One archive, one checksum, both jobs.
#
# No wrapper path is baked in: the bundle finds its own copy, and the launcher
# already searches both the Apple Silicon and Intel prefixes, so one archive
# serves either.

set -euo pipefail

here=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
out=${1:?usage: make-payload.sh <output-dir>}
version=$(cat "$here/VERSION")

mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

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
