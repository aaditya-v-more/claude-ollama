#!/usr/bin/env bash
# Build a release of Claude (Ollama), and everything that has to go out with it.
#
#   Tools/release.sh
#
# The version comes from the VERSION file. Bump that — and the copy of it each
# script carries — run this, then publish what it names at the end. There are
# three places a release has to land and they are easy to do two of: the tag and
# its archive, the appcast that tells installed copies the archive exists, and
# the cask that tells Homebrew. This prepares all three.

set -euo pipefail

ROOT=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DIST="$ROOT/dist"
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
TAG="v$VERSION"
ARCHIVE="$DIST/ClaudeOllama-$VERSION.zip"
REPO="https://github.com/aaditya-v-more/claude-ollama"

echo "Claude (Ollama) $VERSION"

# Releasing one version twice leaves two different archives answering to one
# number, which nothing downstream — an update feed least of all — can tell
# apart. Caught here rather than after the upload.
if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
  echo "$TAG already exists. Bump VERSION before releasing." >&2
  exit 1
fi

# The number is written down in three files and only one of them is called
# VERSION. A release where they disagree ships a proxy that reports a version it
# is not, and there is no way to tell afterwards which one was built.
launcher_version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/bin/claude-ollama")
pace_version=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$ROOT/bin/claude-ollama-pace")
for pair in "bin/claude-ollama:$launcher_version" "bin/claude-ollama-pace:$pace_version"; do
  if [ "${pair#*:}" != "$VERSION" ]; then
    echo "${pair%%:*} says ${pair#*:}, VERSION says $VERSION." >&2
    exit 1
  fi
done

bash -n "$ROOT/bin/claude-ollama"
bash -n "$ROOT/Tools/make-app.sh"
bash -n "$ROOT/Tools/make-payload.sh"
python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" \
  "$ROOT/bin/claude-ollama-pace" >/dev/null
echo "scripts parse, versions agree"

rm -rf "$DIST"
"$ROOT/Tools/make-payload.sh" "$DIST" >/dev/null
echo "packaged $ARCHIVE"

# Everything below asks the archive itself rather than the build that made it.
# This is the file people download and Sparkle unpacks, and the questions worth
# asking are about what comes out of it.
CHECK="$DIST/check"
mkdir -p "$CHECK"
unzip -q "$ARCHIVE" -d "$CHECK"
APP="$CHECK/Claude (Ollama).app"

STAMPED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ "$STAMPED" = "$VERSION" ] || { echo "the bundle says $STAMPED, VERSION says $VERSION." >&2; exit 1; }

# A single-slice build is a download half the Macs in the world cannot run, and
# the appcast would go on to stamp a hardware requirement on the entry, which
# turns "runs slowly" into "never updated again".
for arch in arm64 x86_64; do
  lipo -archs "$APP/Contents/MacOS/ClaudeOllama" | grep -qw "$arch" \
    || { echo "the menu bar item has no $arch slice." >&2; exit 1; }
done

# The launcher and the proxy travel inside the bundle; the cask symlinks them
# out of it and Sparkle replaces all three together. An archive missing them
# would install an app with nothing underneath it.
for command in claude-ollama claude-ollama-pace; do
  [ -x "$APP/Contents/Resources/bin/$command" ] \
    || { echo "$command is not in the bundle." >&2; exit 1; }
done
REPORTED=$("$APP/Contents/Resources/bin/claude-ollama" version)
[ "$REPORTED" = "claude-ollama $VERSION" ] \
  || { echo "the packaged launcher reports '$REPORTED'." >&2; exit 1; }

# Ad-hoc, not notarised — but it has to be intact, because macOS refuses a
# bundle whose seal does not match what it holds, and a zip is unpacked by
# whatever the user happens to have.
codesign --verify --deep --strict "$APP"
echo "verified $STAMPED, arm64 + x86_64, signature intact, commands aboard"
rm -rf "$CHECK"

