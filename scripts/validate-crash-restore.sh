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
#        - marker cleaned up by session_start when wrapper-launched claude boots
#   2. Hard → save (cmd=zsh) → kill -9 → restore:
#        - restored pane comes back as zsh (no claude)
#        - post-restore-keys subshell runs `claude-rescue print` (capture
#          provenance visible in scrollback)
#        - `clr <sid>` pre-filled at the shell prompt
#        - marker SURVIVES (cleaned up only when user presses Enter and claude
#          actually restarts — protects against a second crash before resume)
#   3. Hard → focus-in → fresh `cl` → hard again → crash → restore:
#        - the NEW session_id is what gets pre-filled, not the original.
#          Catches a regression where session_start fails to clean the old
#          marker (would leave the stale sid on the prompt after restore).
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

# Marker should have been auto-promoted from soft to hard with crash-promote tag,
# then cleaned up by cmd_session_start when the wrapper-launched claude booted.
# Race: the session_start cleanup may run a second or two after the wrapper
# starts; allow a small grace.
PROMOTED_MARKER="$CACHE_DIR/hibernated/$P0_UUID.json"
for _ in 1 2 3 4 5; do
  [ -f "$PROMOTED_MARKER" ] || break
  sleep 1
done
assert "scenario 1: marker cleaned up by session_start after wrapper resume" "0" \
  "$([ -f "$PROMOTED_MARKER" ] && echo 1 || echo 0)"

# Verify post-restore-keys correctly skipped this pane (crash-promote marker
# → skip; the wrapper is auto-resuming so any keys would corrupt the pipeline).
# If the skip were broken, `clr <sid>` would have been sent into the running
# claude as a prompt.
if [ -n "$RESTORED_P0" ]; then
  RESTORED_PANE_CONTENT="$(tmux -L "$SOCK" capture-pane -p -t "$RESTORED_P0" -S - 2>/dev/null)"
  if printf '%s' "$RESTORED_PANE_CONTENT" | grep -q "clr $SAVED_SID"; then
    RESULTS+=("FAIL  scenario 1: post-restore-keys must skip crash-promote panes (found clr in scrollback)")
    FAIL=$((FAIL + 1))
  else
    RESULTS+=("PASS  scenario 1: post-restore-keys correctly skipped crash-promote pane")
    PASS=$((PASS + 1))
  fi
fi

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

# Marker must SURVIVE post-restore-keys (the `clr <sid>` text on the prompt
# is live readline input, not captured by tmux-resurrect; if a second crash
# happens before the user presses Enter, we need the marker to drive another
# round of print + pre-fill). Cleanup is cmd_session_start's job, when the
# user actually presses Enter and claude restarts.
assert "scenario 2: marker survives post-restore-keys (crash-restore insurance)" "1" \
  "$([ -f "$CACHE_DIR/hibernated/$P0_UUID.json" ] && echo 1 || echo 0)"
assert "scenario 2: surviving marker is still mode=hard" "hard" \
  "$(jq -r '.mode // empty' "$CACHE_DIR/hibernated/$P0_UUID.json" 2>/dev/null)"

# ===========================================================================
echo ""
echo "[3] hard -> focus-in -> fresh 'cl' -> hard -> crash -> restore: NEW sid pre-filled"

bring_up_fresh

P0=%0
P0_UUID="$(tmux -L "$SOCK" show-options -pv -t $P0 @claude-pane-id 2>/dev/null)"
ORIGINAL_SID="$(jq -rs --arg p "$P0_UUID" '
  [.[] | select(.pane_uuid == $p and (.kind | startswith("session_start")))]
  | sort_by(.ts) | last | .session_id // empty
' "$DATA_DIR/windows/"*.jsonl 2>/dev/null)"
assert_nonempty "scenario 3: ORIGINAL_SID extracted from pre-hibernation event log" "$ORIGINAL_SID"

# 1. Hard-hibernate the existing claude session.
tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((HARD_DELAY + 8))
assert "scenario 3: post-hard marker mode=hard" "hard" \
  "$(jq -r '.mode // empty' "$CACHE_DIR/hibernated/$P0_UUID.json" 2>/dev/null)"

