# claude-ollama

Claude Desktop, pointed at a local Ollama gateway, without editing anything the
app owns.

Two pieces:

- **Environment overrides.** A launcher that starts Claude Desktop with the
  retry, concurrency, timeout and context-window variables set for a small
  self-hosted endpoint. They are process environment only — quit the app and
  nothing remains.
- **A pacing proxy.** A small HTTP proxy in front of the gateway that holds
  requests to a fixed number in flight, retries the ones upstream still
  rejects, and repairs two things the gateway gets wrong on the way through.

Plus a `Claude (Ollama).app` launcher, which stays in the menu bar while Claude
is open and shows what the proxy is doing.

## Install

```sh
brew install --cask aaditya-v-more/tap/claude-ollama
```

That puts **Claude (Ollama)** in `/Applications` and the `claude-ollama` and
`claude-ollama-pace` commands on your `PATH`. Set
`HOMEBREW_CASK_OPTS="--appdir=~/Applications"` first if you would rather it went
there. The formula itself lives in
[aaditya-v-more/homebrew-tap](https://github.com/aaditya-v-more/homebrew-tap);
this repository is the source it builds from.

This assumes you already have Claude Desktop in `/Applications` and Ollama
serving its Claude-compatible gateway on `127.0.0.1:11435`. It installs
neither.

Check the result:

```sh
claude-ollama doctor
```

## Use

Open **Claude (Ollama)**, or run `claude-ollama` in a terminal. Either way the
same thing happens: the proxy starts if it isn't already up, the profile's
endpoint is re-pointed at it, and Claude Desktop launches with the overrides in
its environment.

Launched from the app, a menu bar item appears alongside it showing the port
the proxy settled on, how many requests are in flight against the limit, how
many the gateway has pushed back on, and how many models were found to have a
1M window. It can copy the endpoint, open the log or the settings file, and
restart the proxy without restarting Claude.

Both the menu item and the proxy exit on their own once Claude quits.

If the configured port is already taken by something else, the proxy moves to
the next free one and the profile's endpoint is rewritten to match, so a busy
port needs no attention. `claude-ollama status` says where it ended up.

## Settings

Every setting can be given as an environment variable, for one launch:

```sh
SUBAGENTS=2 PACE_LIMIT=2 claude-ollama
```

or written to a file, for every launch — including the one from the Dock, which
gets no shell and so cannot see anything exported in a profile:

```sh
claude-ollama config --init
```

That writes `~/.config/claude-ollama/config`, a commented `NAME=value` list.
Changes take effect on the next launch; nothing needs reinstalling, because the
app bundle holds no settings of its own — it just calls `claude-ollama`.

`claude-ollama config` prints every setting, its effective value, and whether
that came from the environment, the file or the default. The environment always
wins over the file.

### Claude Desktop

| Variable | Default | Notes |
| --- | --- | --- |
| `RETRIES` | `15` | Claude Code clamps this to 15 for non-Anthropic endpoints, so 15 is the ceiling |
| `SUBAGENTS` | `3` | Concurrent subagents |
| `TIMEOUT_MS` | `1800000` | Request and stream-idle timeout |
| `CONTEXT_TOKENS` | `1048576` | Only reaches models the proxy left untagged |
| `CLASSIFIER` | `claude-haiku-4-5-20251001` | Background classifier model |
| `COMPACT` | `on` | `off` sets `DISABLE_COMPACT=1`, which costs auto-compaction |
| `CLAUDE_APP` | `/Applications/Claude.app` | Which Claude Desktop to launch |

`claude-ollama env` prints exactly what a launch hands to Claude Desktop,
without launching anything.

Tool fan-out is deliberately left at the stock 10. Local reads and greps cost
the gateway nothing, and the only tool in that group that does — Agent — is
already bounded by `SUBAGENTS`.

### Pacing proxy

| Variable | Default | Notes |
| --- | --- | --- |
| `GATEWAY_PORT` | `11435` | Ollama's Claude gateway, on localhost |
| `PACE_UPSTREAM` | `127.0.0.1:11435` | The gateway as `host:port`; wins over `GATEWAY_PORT` |
| `PACE_PORT` | `11436` | Where the proxy listens; a launch moves to the next free port if this one is taken |
| `PACE_LIMIT` | `3` | Requests allowed upstream at once |
| `PACE_ATTEMPTS` | `6` | Tries before giving up on a 429/529/503 |
| `PACE_BASE_DELAY` | `1.0` | Seconds before the first retry |
| `PACE_MAX_DELAY` | `30.0` | Ceiling the delay doubles towards, and the `Retry-After` value |
| `PACE_TIMEOUT` | `1800.0` | Upstream socket timeout, in seconds |
| `PACE_OLLAMA_API` | `127.0.0.1:11434` | Ollama's own API, for reading real context lengths |
| `PACE_TAG_BUDGET` | `2.0` | Seconds a catalog response may spend resolving context lengths before answering without them |
| `PACE_EXIT_WITH_APP` | `on` | `off` leaves the proxy running after Claude quits |
| `PACE_LOG` | `~/.local/state/claude-ollama-pace.log` | Where a proxy started by the launcher writes |

Each has a matching flag — `--limit`, `--attempts`, `--base-delay` and so on —
for `claude-ollama pace`, and a flag beats the variable.

## Why the proxy

Ollama Cloud serves a small fixed number of requests concurrently and returns
529 for the overflow, with no `Retry-After`. Claude Code cannot pace itself
against that — it retries blindly until it runs out of attempts. So the proxy:

1. Holds in-flight requests to `PACE_LIMIT` behind a semaphore. Excess requests
   wait in line locally instead of being rejected upstream.
2. Retries any 429/529/503 that still comes back, with a doubling delay, and
   attaches a real `Retry-After` if it eventually gives up. Retries only ever
   happen before the first response byte, so a partly streamed reply is never
   restarted.

It also fixes two smaller things:

- **Context windows.** Claude Desktop decides a model has a 1M window by
  matching `[1m]` in the model ID, and the gateway never sets it — so every
  model falls back to the 200k default regardless of what it can actually do.
  The proxy reads each model's real `context_length` from Ollama's own API and
  tags the catalog accordingly. `CONTEXT_TOKENS` cannot do this on its own: it
  is ignored for any model whose name starts with `claude-`, and every Ollama
  alias does.
- **The double slash.** The app's setup probe joins its stored base URL with
  `/v1/models` without trimming, asking for `//v1/models`. The gateway's router
  is exact-match and 404s it, which surfaces as "gateway returned no usable
  models" even when inference works fine. The proxy collapses the path.

Reading those context lengths is not free — it is one `/api/show` per model —
and that same setup probe gives the gateway only a few seconds before declaring
the models unusable. So the proxy resolves them all in parallel at startup, the
launcher waits for that to finish before opening Claude, and any lookup still
outstanding when a catalog request arrives is answered without waiting and
filled in for the next one.

One more piece of housekeeping: opening Ollama's settings UI rewrites the
profile's `inferenceGatewayBaseUrl` back to its own port, silently taking the
app off the proxy and losing both the pacing and the context tagging. The
launcher re-asserts it on every start.

## Commands

```
claude-ollama                 launch (same as `run`)
claude-ollama status          what the proxy is doing right now (`--json` too)
claude-ollama restart-proxy   stop the proxy and start it again on the same port
claude-ollama config          every setting, its value and where it came from
claude-ollama config --init   write a commented settings file
claude-ollama config --path   print the settings file's location
claude-ollama doctor          check gateway, proxy, bundle, profile, config
claude-ollama env             print the overrides handed to Claude Desktop
claude-ollama pace [args]     run the proxy in the foreground
claude-ollama install-app     link the bundle into ~/Applications (source installs)
claude-ollama uninstall-app   remove that link
```

## Without Homebrew

```sh
git clone https://github.com/aaditya-v-more/claude-ollama.git
cd claude-ollama
./Tools/make-app.sh . "$PWD/bin/claude-ollama"
./bin/claude-ollama install-app
```

Put `bin` on your `PATH` if you want the command as well. Everything resolves
relative to the checkout, so there is nothing else to set.

`make-app.sh` compiles the menu bar item with `swiftc`. Without the Xcode
command line tools it falls back to a shell launcher that starts Claude and
exits — same behaviour, no menu item.

## Uninstall

```sh
brew uninstall --cask claude-ollama
```

Add `--zap` to take the settings file and the proxy log with it. The profile at
`~/Library/Application Support/Claude-3p` is Claude Desktop's, not this tool's,
and is left alone either way. Delete it yourself if you want the chats gone too.

## Supporting it

Free, and staying that way — no licence to buy, no account to make, nothing
measured and sent anywhere. If it saved you the trouble, there's a
[tip jar](https://ko-fi.com/aadityavmore). Ollama moves its gateway around,
Claude Desktop moves its own furniture every few weeks, and that's what the
money is for.

The same link is under **Support** in the menu bar item.

## Licence

MIT.
