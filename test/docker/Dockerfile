# Linux test image for the dual-trigger restore harness.
#
# Purpose: run a REAL tmux + tmux-resurrect + tmux-continuum + claude stack in
# full isolation, so the test server is the ONLY tmux server. That makes
# continuum's own auto-restore fire (it self-suppresses when another tmux
# server is running) AND the boot-guard restore-wrapper fire — the genuine
# production dual restore-trigger that caused the 2026-06-05 incident. This is
# the only way to faithfully exercise that race (impossible on the host, where
# the live default server suppresses continuum's auto-restore).
#
# Runs as a NON-ROOT user: claude refuses --permission-mode bypassPermissions
# under root, and production runs as a normal user — so the cl/clr aliases the
# restore path pre-fills only work non-root. This matches production.
#
# The claude-rescue working tree, tmux plugins, restore-wrapper, zsh aliases,
# and credentials are MOUNTED at runtime (see run.sh) so the image stays stable
# and we test the working tree directly.
FROM debian:bookworm-slim

# This host's clock reads 2026, which makes apt see the Debian archive signing
# keys as expired ("invalid signature"). Throwaway LOCAL test image only —
# disable apt signature checks rather than fight the clock. Never ship this.
RUN printf 'Acquire::Check-Valid-Until "false";\nAcquire::AllowInsecureRepositories "true";\nAPT::Get::AllowUnauthenticated "true";\n' \
      > /etc/apt/apt.conf.d/99insecure
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq bash coreutils zsh procps psmisc less uuid-runtime \
      build-essential libevent-dev libncurses-dev bison pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Non-root user; /work writable by them.
RUN useradd -m -s /usr/bin/zsh -u 1000 tester \
    && mkdir -p /work && chown tester:tester /work
USER tester
ENV HOME=/home/tester
WORKDIR /home/tester

# claude, tmux, neovim, node ALL via mise, pinned by the mise.toml config file
# (a faithful mirror of the host's ~/.config/mise/config.toml) so the
# version-sensitive restore hooks behave identically to production. mise's aqua
# backends fetch prebuilt tmux/neovim binaries; the build deps above are a
# fallback if aqua lacks this arch and mise source-builds.
COPY --chown=tester:tester mise.toml /home/tester/.config/mise/config.toml
RUN curl -fsSL https://mise.run | sh
ENV PATH="/home/tester/.local/bin:/home/tester/.local/share/mise/shims:/opt/claude-rescue/bin:${PATH}"
RUN mise install \
    && tmux -V && nvim --version | head -1 && claude --version

# Minimal zsh rc: source the (mounted) cl/clr aliases if present; keep PATH.
RUN printf '%s\n' \
  'export PATH=/home/tester/.local/bin:/home/tester/.local/share/mise/shims:/opt/claude-rescue/bin:$PATH' \
  '[ -f $HOME/.config/zsh/aliases.zsh ] && source $HOME/.config/zsh/aliases.zsh 2>/dev/null' \
  'PROMPT="%~ %# "' \
  > /home/tester/.zshrc

ENV SHELL=/usr/bin/zsh
WORKDIR /work
CMD ["sleep", "infinity"]
