#!/usr/bin/env bash
# validate-crash-restore.sh — autonomous validation of behavior across a
# tmux server kill+restore. Exercises both the "soft-saved-as-claude"
# auto-resume path and the "hard-saved-as-zsh" post-restore print + pre-fill
# path.
#
# Scenarios:
#   1. Soft → save → kill -9 → restore:
#        - cwd preserved on the restored pane
#        - resurrect wrapper auto-restarts claude with -r <correct session_id>
#        - marker auto-promoted to mode=hard with hard_source: "crash-promote"
#   2. Hard → save (cmd=zsh) → kill -9 → restore:
#        - restored pane comes back as zsh (no claude)
#        - post-restore-keys subshell runs `claude-rescue print` (capture
#          provenance visible in scrollback)
#        - `clr <sid>` pre-filled at the shell prompt
#        - marker removed after subshell runs
#
# Exit 0 on all-pass, non-zero on any failure. Cleans up on exit.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="claude-rescue-staging"
STAGING_DIR="${CLAUDE_RESCUE_STAGING_DIR:-$HOME/claude-rescue-staging}"
DATA_DIR="$STAGING_DIR/data"
CACHE_DIR="$DATA_DIR/cache"
RESURRECT_DIR="$HOME/.local/share/tmux/resurrect/$SOCK"

SOFT_DELAY="${CLAUDE_RESCUE_SOFT_DELAY:-8}"
HARD_DELAY="${CLAUDE_RESCUE_HARD_DELAY:-16}"

PASS=0
FAIL=0
RESULTS=()

# ---------------------------------------------------------------------------

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    RESULTS+=("PASS  $desc"); PASS=$((PASS + 1))
  else
    RESULTS+=("FAIL  $desc  (expected '$expected' got '$actual')"); FAIL=$((FAIL + 1))
  fi
}

assert_nonempty() {
  local desc="$1" actual="$2"
  if [ -n "$actual" ]; then
    RESULTS+=("PASS  $desc"); PASS=$((PASS + 1))
  else
    RESULTS+=("FAIL  $desc  (got empty)"); FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qE "$needle"; then
    RESULTS+=("PASS  $desc"); PASS=$((PASS + 1))
  else
    RESULTS+=("FAIL  $desc  (pattern '$needle' not found)"); FAIL=$((FAIL + 1))
  fi
}

kill_server() {
  local pid
  pid="$(pgrep -f "tmux.*-L $SOCK" | head -1)"
  if [ -n "$pid" ]; then
    kill -9 "$pid" 2>/dev/null
    # Wait for the socket to be torn down.
    local i
    for i in 1 2 3 4 5; do
      tmux -L "$SOCK" has-session 2>/dev/null || return 0
      sleep 1
    done
  fi
}
trap kill_server EXIT

pane_with_uuid() {
  # Find the pane_id whose @claude-pane-id matches $1. Empty if none.
  tmux -L "$SOCK" list-panes -aF '#{pane_id}	#{@claude-pane-id}' \
    | awk -F'\t' -v u="$1" '$2==u {print $1; exit}'
}

force_save() {
  tmux -L "$SOCK" run-shell '~/.config/tmux/plugins/tmux-resurrect/scripts/save.sh' >/dev/null 2>&1
  sleep 2
}

force_restore() {
  tmux -L "$SOCK" run-shell '~/.config/tmux/plugins/tmux-resurrect/scripts/restore.sh' >/dev/null 2>&1
}

bring_up_fresh() {
  echo "  [setup] kill + wipe + fresh setup + fixture..."
  kill_server
  rm -rf "$DATA_DIR" "$RESURRECT_DIR"
  bash "$REPO/scripts/staging.sh" setup >/dev/null 2>&1
  bash "$REPO/scripts/staging-fixture.sh" >/dev/null 2>&1 \
    || { echo "FATAL: staging-fixture.sh failed" >&2; exit 1; }
  tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_SOFT_DELAY "$SOFT_DELAY"
  tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_HARD_DELAY "$HARD_DELAY"
  tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES 0
}

# ===========================================================================
echo "[1] soft-saved-as-claude → kill -9 → restore: wrapper resumes session"

bring_up_fresh

# Target main:1.1 — claude in $STAGING_DIR (cwd ≠ default home, so we can verify cwd preservation).
P0=%0
P0_UUID="$(tmux -L "$SOCK" show-options -pv -t $P0 @claude-pane-id 2>/dev/null)"
[ -z "$P0_UUID" ] && { echo "FATAL: $P0 missing @claude-pane-id" >&2; exit 1; }
SAVED_SID="$(jq -rs --arg p "$P0_UUID" '
  [.[] | select(.pane_uuid == $p and (.kind | startswith("session_start")))]
  | sort_by(.ts) | last | .session_id // empty
' "$DATA_DIR/windows/"*.jsonl 2>/dev/null)"
SAVED_CWD="$STAGING_DIR"
assert_nonempty "scenario 1: SAVED_SID extracted from pre-crash event log" "$SAVED_SID"

# Soft hibernate (no resume) — claude remains in T, save will capture
# pane_current_command=zsh (foreground) but the full command stays claude.
tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((SOFT_DELAY + 4))

