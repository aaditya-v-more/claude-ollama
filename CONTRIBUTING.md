# Contributing

Bug reports, fixes, and small features are all welcome, and so is a plain
question about why something works the way it does.

This is a narrow tool: it points Claude Desktop at a local Ollama gateway using
process environment and a pacing proxy, and it writes nothing into the app's own
settings. Changes that keep it inside that purpose are easy to accept. Changes
that widen it — another provider, another app, a settings UI of its own — are
worth an issue before any code, because the answer may be that the tool is not
the place for it.

If a change will take you more than an afternoon, open an issue first. A
sentence about what you are trying to do is enough, and it saves the case where
the answer is "there is already a setting for that".

## Getting a checkout running

You need macOS 11 or later and the Xcode command line tools, for `swiftc`
(`xcode-select --install`). Everything else the build uses ships with macOS. The
first build downloads the Sparkle framework into `vendor/`, so it needs the
network once; without it the build still produces an app, just one with no menu
bar item and no updater.

```sh
git clone https://github.com/aaditya-v-more/claude-ollama.git
cd claude-ollama
./Tools/make-app.sh . "$PWD/bin/claude-ollama"
./bin/claude-ollama install-app
```

That builds `Claude (Ollama).app` in the checkout and links it into
`~/Applications`, where Spotlight will find it. Your own build otherwise
replaces itself with a released one the first time it checks for updates, so
stop it looking:

```sh
defaults write local.aaditya.claude-ollama-launcher SUEnableAutomaticChecks -bool false
```

To see it do anything real you also need Claude Desktop in `/Applications` and
Ollama's gateway switched on — in the Ollama app, **Apps**, turn **Claude** on.
`./bin/claude-ollama doctor` reports which of those are missing.

## What the pieces are

**`bin/claude-ollama`** is the launcher, and the single place that knows what the
settings are called, what they default to, and what overrides what. Everything
else asks it: the menu bar item reads `claude-ollama status --json` and writes
back through `claude-ollama config --set`. A new setting goes into the `KNOWN`
list near the top of this script and gets its default just below; `config`, the
environment override, and the menu all pick it up from there.

**`bin/claude-ollama-pace`** is the pacing proxy that sits between Claude Desktop
and the gateway: it holds the number of in-flight requests down, retries the
529s the gateway returns instead of passing them on, and tags the model catalog
with each model's real context length. It must run on the Python that macOS
ships — currently 3.9, with nothing installed beside it — so the standard
library is all there is. `Tools/check.sh` enforces that.

**`app/StatusItem.swift`** is the menu bar item, and the bundle's real
executable. **`app/launch`** is the shell fallback used when a machine has no
`swiftc`; it starts Claude and exits, with no menu.

**`Tools/`** builds and releases: `make-app.sh` assembles the bundle,
`make-payload.sh` zips the archive the cask installs, `fetch-sparkle.sh` vendors
the updater, `release.sh` does a release, and `check.sh` is the next section.

**`docs/`** is the website GitHub Pages serves, and `docs/appcast.xml` is the
update feed. The feed is written by `release.sh` and signed; never edit it by
hand.

## Checking your work

```sh
./Tools/check.sh
```

That is exactly what runs on a pull request. It parses every script, confirms
the three copies of the version agree, builds the bundle in a temporary
directory, and asks the built app the questions rather than the checkout — both
architectures, an intact signature, both commands aboard, the launcher answering
with no gateway, and the proxy listening and reporting its status. It installs
nothing and leaves anything already installed alone.

Then run it. A change to the launcher or the proxy wants `claude-ollama run`
with Claude actually driving traffic through it: the menu bar item is the
fastest way to see whether requests are still being paced, and
`~/.local/state/claude-ollama-pace.log` has the rest. Say in the pull request
what you did to check, even if it was only that.

## Commits and pull requests

One change per pull request, and a subject line that says what the change does
to the thing rather than what you did — `git log` shows the shape. Say why in
the body when the why is not obvious from the diff.

Comments here explain reasons, not mechanics: the code says what it does, so a
comment earns its place by saying why it has to be that way, or which failure it
is avoiding. That is most of the existing comments, and it is the house style
worth matching.

Leave `VERSION` alone. It is bumped as part of a release, along with the copies
in the two `bin` scripts, and a pull request that moves it collides with the
next release rather than helping it. Releasing is a maintainer job — it signs an
update feed with a key that lives on one machine.

By opening a pull request you are offering the change under this repository's
[MIT licence](LICENSE), same as everything already here.

## Reporting things

Bugs and ideas go in
[issues](https://github.com/aaditya-v-more/claude-ollama/issues). For a bug,
`claude-ollama doctor` answers most of what the form asks for. Security reports
go by email instead — see [SECURITY.md](SECURITY.md).

Everyone taking part is expected to keep to the
[code of conduct](CODE_OF_CONDUCT.md).
