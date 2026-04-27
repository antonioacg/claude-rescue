#!/usr/bin/env bash
# Run a command against an isolated tmux server with a fresh CLAUDE_RESCUE_DATA_HOME.
#
# Usage:
#   test/run-isolated.sh <subcommand> [args...]
#
# Subcommands:
#   start                  Start the isolated server (idempotent).
#   stop                   Kill the server and clean up the rescue home.
#   send <target> <keys>   tmux send-keys -t <target> <keys> Enter
#   exec <args...>         tmux -L <socket> <args...>  (raw passthrough)
#   shell                  Attach interactively (foreground).
#   home                   Print the active CLAUDE_RESCUE_DATA_HOME path.
#
# Env:
#   CLAUDE_RESCUE_REPO     Path to the repo (defaults to the script's parent).
#   RESCUE_SOCK            Socket name (default: claude-rescue-test).
#   RESCUE_HOME_PARENT     Parent dir for ephemeral rescue homes (default: /tmp).

set -euo pipefail

REPO="${CLAUDE_RESCUE_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SOCK="${RESCUE_SOCK:-claude-rescue-test}"
HOME_PARENT="${RESCUE_HOME_PARENT:-/tmp}"
HOME_FILE="$HOME_PARENT/claude-rescue-home.$SOCK"

export CLAUDE_RESCUE_REPO="$REPO"

resolve_home() {
  if [ -f "$HOME_FILE" ]; then
    cat "$HOME_FILE"
  else
    return 1
  fi
}

cmd_start() {
  if tmux -L "$SOCK" has-session 2>/dev/null; then
    echo "isolated server '$SOCK' already running" >&2
    return 0
  fi
  local home
  home="$(mktemp -d -t claude-rescue.XXXXXX)"
  echo "$home" > "$HOME_FILE"
  # CLAUDE_RESCUE_REPO is exported only so test.conf can locate rescue.tmux.conf
  # in the dev tree; the rescue config itself uses bare command names (PATH).
  CLAUDE_RESCUE_DATA_HOME="$home" CLAUDE_RESCUE_CACHE_HOME="$home/cache" CLAUDE_RESCUE_REPO="$REPO" PATH="$REPO/bin:$PATH" \
    tmux -L "$SOCK" -f "$REPO/tmux/test/test.conf" \
      new-session -d -s t1 -x 200 -y 50
  tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_DATA_HOME "$home"
  tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_CACHE_HOME "$home/cache"
  tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_REPO "$REPO"
  tmux -L "$SOCK" set-environment -g PATH "$REPO/bin:$PATH"
  echo "started '$SOCK' with CLAUDE_RESCUE_DATA_HOME=$home" >&2
}

cmd_stop() {
  if tmux -L "$SOCK" has-session 2>/dev/null; then
    tmux -L "$SOCK" kill-server || true
  fi
  if [ -f "$HOME_FILE" ]; then
    local home
    home="$(cat "$HOME_FILE")"
    [ -n "$home" ] && [ -d "$home" ] && rm -rf "$home"
    rm -f "$HOME_FILE"
    echo "cleaned up $home" >&2
  fi
}

cmd_send() {
  local target="$1"; shift
  tmux -L "$SOCK" send-keys -t "$target" "$@" Enter
}

cmd_exec() {
  tmux -L "$SOCK" "$@"
}

cmd_shell() {
  tmux -L "$SOCK" attach
}

cmd_home() {
  resolve_home
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  stop)   shift; cmd_stop "$@" ;;
  send)   shift; cmd_send "$@" ;;
  exec)   shift; cmd_exec "$@" ;;
  shell)  shift; cmd_shell "$@" ;;
  home)   shift; cmd_home "$@" ;;
  *)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
    ;;
esac
