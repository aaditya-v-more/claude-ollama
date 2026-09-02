# claude-ollama

[![Support this on Ko-fi](https://img.shields.io/badge/Ko--fi-support%20this-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/aadityavmore)

Claude Desktop, pointed at a local Ollama gateway, without editing anything the
app owns. A launcher sets the tuning as process environment only, a small proxy
paces requests against the gateway and repairs what it gets wrong, and a menu
bar item shows what is going on.

## Install

```sh
brew install --cask aaditya-v-more/tap/claude-ollama
```

<img src="docs/images/app-in-launcher.png" alt="Claude (Ollama) as the first result of a launcher search, with its own icon." width="520">

It goes into `/Applications`, so Spotlight and Launchpad find it by name.

Two things have to be in place first, and this installs neither. Claude Desktop
in `/Applications`, and Ollama's gateway actually switched on — it is not on by
default. In the Ollama app open **Apps** and turn **Claude** on; for cloud
models, sign in to Ollama and enable those as well, some of which need a paid
plan. Until that is done nothing is listening on `127.0.0.1:11435` and none of
this will work.

## Use

Open **Claude (Ollama)**. The proxy starts, the profile's endpoint is pointed at
it, and Claude Desktop launches with the overrides in its environment.

<img src="docs/images/menu-under-load.png" alt="The menu bar item during a run: 2 in flight of 3, 0 queued, 1338 served, 13 retried, 0 gave up, 2 of 3 models at 1M, and the time of the last pushback from the gateway." width="380">

Everything else is in that menu. Every setting is listed with its current value
and will take a new one, applied the next time Claude starts.

<img src="docs/images/menu-settings.png" alt="The Settings submenu open, listing every Claude Desktop and pacing proxy setting with its current value, above the running version and Check for Updates." width="560">

The app keeps itself up to date, and both it and the proxy quit when Claude
does.

Models that can do a million tokens are used as such. Claude Desktop decides
that by matching `[1m]` in the model ID and the gateway never sets it, so
without this every model falls back to 200k regardless of what it can actually
do — the proxy reads each one's real context length from Ollama and tags the
catalog with it.

<img src="docs/images/context-window-1m.png" alt="Claude's context window readout showing 43.4k of 1M used, 919k free, on the model glm-5.3-flash:cloud." width="480">

## Uninstall

```sh
brew uninstall --cask claude-ollama
```

Add `--zap` to take the settings file and the proxy log with it. Your chats live
in Claude Desktop's own profile and are left alone either way.

## Building from a checkout

```sh
./Tools/make-app.sh . "$PWD/bin/claude-ollama"
./bin/claude-ollama install-app
```

Such a build will otherwise replace itself with a released one, so stop it
looking:

```sh
defaults write local.aaditya.claude-ollama-launcher SUEnableAutomaticChecks -bool false
```

`claude-ollama --help` lists the rest of the commands.

---

[What it does and why](https://aaditya-v-more.github.io/claude-ollama/) &middot;
MIT &middot; [Tip jar](https://ko-fi.com/aadityavmore)
