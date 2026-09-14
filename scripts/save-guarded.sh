#!/usr/bin/env bash
# Wrapper around tmux-resurrect's save.sh that bails when a restore is in
# progress. Wired via @resurrect-save-script-path so watcher-scheduled
# auto-saves also honor the lock — without this gate, a save can fire during
# restore, capture partial state (panes still in send-keys handoff, claude argv
# empty), and rotate `last` to the broken snapshot. The pre-restore hook
# then can't find a matching sidecar and bails, breaking @claude-pane-id
# reapply for every pane.
#
# The lock file is created/removed by cmd_resurrect_pre_restore_all and
# cmd_resurrect_post_restore_all in claude-rescue-log.

set -u

RESURRECT_DIR="$(tmux show -gqv @resurrect-dir 2>/dev/null || true)"
LOCK_FILE="${RESURRECT_DIR:-/dev/null}/.restoring"

if [ -n "$RESURRECT_DIR" ] && [ -f "$LOCK_FILE" ]; then
  # Bail silently — restore is in progress. The periodic watcher will retry
  # the due-check after the lock clears.
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

# Remember what `last` points at before the save. tmux-resurrect's save_all()
# writes the new snapshot and then unconditionally rotates `last` onto it — it
# never inspects what it just wrote. If a dump came back empty, the broken file
# silently becomes the next restore source.
prev_last=""
if [ -n "$RESURRECT_DIR" ] && [ -L "$RESURRECT_DIR/last" ]; then
  prev_last="$(readlink "$RESURRECT_DIR/last" 2>/dev/null || true)"
fi

"$REAL_SAVE" "$@"
save_rc=$?

# Structural validation, post-rotation.
#
# Every pane belongs to a window, so a snapshot carrying pane lines and zero
# window lines cannot describe a real server — it is a save that caught the
# server mid-teardown, with dump_panes succeeding and dump_windows returning
# nothing. Restoring from one produces the worst possible outcome: the panes
# come back, so it *looks* like it worked, but with default layouts, no pane
# processes, and no active-window state. That is not hypothetical; it is what
# a 2026-09-14 Ghostty kill produced (61 panes, 0 windows, empty state line,
# every full_command blank), and the restore silently used it.
#
# The test is deliberately narrow so it cannot reject a healthy save: an empty
# server yields zero panes AND zero windows and is left alone. Cost is a grep
# over a file of a few KB that was just written and is still in page cache —
# this runs on every auto-save, so it must stay that cheap.
if [ -n "$RESURRECT_DIR" ] && [ -L "$RESURRECT_DIR/last" ]; then
  now_last="$(readlink "$RESURRECT_DIR/last" 2>/dev/null || true)"
  snapshot="$RESURRECT_DIR/$now_last"
  if [ -n "$now_last" ] && [ "$now_last" != "$prev_last" ] && [ -f "$snapshot" ]; then
    # `grep -c` exits 1 when the count is zero, so `|| echo 0` would append a
    # second line and yield "0\n0" — breaking the integer test on precisely the
    # zero-window case this exists to catch. Swallow the status, keep stdout.
    pane_lines="$(grep -c '^pane' "$snapshot" 2>/dev/null || true)"
    window_lines="$(grep -c '^window' "$snapshot" 2>/dev/null || true)"
    [ -n "$pane_lines" ] || pane_lines=0
    [ -n "$window_lines" ] || window_lines=0
    if [ "$pane_lines" -gt 0 ] && [ "$window_lines" -eq 0 ]; then
      # Quarantine rather than delete: the file is the only evidence of what
      # the dying server reported, and it is wanted for diagnosis.
      mv -f "$snapshot" "$snapshot.rejected" 2>/dev/null || true
      sidecar="${snapshot%.txt}.claude-userops.tsv"
      [ -f "$sidecar" ] && mv -f "$sidecar" "$sidecar.rejected" 2>/dev/null
      if [ -n "$prev_last" ] && [ -f "$RESURRECT_DIR/$prev_last" ]; then
        ln -fs "$prev_last" "$RESURRECT_DIR/last"
        echo "save-guarded: rejected structurally invalid snapshot $now_last" \
             "($pane_lines panes, 0 windows); kept $prev_last as last" >&2
      else
        # No good predecessor. A dangling `last` makes restore a no-op, which
        # is strictly better than restoring a gutted layout over a live server.
        rm -f "$RESURRECT_DIR/last"
        echo "save-guarded: rejected structurally invalid snapshot $now_last" \
             "($pane_lines panes, 0 windows); no valid predecessor to fall back to" >&2
      fi
    fi
  fi
fi

exit $save_rc
