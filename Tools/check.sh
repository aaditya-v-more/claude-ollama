#!/usr/bin/env bash
# Everything worth checking before a change goes out.
#
#   Tools/check.sh
#
# This is what runs on a pull request, so a clean run here is a clean run
# there. It builds into a temporary directory and asks the built bundle the
# questions rather than the checkout it came from — the interesting failures
# are the ones packaging introduces. Nothing is installed and nothing already
# installed is touched.
#
# The first run fetches Sparkle into vendor/, which needs the network. Without
# it the build still works and says so; the arch and signature checks are then
# skipped, because there is no compiled binary to have either.

set -euo pipefail

ROOT=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")

pass() { printf '  ok    %s\n' "$*"; }
skip() { printf '  --    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; exit 1; }

WORK=$(mktemp -d)
PACE_PID=""
cleanup() {
  if [ -n "$PACE_PID" ]; then
    # Both redirected: the kill is expected to race a proxy that has already
    # gone, and the wait is only here to stop the shell announcing the job it
    # just reaped.
    kill "$PACE_PID" 2>/dev/null || true
    wait "$PACE_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Claude (Ollama) $VERSION"
echo

# ------------------------------------------------------------------- parses --

for script in bin/claude-ollama app/launch Tools/*.sh; do
  bash -n "$ROOT/$script" || fail "$script does not parse"
done
python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" \
  "$ROOT/bin/claude-ollama-pace" >/dev/null || fail "the proxy does not compile"
pass "every script parses"

# The proxy runs on whatever python3 macOS ships, which is old and has nothing
# installed beside it. -S is that same machine without site-packages: an import
# resolving only through one works where it was written and on no user's.
imports=$(python3 - "$ROOT/bin/claude-ollama-pace" <<'PY'
import ast, pathlib, sys

tree = ast.parse(pathlib.Path(sys.argv[1]).read_text())
names = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        names |= {alias.name.split(".")[0] for alias in node.names}
    elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
        names.add(node.module.split(".")[0])
print(" ".join(sorted(names)))
PY
)
for module in $imports; do
  python3 -S -c "import $module" 2>/dev/null \
    || fail "the proxy imports $module, which is not in the standard library"
done
pass "the proxy imports nothing outside the standard library"

# ----------------------------------------------------------------- versions --

# The number is written down in three files and only one of them is called
# VERSION. A build where they disagree ships a proxy reporting a version it is
# not, and nothing afterwards can tell which one was built.
launcher=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/bin/claude-ollama")
pace=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$ROOT/bin/claude-ollama-pace")
[ "$launcher" = "$VERSION" ] || fail "bin/claude-ollama says $launcher, VERSION says $VERSION"
[ "$pace" = "$VERSION" ] || fail "bin/claude-ollama-pace says $pace, VERSION says $VERSION"
pass "all three copies of the version agree"

# -------------------------------------------------------------------- build --

"$ROOT/Tools/make-app.sh" "$WORK" >/dev/null
APP="$WORK/Claude (Ollama).app"
[ -d "$APP" ] || fail "make-app.sh produced no bundle"

STAMPED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ "$STAMPED" = "$VERSION" ] || fail "the bundle says $STAMPED, VERSION says $VERSION"

if file "$APP/Contents/MacOS/ClaudeOllama" | grep -q Mach-O; then
  # A single-slice build is a download half the Macs in the world cannot run,
  # and the appcast would go on to stamp a hardware requirement onto the entry.
  for arch in arm64 x86_64; do
    lipo -archs "$APP/Contents/MacOS/ClaudeOllama" | grep -qw "$arch" \
      || fail "the menu bar item has no $arch slice"
  done
  # Ad-hoc, not notarised — but it has to be intact, because macOS refuses a
  # bundle whose seal does not match what it holds.
  codesign --verify --deep --strict "$APP" || fail "the bundle's signature is broken"
  pass "built the menu bar item, arm64 + x86_64, signature intact"
else
  skip "built the shell fallback (no swiftc); arch and signature unchecked"
fi

# The launcher and the proxy travel inside the bundle. An archive missing them
# would install an app with nothing underneath it.
for command in claude-ollama claude-ollama-pace; do
  [ -x "$APP/Contents/Resources/bin/$command" ] || fail "$command is not in the bundle"
done
LAUNCHER="$APP/Contents/Resources/bin/claude-ollama"
REPORTED=$("$LAUNCHER" version)
[ "$REPORTED" = "claude-ollama $VERSION" ] || fail "the packaged launcher reports '$REPORTED'"
pass "both commands are aboard and report $VERSION"

# -------------------------------------------------------------------- smoke --

# None of this needs Ollama running, which is the point: these are the paths a
# machine with nothing set up still has to get through without an error.
"$LAUNCHER" --help >/dev/null || fail "the launcher cannot print its usage"
"$LAUNCHER" config >/dev/null || fail "the launcher cannot list its settings"
"$LAUNCHER" env >/dev/null || fail "the launcher cannot print the overrides"
pass "the launcher answers without a gateway"

# Pointed at a port nothing is listening on, so it starts, fails its catalog
# warm-up the way it would against a gateway that is off, and serves anyway.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
PACE_EXIT_WITH_APP=0 "$APP/Contents/Resources/bin/claude-ollama-pace" \
  --port "$PORT" --upstream 127.0.0.1:1 >"$WORK/pace.log" 2>&1 &
PACE_PID=$!
STATUS=""
for _ in $(seq 20); do
  STATUS=$(curl -fsS "http://127.0.0.1:$PORT/__pace" 2>/dev/null) && break
  sleep 0.25
done
[ -n "$STATUS" ] || { cat "$WORK/pace.log" >&2; fail "the proxy never answered on $PORT"; }
echo "$STATUS" | grep -q "\"version\": \"$VERSION\"" \
  || fail "the proxy's status does not report $VERSION"
pass "the proxy listens and reports its status"

echo
echo "all checks passed"
