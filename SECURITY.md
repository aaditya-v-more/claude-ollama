# Security

## Reporting a vulnerability

Email **aadityavmore@gmail.com**. Please do not open a public issue for anything
that could be exploited before there is a fix.

Tell me what you found, how to reproduce it, and what an attacker gets out of
it. A rough note is fine — I would rather have it early than well written. This
is a side project, so a reply may take a few days; you will get one.

If a report leads to a fix, you will be credited in the release notes unless you
would rather not be.

## What is in scope

The launcher, the pacing proxy, the menu bar item, the build and release
scripts, and the update feed — anything in this repository, and the archives
published from it. The Homebrew cask lives in
[aaditya-v-more/homebrew-tap](https://github.com/aaditya-v-more/homebrew-tap)
and is covered too; report those here.

Not in scope, because they are not this project's to fix: Claude Desktop, Ollama
and its gateway, and the Sparkle framework, which is vendored at a pinned
version and verified by checksum. Report those to their own projects. If a
released archive is signed for a Sparkle version with a known problem, that one
is worth telling me about — the pin is mine.

## What this thing actually does

Worth knowing before you go looking:

Everything runs on the machine and nothing here opens a port to the network. The
proxy binds `127.0.0.1` only, and sits between Claude Desktop and Ollama's local
gateway, which is also loopback. It forwards request and response bodies without
reading them; what it does read is the model catalog, to tag each model with its
context length.

The tuning is supplied as process environment for the app it starts, and nothing
is written into Claude Desktop's own settings. The only files written are the
config file at `~/.config/claude-ollama/config`, the proxy log at
`~/.local/state/claude-ollama-pace.log`, and the port file beside it.

Updates arrive through Sparkle. The appcast is served over HTTPS from GitHub
Pages, every enclosure carries an EdDSA signature, and the public key is in the
app's `Info.plist` — an archive that is not signed by the matching private key
is refused. The app itself is signed ad-hoc, not notarised: the cask clears the
quarantine attribute rather than pretending otherwise, which is worth knowing if
you are deciding what to trust here.

## Supported versions

The latest release, and no other. Fixes go out as a new version rather than back
into an old one.