# 2. Simulate focus-in (marker must survive).
tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-resume #{pane_id}'
sleep 2
assert "scenario 3: marker survives focus-in" "1" \
  "$([ -f "$CACHE_DIR/hibernated/$P0_UUID.json" ] && echo 1 || echo 0)"

# 3. User clears the pre-filled `clr <sid>` and starts a FRESH session via `cl`.
#    Send Ctrl+U to clear the line, then `cl` Enter.
tmux -L "$SOCK" send-keys -t $P0 C-u
sleep 0.5
tmux -L "$SOCK" send-keys -t $P0 "cl" Enter

# Wait for claude to come back.
for _ in $(seq 1 20); do
  CMD="$(tmux -L "$SOCK" display-message -p -t $P0 '#{pane_current_command}' 2>/dev/null)"
  [ "$CMD" = "claude" ] && break
  sleep 1
done
assert "scenario 3: claude foreground after fresh cl" "claude" \
  "$(tmux -L "$SOCK" display-message -p -t $P0 '#{pane_current_command}' 2>/dev/null)"

# Send "hi" to make claude write a transcript (needed by find-sessions on restore).
sleep 2
tmux -L "$SOCK" send-keys -t $P0 "hi" Enter
sleep 5  # let transcript land + session_start hook clean up the old marker

# Marker from the original hibernation should be gone (session_start cleanup).
assert "scenario 3: old marker cleaned by session_start of new session" "0" \
  "$([ -f "$CACHE_DIR/hibernated/$P0_UUID.json" ] && echo 1 || echo 0)"

# Extract the NEW session_id from the latest session_start in the window log.
NEW_SID="$(jq -rs --arg p "$P0_UUID" '
  [.[] | select(.pane_uuid == $p and (.kind | startswith("session_start")))]
  | sort_by(.ts) | last | .session_id // empty
' "$DATA_DIR/windows/"*.jsonl 2>/dev/null)"
assert_nonempty "scenario 3: NEW_SID extracted from post-resume event log" "$NEW_SID"

if [ "$ORIGINAL_SID" = "$NEW_SID" ]; then
  RESULTS+=("FAIL  scenario 3: NEW_SID equals ORIGINAL_SID (fresh cl did not start a new session)")
  FAIL=$((FAIL + 1))
else
  RESULTS+=("PASS  scenario 3: NEW_SID differs from ORIGINAL_SID (fresh session confirmed)")
  PASS=$((PASS + 1))
fi

# 4. Hard-hibernate the NEW session.
tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((HARD_DELAY + 8))
assert "scenario 3: marker for NEW session mode=hard" "hard" \
  "$(jq -r '.mode // empty' "$CACHE_DIR/hibernated/$P0_UUID.json" 2>/dev/null)"

# Capture sidecar must hold the NEW session_id, not the original.
SIDECAR_SID="$(jq -r '.session_id // empty' "$DATA_DIR/captures/$P0_UUID.json" 2>/dev/null)"
assert "scenario 3: capture sidecar references NEW_SID" "$NEW_SID" "$SIDECAR_SID"

# 5. Crash + restore. post-restore-keys should pre-fill `clr <NEW_SID>`.
force_save
kill_server
sleep 1
bash "$REPO/scripts/staging.sh" setup >/dev/null 2>&1
force_restore
sleep 8

RESTORED_P0="$(pane_with_uuid "$P0_UUID")"
assert_nonempty "scenario 3: restored pane found by pane_uuid" "$RESTORED_P0"

if [ -n "$RESTORED_P0" ]; then
  PANE_CONTENT="$(tmux -L "$SOCK" capture-pane -p -t "$RESTORED_P0" -S - 2>/dev/null)"
  assert_contains "scenario 3: post-restore-keys pre-filled clr <NEW_SID>" \
    "❯ clr $NEW_SID" "$PANE_CONTENT"
  if printf '%s' "$PANE_CONTENT" | grep -q "❯ clr $ORIGINAL_SID"; then
    RESULTS+=("FAIL  scenario 3: original sid leaked into prompt (stale marker bug)")
    FAIL=$((FAIL + 1))
  else
    RESULTS+=("PASS  scenario 3: original sid not present in prompt (clean lifecycle)")
    PASS=$((PASS + 1))
  fi
fi

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