# Confirm we're in soft state before saving.
assert "scenario 1: pre-crash marker mode=soft" "soft" \
  "$(jq -r '.mode // empty' "$CACHE_DIR/hibernated/$P0_UUID.json" 2>/dev/null)"

# Save → crash → restore.
force_save
kill_server
sleep 1
bash "$REPO/scripts/staging.sh" setup >/dev/null 2>&1
force_restore
sleep 6   # let resurrect finish + post-restore-keys subshell sleep (5s) elapse

# Find the restored pane by its @claude-pane-id.
RESTORED_P0="$(pane_with_uuid "$P0_UUID")"
assert_nonempty "scenario 1: restored pane found by pane_uuid" "$RESTORED_P0"

if [ -n "$RESTORED_P0" ]; then
  RESTORED_CWD="$(tmux -L "$SOCK" display-message -p -t "$RESTORED_P0" '#{pane_current_path}' 2>/dev/null)"
  RESTORED_CMD="$(tmux -L "$SOCK" display-message -p -t "$RESTORED_P0" '#{pane_current_command}' 2>/dev/null)"
  assert "scenario 1: cwd preserved" "$SAVED_CWD" "$RESTORED_CWD"
  assert "scenario 1: wrapper restarted claude (cmd=claude)" "claude" "$RESTORED_CMD"

  # The claude process command line should include -r <SAVED_SID>.
  PANE_PID="$(tmux -L "$SOCK" display-message -p -t "$RESTORED_P0" '#{pane_pid}' 2>/dev/null)"
  CLAUDE_PID="$(pgrep -P "$PANE_PID" claude 2>/dev/null | head -1)"
  CLAUDE_ARGS="$(ps -p "$CLAUDE_PID" -o args= 2>/dev/null || true)"
  assert_contains "scenario 1: claude resumed with -r <saved session_id>" \
    "\\-r $SAVED_SID" "$CLAUDE_ARGS"
fi

# Marker should have been auto-promoted from soft to hard with crash-promote tag.
PROMOTED_MARKER="$CACHE_DIR/hibernated/$P0_UUID.json"
assert "scenario 1: marker auto-promoted to mode=hard" "hard" \
  "$(jq -r '.mode // empty' "$PROMOTED_MARKER" 2>/dev/null)"
assert "scenario 1: hard_source=crash-promote" "crash-promote" \
  "$(jq -r '.hard_source // empty' "$PROMOTED_MARKER" 2>/dev/null)"

# ===========================================================================
echo ""
echo "[2] hard-saved-as-zsh → kill -9 → restore: post-restore-keys runs"

bring_up_fresh

P0=%0
P0_UUID="$(tmux -L "$SOCK" show-options -pv -t $P0 @claude-pane-id 2>/dev/null)"
SAVED_SID="$(jq -rs --arg p "$P0_UUID" '
  [.[] | select(.pane_uuid == $p and (.kind | startswith("session_start")))]
  | sort_by(.ts) | last | .session_id // empty
' "$DATA_DIR/windows/"*.jsonl 2>/dev/null)"
assert_nonempty "scenario 2: SAVED_SID extracted from pre-crash event log" "$SAVED_SID"

# Soft → wait for hard escalation. Pane should end at shell with `clr <sid>` pre-filled.
tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((HARD_DELAY + 8))

assert "scenario 2: pre-crash marker mode=hard" "hard" \
  "$(jq -r '.mode // empty' "$CACHE_DIR/hibernated/$P0_UUID.json" 2>/dev/null)"

# Now save (pane is zsh foreground, no claude) → crash → restore.
force_save
kill_server
sleep 1
bash "$REPO/scripts/staging.sh" setup >/dev/null 2>&1
force_restore
sleep 8   # restore + post-restore-keys (5s sleep) + send-keys propagation

RESTORED_P0="$(pane_with_uuid "$P0_UUID")"
assert_nonempty "scenario 2: restored pane found by pane_uuid" "$RESTORED_P0"

if [ -n "$RESTORED_P0" ]; then
  RESTORED_CMD="$(tmux -L "$SOCK" display-message -p -t "$RESTORED_P0" '#{pane_current_command}' 2>/dev/null)"
  assert "scenario 2: restored pane is zsh (not auto-resumed)" "zsh" "$RESTORED_CMD"

  # The post-restore-keys subshell should have run `claude-rescue print` (provenance visible)
  # and pre-filled `clr <SAVED_SID>` at the prompt (no Enter, so it's in the line buffer).
  PANE_CONTENT="$(tmux -L "$SOCK" capture-pane -p -t "$RESTORED_P0" -S - 2>/dev/null)"
  assert_contains "scenario 2: 'claude-rescue capture' header in scrollback" \
    "# claude-rescue capture" "$PANE_CONTENT"
  assert_contains "scenario 2: 'clr <saved_sid>' pre-filled at prompt" \
    "❯ clr $SAVED_SID" "$PANE_CONTENT"
fi

# Marker should be removed by the post-restore-keys subshell.
assert "scenario 2: marker removed after post-restore-keys" "0" \
  "$([ -f "$CACHE_DIR/hibernated/$P0_UUID.json" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# Summary

echo ""
echo "==================="
echo "Validation summary:"
echo "==================="
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