# The version is written down once more, in another repository. Nothing here
# pushes to it — this script builds and prepares, a person publishes — but the
# cask is the half that gets forgotten, and a tap left behind serves an install
# that Sparkle then has to correct on first launch.
TAP_REPO="https://github.com/aaditya-v-more/homebrew-tap.git"
TAP="$DIST/homebrew-tap"
CASK="$TAP/Casks/claude-ollama.rb"
SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if git clone -q "$TAP_REPO" "$TAP" 2>/dev/null; then
  WAS=$(sed -n 's/^  version "\(.*\)"$/\1/p' "$CASK")
  /usr/bin/sed -i "" \
    -e "s|^  version \".*\"$|  version \"$VERSION\"|" \
    -e "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" "$CASK"
  grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" \
    || { echo "the cask in $TAP was not rewritten for $VERSION." >&2; exit 1; }

  # This clone is of the tap as published, so it can be older than the archive
  # it is being pointed at. The commands moved inside the bundle in 1.3.0, and a
  # cask still linking bin/ from the archive root would fail every install until
  # someone noticed — better to say so here than to push it.
  grep -q 'binary "#{appdir}/Claude (Ollama).app/Contents/Resources/bin/claude-ollama"' "$CASK" \
    || { echo "the published cask still links bin/ from the archive root." >&2
         echo "Update its binary stanzas to point inside the bundle, then run this again." >&2
         exit 1; }
  git -C "$TAP" commit -q -am "Point the cask at $VERSION"
  echo "cask updated to $VERSION in $TAP (was $WAS)"
else
  echo "could not reach the tap; the cask must be updated by hand:" >&2
  echo "  version \"$VERSION\"  sha256 \"$SHA\"" >&2
fi

# The appcast is a file in docs/, which Pages serves straight off main. No
# branch to juggle and no CI secret: the signing key stays in this machine's
# keychain and generate_appcast reads it from there.
"$ROOT/Tools/fetch-sparkle.sh" >&2
mkdir -p "$DIST/sparkle" "$ROOT/docs"
cp "$ARCHIVE" "$DIST/sparkle/"

# generate_appcast merges into an appcast it finds beside the archives, and the
# download prefix it is given applies only to the build it has not seen before.
# Without seeding it with the feed as published, this run would rewrite the file
# from the one new zip and every earlier version would vanish with its URL.
BEFORE=0
if [ -f "$ROOT/docs/appcast.xml" ]; then
  cp "$ROOT/docs/appcast.xml" "$DIST/sparkle/appcast.xml"
  BEFORE=$(grep -c "<item>" "$ROOT/docs/appcast.xml" || true)
fi

# --maximum-versions 0 keeps every entry. The default prunes to a handful,
# which quietly drops the oldest release on each run — and the signature in an
# entry is over an archive that is not built again, so a dropped one is
# recovered from git history or not at all.
"$ROOT/vendor/bin/generate_appcast" \
  --maximum-versions 0 \
  --download-url-prefix "$REPO/releases/download/$TAG/" \
  --link "$REPO" \
  -o "$ROOT/docs/appcast.xml" \
  "$DIST/sparkle"

AFTER=$(grep -c "<item>" "$ROOT/docs/appcast.xml" || true)
[ "$AFTER" -eq "$((BEFORE + 1))" ] \
  || { echo "the appcast should have gone $BEFORE -> $((BEFORE + 1)), went $BEFORE -> $AFTER." >&2; exit 1; }

# generate_appcast drops the signature silently when the key it finds does not
# match SUPublicEDKey, and an unsigned enclosure is one every client refuses.
grep -q "sparkle:edSignature" "$ROOT/docs/appcast.xml" \
  || { echo "the new appcast entry carries no EdDSA signature." >&2; exit 1; }
grep -q "ClaudeOllama-$VERSION.zip" "$ROOT/docs/appcast.xml" \
  || { echo "the appcast does not mention $VERSION." >&2; exit 1; }
! grep -q "hardwareRequirements" "$ROOT/docs/appcast.xml" \
  || { echo "the appcast limits an entry to one architecture." >&2; exit 1; }
echo "appcast has a signed entry for $VERSION"

cat <<NOTE

To publish $TAG:
  git add docs/appcast.xml && git commit -m "Release $VERSION"
  git tag -a $TAG -m "Claude (Ollama) $VERSION"
  git push origin main --tags
  gh release create $TAG "$ARCHIVE" --title "Claude (Ollama) $VERSION" --notes-file -
  git -C "$TAP" push origin HEAD

The archive must exist for the URL inside the appcast to resolve, and the
appcast must be pushed for anyone to be told about it. Do both before telling
anyone. The cask push is the third, and it is the one that gets forgotten.

Then check the feed actually rebuilt — a push does not reliably queue a Pages
build, and a feed still serving the old file means nobody is offered anything:

  curl -s https://aaditya-v-more.github.io/claude-ollama/appcast.xml | grep shortVersionString

If it does not name this version, ask for a build and wait for it:

  gh api -X POST repos/aaditya-v-more/claude-ollama/pages/builds

Pages has to be switched on once, in the repository's settings: deploy from the
main branch, /docs folder. Until it is, every installed copy polls a 404 and
quietly carries on with the version it has.
NOTE
