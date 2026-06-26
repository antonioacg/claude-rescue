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
#        - `clr <sid>` pre-filled at the shell prompt (no auto `claude-rescue
#          print` — that Enter-terminated step was dropped; capture header must
#          NOT auto-paint)
#        - marker SURVIVES (cleaned up only when user presses Enter and claude
#          actually restarts — protects against a second crash before resume)
#   3. Hard → focus-in → fresh `cl` → hard again → crash → restore:
#        - the NEW session_id is what gets pre-filled, not the original.
#          Catches a regression where session_start fails to clean the old
#          marker (would leave the stale sid on the prompt after restore).
#   4. Wrapper priority — active-file beats stale saved -r:
#        - $DATA/active/<pane_uuid> with a fresh sid wins over a stale -r arg
#          baked into the saved tmux-resurrect cmdline. Catches the regression
#          where in-claude `/resume` switches sessions and the wrapper resumes
#          the wrong (frozen-at-save-time) conversation after a crash-restore.
#   5. Hard → DOUBLE concurrent post-restore (the 2026-06-05 incident):
#        - the post-restore hook fired twice concurrently (continuum auto-
#          restore + restore-wrapper) is idempotent — exactly ONE pre-fill per
#          pane, no executed garble, stray prompt text wiped (C-u), pre-fill
#          cwd-anchored as `cd <launch-cwd> && clr <sid>`.
#   6. Hard → post-restore with a vanished launch dir:
#        - falls back to a bare `clr <sid>` (never emits `cd <gone-dir> &&`,
#          which would fail on Enter).
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

  # The post-restore-keys subshell pre-fills `clr <SAVED_SID>` at the prompt
  # (no Enter, so it's in the line buffer), now anchored with `cd <cwd> &&`.
  # No auto `claude-rescue print` runs anymore (it was the dangerous, Enter-
  # terminated half), so the capture header should NOT be auto-painted.
  PANE_CONTENT="$(tmux -L "$SOCK" capture-pane -p -t "$RESTORED_P0" -S - 2>/dev/null)"
  if printf '%s' "$PANE_CONTENT" | grep -q "# claude-rescue capture"; then
    RESULTS+=("FAIL  scenario 2: auto-print should be gone (capture header auto-painted)")
    FAIL=$((FAIL + 1))
  else
    RESULTS+=("PASS  scenario 2: no auto-print (capture header not auto-painted)")
    PASS=$((PASS + 1))
  fi
  assert_contains "scenario 2: 'clr <saved_sid>' pre-filled at prompt" \
    "clr $SAVED_SID" "$PANE_CONTENT"
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
    "clr $NEW_SID" "$PANE_CONTENT"
  if printf '%s' "$PANE_CONTENT" | grep -q "clr $ORIGINAL_SID"; then
    RESULTS+=("FAIL  scenario 3: original sid leaked into prompt (stale marker bug)")
    FAIL=$((FAIL + 1))
  else
    RESULTS+=("PASS  scenario 3: original sid not present in prompt (clean lifecycle)")
    PASS=$((PASS + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Scenario 4: claude-rescue-resume prefers $DATA/active/<pane_uuid> over the
# saved tmux-resurrect `-r <sid>` cmdline. The frozen cmdline goes stale when
# the user does in-claude `/resume` and switches sessions; the active file is
# rewritten by every cmd_session_start and is the authoritative source.
echo "[scenario 4] claude-rescue-resume prefers active-file over stale saved -r"

# Find any pane with @claude-pane-id set. Scenarios 1-3 leave the staging
# server in various restored states; we just need *some* pane that the
# wrapper can read its uuid from. Pick the first one that satisfies.
S4_PANE_ROW="$(tmux -L "$SOCK" list-panes -aF '#{pane_id}	#{@claude-pane-id}' 2>/dev/null \
  | awk -F'\t' '$2 != "" { print $1 "|" $2; exit }')"
S4_PANE="${S4_PANE_ROW%|*}"
S4_PUUID="${S4_PANE_ROW#*|}"

if [ -z "$S4_PANE" ] || [ -z "$S4_PUUID" ]; then
  RESULTS+=("FAIL  scenario 4: no pane with @claude-pane-id found; cannot exercise wrapper")
  FAIL=$((FAIL + 1))
else
  FRESH_SID="aaaabbbb-1111-2222-3333-444455556666"
  STALE_SID="ffffeeee-9999-8888-7777-666655554444"

  mkdir -p "$DATA_DIR/active"
  printf '%s\n' "$FRESH_SID" > "$DATA_DIR/active/$S4_PUUID"

  # Run the wrapper in --debug. SHELL=/usr/bin/true makes the final `exec
  # "$SHELL" -i` a no-op (zsh -i without a tty would hang). Capture the
  # debug banner from stderr via a file. TMUX_PANE has to be set explicitly
  # (staging.sh does `set-environment -gu TMUX_PANE` to keep claude-inside-
  # staging from confusing it with the outer pane; run-shell -t doesn't
  # export TMUX_PANE to the child).
  S4_OUT="$DATA_DIR/scenario4.err"
  : > "$S4_OUT"
  tmux -L "$SOCK" run-shell -t "$S4_PANE" \
    "SHELL=/usr/bin/true TMUX_PANE=$S4_PANE $REPO/bin/claude-rescue-resume --debug -r $STALE_SID 2>$S4_OUT"
  sleep 1

  S4_TARGET_LINE="$(grep 'resume target' "$S4_OUT" | head -1)"
  S4_ACTIVE_LINE="$(grep 'active-file'   "$S4_OUT" | head -1)"
  assert_contains "scenario 4: active-file line names FRESH_SID"   "$FRESH_SID" "$S4_ACTIVE_LINE"
  assert_contains "scenario 4: resume target line names FRESH_SID" "$FRESH_SID" "$S4_TARGET_LINE"
  if printf '%s' "$S4_TARGET_LINE" | grep -q "$STALE_SID"; then
    RESULTS+=("FAIL  scenario 4: STALE_SID became the resume target (active-file ignored)")
    FAIL=$((FAIL + 1))
  else
    RESULTS+=("PASS  scenario 4: STALE_SID was not used (active-file took priority)")
    PASS=$((PASS + 1))
  fi

  rm -f "$DATA_DIR/active/$S4_PUUID"
fi

# ===========================================================================
echo ""
echo "[5] hard → DOUBLE concurrent post-restore: exactly-once, cwd-anchored, Enter-safe"

bring_up_fresh

P0=%0
P0_UUID="$(tmux -L "$SOCK" show-options -pv -t $P0 @claude-pane-id 2>/dev/null)"
SAVED_SID="$(jq -rs --arg p "$P0_UUID" '
  [.[] | select(.pane_uuid == $p and (.kind | startswith("session_start")))]
  | sort_by(.ts) | last | .session_id // empty
' "$DATA_DIR/windows/"*.jsonl 2>/dev/null)"
assert_nonempty "scenario 5: SAVED_SID extracted" "$SAVED_SID"

# Hard-hibernate → pane ends at zsh with a genuine (non-crash-promote) marker.
tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((HARD_DELAY + 8))
assert "scenario 5: marker mode=hard" "hard" \
  "$(jq -r '.mode // empty' "$CACHE_DIR/hibernated/$P0_UUID.json" 2>/dev/null)"

# Sidecar so cmd_resurrect_restore proceeds to the post-restore subshell.
force_save

# Leave a stray half-typed line on the prompt — the pre-fill's C-u must wipe it.
tmux -L "$SOCK" send-keys -t $P0 "garbage-leftover-xyz"
sleep 0.3

# Scope the idempotency count to this scenario.
: > "$DATA_DIR/send-keys.log"

# Fire the post-restore hook TWICE concurrently — reproduces the two restore
# triggers (continuum auto-restore + restore-wrapper boot path) racing on one
# boot, which is what corrupted the 2026-06-05 restore.
tmux -L "$SOCK" run-shell -b "claude-rescue-log resurrect-restore"
tmux -L "$SOCK" run-shell -b "claude-rescue-log resurrect-restore"
sleep 9   # each subshell: 5s sleep + send-keys

# Exactly ONE pre-fill for this session despite two concurrent passes. This is
# the load-bearing idempotency check: the C-u in each burst means a second
# (un-guarded) pass would still LOOK clean in the pane (it wipes the first
# pre-fill and re-types), so only the send COUNT proves the claim skipped it.
# Match on the bare sid — send_keys_logged %q-quotes the keys, so the space in
# `clr <sid>` is logged as `clr\ <sid>`; the uuid itself is unquoted.
CLR_COUNT="$(grep -c "post-restore-clr.*$SAVED_SID" "$DATA_DIR/send-keys.log" 2>/dev/null || true)"
assert "scenario 5: exactly one post-restore-clr (idempotent under double-fire)" "1" "${CLR_COUNT:-0}"
# Direct proof the guard claimed the pane exactly once.
CLAIM_COUNT="$(find "$CACHE_DIR/post-restore-claims" -mindepth 1 -maxdepth 1 -type d -name "*__$P0_UUID" 2>/dev/null | wc -l | tr -d ' ')"
assert "scenario 5: exactly one idempotency claim dir for the pane" "1" "${CLAIM_COUNT:-0}"

# Pane stayed at the shell — no garbled claude got executed.
assert "scenario 5: pane still zsh (no executed garble)" "zsh" \
  "$(tmux -L "$SOCK" display-message -p -t $P0 '#{pane_current_command}' 2>/dev/null)"

PANE_CONTENT="$(tmux -L "$SOCK" capture-pane -p -t $P0 -S - 2>/dev/null)"
assert_contains "scenario 5: pre-fill is cwd-anchored 'cd .. && clr <sid>'" \
  "cd .* && clr $SAVED_SID" "$PANE_CONTENT"
if printf '%s' "$PANE_CONTENT" | grep -q "garbage-leftover-xyz.*clr $SAVED_SID"; then
  RESULTS+=("FAIL  scenario 5: stray text not cleared before pre-fill (C-u missing)"); FAIL=$((FAIL + 1))
else
  RESULTS+=("PASS  scenario 5: stray prompt text cleared before pre-fill (C-u)"); PASS=$((PASS + 1))
fi
if printf '%s' "$PANE_CONTENT" | grep -qE "clr ${SAVED_SID}[A-Za-z]"; then
  RESULTS+=("FAIL  scenario 5: garbled concatenation after sid (double-fire leaked)"); FAIL=$((FAIL + 1))
else
  RESULTS+=("PASS  scenario 5: no garbled concatenation after sid"); PASS=$((PASS + 1))
fi

# ===========================================================================
echo ""
echo "[6] hard → post-restore with a vanished launch dir: bare 'clr' fallback (no broken cd)"

bring_up_fresh

P0=%0
P0_UUID="$(tmux -L "$SOCK" show-options -pv -t $P0 @claude-pane-id 2>/dev/null)"
SAVED_SID="$(jq -rs --arg p "$P0_UUID" '
  [.[] | select(.pane_uuid == $p and (.kind | startswith("session_start")))]
  | sort_by(.ts) | last | .session_id // empty
' "$DATA_DIR/windows/"*.jsonl 2>/dev/null)"
assert_nonempty "scenario 6: SAVED_SID extracted" "$SAVED_SID"

tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((HARD_DELAY + 8))
assert "scenario 6: marker mode=hard" "hard" \
  "$(jq -r '.mode // empty' "$CACHE_DIR/hibernated/$P0_UUID.json" 2>/dev/null)"
force_save

# Point the only resolvable cwd (capture json — find-sessions won't resolve a
# fixture sid in the real projects dir) at a directory that does not exist.
GONE="/tmp/claude-rescue-gone-$$"
rm -rf "$GONE"
S6_TMP="$(mktemp)"
jq --arg c "$GONE" '.cwd=$c' "$DATA_DIR/captures/$P0_UUID.json" > "$S6_TMP" \
  && mv "$S6_TMP" "$DATA_DIR/captures/$P0_UUID.json"

: > "$DATA_DIR/send-keys.log"
tmux -L "$SOCK" run-shell -b "claude-rescue-log resurrect-restore"
sleep 9

PANE_CONTENT="$(tmux -L "$SOCK" capture-pane -p -t $P0 -S - 2>/dev/null)"
assert_contains "scenario 6: bare 'clr <sid>' pre-filled" "clr $SAVED_SID" "$PANE_CONTENT"
if printf '%s' "$PANE_CONTENT" | grep -q "cd $GONE"; then
  RESULTS+=("FAIL  scenario 6: emitted 'cd <gone-dir>' (would fail on Enter)"); FAIL=$((FAIL + 1))
else
  RESULTS+=("PASS  scenario 6: no 'cd <gone-dir>' emitted (graceful fallback)"); PASS=$((PASS + 1))
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
