#!/usr/bin/env bash
# Wrapper around tmux-resurrect's save.sh that bails when a restore is in
# progress. Wired via @resurrect-save-script-path so tmux-continuum's
# auto-save (status-bar-interval driven) also honors the lock — without
# this gate, continuum's save fires during restore, captures partial state
# (panes still in send-keys handoff, claude argv empty), and rotates `last`
# to point at the partial snapshot. The pre-restore-pane-processes hook
# then can't find a matching sidecar and bails, breaking @claude-pane-id
# reapply for every pane.
#
# The lock file is created/removed by cmd_resurrect_pre_restore_all and
# cmd_resurrect_post_restore_all in claude-rescue-log.

set -u

RESURRECT_DIR="$(tmux show -gqv @resurrect-dir 2>/dev/null || true)"
LOCK_FILE="${RESURRECT_DIR:-/dev/null}/.restoring"

if [ -n "$RESURRECT_DIR" ] && [ -f "$LOCK_FILE" ]; then
  # Bail silently — restore is in progress. tmux's status-right is the
  # caller; surfacing an error here would clutter the status line.
  exit 0
fi

# Bundle the async sampler's per-pane scrollback into pane_contents.tar.gz
# before the real save runs. With @resurrect-capture-pane-contents off,
# save.sh leaves this tar alone — so we get scrollback restore without ever
# letting capture-pane block tmux's main thread during the save. If the
# sampler hasn't populated anything yet (cold start, never ran), this is a
# no-op and save just writes a .txt with no pane_contents.
DATA_HOME="${CLAUDE_RESCUE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-rescue}"
# Per-server scrollback dir matches the convention @resurrect-dir already
# uses (basename of socket_path). For the live default server this is
# $DATA/scrollback/default; a second test server gets its own dir and its
# own watcher writes into it independently. Fall back to "default" when the
# resurrect-dir basename can't be derived (shouldn't happen in practice).
SERVER_NAME="$(basename "${RESURRECT_DIR:-/default}")"
[ -z "$SERVER_NAME" ] && SERVER_NAME="default"
SCROLLBACK_DIR="$DATA_HOME/scrollback/$SERVER_NAME"
if [ -n "$RESURRECT_DIR" ] && [ -d "$SCROLLBACK_DIR" ]; then
  # Only bundle if at least one pane-* file is present. Globbing in a guard
  # so an empty dir doesn't produce an empty tar.
  if compgen -G "$SCROLLBACK_DIR/pane-*" >/dev/null 2>&1; then
    tar_stage="$(mktemp -d -t claude-rescue-tar.XXXXXX)"
    mkdir -p "$tar_stage/pane_contents"
    # Hardlink instead of copy — same filesystem, near-zero cost.
    for f in "$SCROLLBACK_DIR"/pane-*; do
      ln "$f" "$tar_stage/pane_contents/$(basename "$f")" 2>/dev/null \
        || cp "$f" "$tar_stage/pane_contents/$(basename "$f")" 2>/dev/null \
        || true
    done
    # Write atomically: tar to .tmp, mv into place.
    if ( cd "$tar_stage" && tar cf - pane_contents/ | gzip > "$RESURRECT_DIR/pane_contents.tar.gz.tmp" ); then
      mv -f "$RESURRECT_DIR/pane_contents.tar.gz.tmp" "$RESURRECT_DIR/pane_contents.tar.gz"
    else
      rm -f "$RESURRECT_DIR/pane_contents.tar.gz.tmp"
    fi
    rm -rf "$tar_stage"
  fi
fi

# Path to the real save script. Overridable via env for validate.sh
# (which exercises this wrapper's lock-check behavior without invoking
# tmux-resurrect's real save against the live resurrect-dir).
REAL_SAVE="${CLAUDE_RESCUE_RESURRECT_SAVE:-$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh}"
if [ ! -x "$REAL_SAVE" ]; then
  echo "save-guarded: tmux-resurrect save.sh not found at $REAL_SAVE" >&2
  exit 1
fi

exec "$REAL_SAVE" "$@"
