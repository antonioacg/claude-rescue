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

# Path to the real save script. Overridable via env for validate.sh
# (which exercises this wrapper's lock-check behavior without invoking
# tmux-resurrect's real save against the live resurrect-dir).
REAL_SAVE="${CLAUDE_RESCUE_RESURRECT_SAVE:-$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh}"
if [ ! -x "$REAL_SAVE" ]; then
  echo "save-guarded: tmux-resurrect save.sh not found at $REAL_SAVE" >&2
  exit 1
fi

exec "$REAL_SAVE" "$@"
