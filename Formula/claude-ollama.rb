class ClaudeOllama < Formula
  desc "Run Claude Desktop against a local Ollama gateway, paced and untouched"
  homepage "https://github.com/aaditya-v-more/homebrew-claude-ollama"
  url "https://github.com/aaditya-v-more/homebrew-claude-ollama/releases/download/v1.0.0/claude-ollama-1.0.0.tar.gz"
  sha256 "0f1b43d44c624d60eff90444bfab2fbad1fb92aefdeac27590fb99f8ba1db1e1"
  license "MIT"
  head "https://github.com/aaditya-v-more/homebrew-claude-ollama.git", branch: "main"

  depends_on :macos

  # Both scripts are pure stdlib — bash and whatever python3 the machine already
  # has, which on macOS means the Command Line Tools copy. Pulling in a keg of
  # Python to run a 400-line proxy would be the larger dependency by far.

  def install
    bin.install "bin/claude-ollama"
    bin.install "bin/claude-ollama-pace"

    # The app bundle is a launcher, not a program: a Dock icon that calls the
    # wrapper. It lives in the keg and is linked into ~/Applications by
    # `claude-ollama install-app`, which is the user's call to make.
    system "./Tools/make-app.sh", prefix, opt_bin/"claude-ollama"

    inreplace bin/"claude-ollama", "@@OPT_PREFIX@@", opt_prefix
  end

  def caveats
    <<~EOS
      Two things are still yours to do:

        claude-ollama install-app   links "Claude (Ollama).app" into ~/Applications
        claude-ollama doctor        checks the gateway, proxy, bundle and profile

      This drives an existing Claude Desktop install at /Applications/Claude.app
      and an Ollama gateway on 127.0.0.1:11435 — it does not install either.
    EOS
  end

  test do
    assert_match "claude-ollama #{version}", shell_output("#{bin}/claude-ollama version")

    # `env` prints the overrides the launcher would apply, without launching
    # anything, so it is the one command that is safe to run in a sandbox.
    overrides = shell_output("#{bin}/claude-ollama env")
    assert_match "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=3", overrides
    assert_match "CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576", overrides
    refute_match "DISABLE_COMPACT", overrides

    assert_match "DISABLE_COMPACT=1",
                 shell_output("COMPACT=off #{bin}/claude-ollama env")

    assert_predicate prefix/"Claude (Ollama).app/Contents/MacOS/launch", :executable?
    system "python3", "-c", "import ast; ast.parse(open('#{bin}/claude-ollama-pace').read())"
  end
end
