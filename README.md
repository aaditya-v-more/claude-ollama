# claude-ollama

Claude Desktop, pointed at a local Ollama gateway, without editing anything the
app owns.

Two pieces:

- **Environment overrides.** A launcher that starts Claude Desktop with the
  retry, concurrency, timeout and context-window variables set for a
  small self-hosted endpoint. They are process environment only — quit the app
  and nothing remains.
- **A pacing proxy.** A small HTTP proxy in front of the gateway that holds
  requests to a fixed number in flight, retries the ones upstream still
  rejects, and repairs two things the gateway gets wrong on the way through.

Plus a `Claude (Ollama).app` launcher so it has a Dock icon.

## Install

```sh
brew tap aaditya-v-more/tap
brew install claude-ollama
claude-ollama install-app
```

Or in one line: `brew install aaditya-v-more/tap/claude-ollama`.

The formula itself lives in
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

Open **Claude (Ollama)** from `~/Applications`, or run `claude-ollama` in a
terminal. Either way the same thing happens: the proxy starts if it isn't
already up, the profile's endpoint is re-pointed at it, and Claude Desktop
launches with the overrides in its environment.

The proxy exits on its own once the app quits.

## Why the proxy

Ollama Cloud serves a small fixed number of requests concurrently and returns
529 for the overflow, with no `Retry-After`. Claude Code cannot pace itself
against that — it retries blindly until it runs out of attempts. So the proxy:

1. Holds in-flight requests to `--limit` (3 by default) behind a semaphore.
   Excess requests wait in line locally instead of being rejected upstream.
2. Retries any 429/529/503 that still comes back, with a doubling delay, and
   attaches a real `Retry-After` if it eventually gives up. Retries only ever
   happen before the first response byte, so a partly streamed reply is never
   restarted.

It also fixes two smaller things:

- **Context windows.** Claude Desktop decides a model has a 1M window by
  matching `[1m]` in the model ID, and the gateway never sets it — so every
  model falls back to the 200k default regardless of what it can actually do.
  The proxy reads each model's real `context_length` from Ollama's own API and
  tags the catalog accordingly. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` cannot do this
  on its own: it is ignored for any model whose name starts with `claude-`, and
  every Ollama alias does.
- **The double slash.** The app's setup probe joins its stored base URL with
  `/v1/models` without trimming, asking for `//v1/models`. The gateway's router
  is exact-match and 404s it, which surfaces as "gateway returned no usable
  models" even when inference works fine. The proxy collapses the path.

One more piece of housekeeping: opening Ollama's settings UI rewrites the
profile's `inferenceGatewayBaseUrl` back to its own port, silently taking the
app off the proxy and losing both the pacing and the context tagging. The
launcher re-asserts it on every start.

## Tuning

Set any of these for a single launch:

```sh
SUBAGENTS=2 RETRIES=40 claude-ollama
```

| Variable | Default | Notes |
| --- | --- | --- |
| `RETRIES` | `15` | Claude Code clamps this to 15 for non-Anthropic endpoints, so 15 is the ceiling |
| `SUBAGENTS` | `3` | Concurrent subagents |
| `TIMEOUT_MS` | `1800000` | Request and stream-idle timeout |
| `CONTEXT_TOKENS` | `1048576` | Only reaches models the proxy left untagged |
| `CLASSIFIER` | `claude-haiku-4-5-20251001` | Background classifier model |
| `COMPACT` | `on` | `off` sets `DISABLE_COMPACT=1`, which costs auto-compaction |
| `GATEWAY_PORT` | `11435` | Ollama's Claude gateway |
| `PACE_PORT` | `11436` | Where the proxy listens |
| `PACE_LIMIT` | `3` | Requests allowed upstream at once |
| `CLAUDE_APP` | `/Applications/Claude.app` | Which Claude Desktop to launch |

`claude-ollama env` prints exactly what a launch would apply, without launching
anything.

Tool fan-out is deliberately left at the stock 10. Local reads and greps cost
the gateway nothing, and the only tool in that group that does — Agent — is
already bounded by `SUBAGENTS`.

## Commands

```
claude-ollama                 launch (same as `run`)
claude-ollama install-app     link "Claude (Ollama).app" into ~/Applications
claude-ollama uninstall-app   remove that link
claude-ollama doctor          check gateway, proxy, bundle, profile
claude-ollama env             print the overrides a launch would apply
claude-ollama pace [args]     run the proxy in the foreground
```

The proxy's own flags: `--port`, `--upstream`, `--limit`, `--attempts`,
`--base-delay`, `--max-delay`, `--timeout`, `--ollama-api`, `--exit-with-app`.

Its log, when started by the launcher, is at
`~/.local/state/claude-ollama-pace.log`.

## Uninstall

```sh
claude-ollama uninstall-app
brew uninstall claude-ollama
brew untap aaditya-v-more/tap
```

The profile at `~/Library/Application Support/Claude-3p` is Claude Desktop's,
not this tool's, and is left alone. Delete it yourself if you want the chats
gone too.

## Without Homebrew

```sh
git clone https://github.com/aaditya-v-more/claude-ollama.git
cd claude-ollama
./Tools/make-app.sh . "$PWD/bin/claude-ollama"
./bin/claude-ollama install-app
```

Put `bin` on your `PATH` if you want the command as well. Everything resolves
relative to the checkout, so there is nothing else to set.

## Licence

MIT.
