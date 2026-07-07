#!/usr/bin/env bash
# validate-hibernation.sh — autonomous validation of the hibernation lifecycle.
#
# Tears down any running staging, brings up a fresh server, populates the
# fixture, then drives the hibernation scenarios via tmux run-shell (focus
# events don't fire reliably without an attached client, so we invoke the
# arm/resume subcommands directly — same code path the focus hooks trigger).
#
# Scenarios:
#   1s. suspend_hibernation (per-session opt-out from the `prefix + a` popup)
#       makes hibernate-arm a no-op — no marker, no arm.pid, no Ctrl+Z; blocks
#       both soft and hard. Scenario 1 is its positive control.
#   1. Soft hibernation fires on an idle claude pane (capture + Ctrl+Z + marker)
#   2. Soft resume restores the suspended claude
#   3. Hard escalation fires after HARD_DELAY (claude exits + clr pre-fill)
#   3b. Hard marker survives focus-in (no-op, no spurious unhibernated event)
#   3c. Hard marker cleaned up by session_start when claude restarts in pane
#   4. Fast guard skips panes without @claude-pane-id (nvim)
#   5. Orphan arm subshell self-bails on @claude-pane-id mismatch — no action
#      taken against a pane whose identity has changed since the timer armed.
#   6. arm-sweep arms every backgrounded claude pane in one shot (so the user
#      doesn't have to physically visit each pane to start its countdown).
#   7. hibernate-resume preserves the in-flight arm subshell when the marker
#      is mode=hard (post-/exit cleanup is sending `clr <sid>` to the prompt
#      — killing the subshell mid-flight would drop the pre-fill). For
#      mode=soft (or no marker), the kill still happens — that's how
#      focus-in cancels a pending hibernation.
#   8. SessionEnd reaps arm.pid + active session file (the bug that left 27
#      orphan arm.pid files in production after users dismissed claude's
#      "Resume from summary?" dialog). @claude-pane-id is KEPT — it's the
#      identity bridge the hibernation marker (and find-sessions) depend on.
#   9. arm-sweep detects voluntary-exit (pane has @claude-pane-id but is not
#      running claude, no busy marker, no hibernation marker) and cleans up
#      arm.pid + active file + unsets @claude-pane-id. Catches hook-skipping
#      exit paths (SIGKILL, hard crashes) that SessionEnd never sees.
#  11. On-demand hibernate/restore (the `prefix + a` popup row). hibernate-now
#      forces a hard hibernation immediately (bypassing SOFT/HARD delays and the
#      busy/active guards) AND clears suspend_hibernation; hibernate-state
#      reports none→hard; restore-now on a hard pane types `clr <sid>` at the
#      shell prompt (smart about a text shell) and claude comes back.
#
# Timing: with SOFT_DELAY=8 / HARD_DELAY=16 the script runs in ~90s including
# fixture boot. Exit 0 on all-pass, non-zero on any failure.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="claude-rescue-staging"
STAGING_DIR="${CLAUDE_RESCUE_STAGING_DIR:-$HOME/claude-rescue-staging}"
DATA_DIR="$STAGING_DIR/data"
CACHE_DIR="$DATA_DIR/cache"

SOFT_DELAY="${CLAUDE_RESCUE_SOFT_DELAY:-8}"
HARD_DELAY="${CLAUDE_RESCUE_HARD_DELAY:-16}"
DEFER_TIMES="${CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES:-0}"

PASS=0
FAIL=0
RESULTS=()

# ---------------------------------------------------------------------------

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    RESULTS+=("PASS  $desc")
    PASS=$((PASS + 1))
  else
    RESULTS+=("FAIL  $desc  (expected '$expected' got '$actual')")
    FAIL=$((FAIL + 1))
  fi
}

assert_nonempty() {
  local desc="$1" actual="$2"
  if [ -n "$actual" ]; then
    RESULTS+=("PASS  $desc")
    PASS=$((PASS + 1))
  else
    RESULTS+=("FAIL  $desc  (got empty)")
    FAIL=$((FAIL + 1))
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    RESULTS+=("PASS  $desc")
    PASS=$((PASS + 1))
  else
    RESULTS+=("FAIL  $desc  (expected empty, got '$actual')")
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  if tmux -L "$SOCK" has-session 2>/dev/null; then
    local pid
    pid="$(pgrep -f "tmux.*-L $SOCK" | head -1)"
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  fi
}
trap cleanup EXIT

# Return the @claude-pane-id of a pane.
pane_uuid_of() {
  tmux -L "$SOCK" show-options -pv -t "$1" @claude-pane-id 2>/dev/null
}

# Read the hibernated marker's pids array (one pid per line).
marker_pids() {
  jq -r '.pids[]?' "$CACHE_DIR/hibernated/$1.json" 2>/dev/null
}

# Return the foreground command of a pane (claude | zsh | nvim | ...).
fg_cmd() {
  tmux -L "$SOCK" display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# Read the first character of `ps stat` for a pid (T = stopped, S = sleeping, etc.).
# Empty if pid is dead or unreadable.
pid_stat() {
  ps -o stat= -p "$1" 2>/dev/null | tr -d ' ' | cut -c1
}

# 1 if all pids in $@ respond to kill -0 (alive); 0 otherwise.
pids_all_alive() {
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    kill -0 "$p" 2>/dev/null || { echo 0; return; }
  done
  echo 1
}

# 1 if NO pid in $@ responds to kill -0 (all dead); 0 if any alive.
pids_all_dead() {
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    kill -0 "$p" 2>/dev/null && { echo 0; return; }
  done
  echo 1
}

# ---------------------------------------------------------------------------
# Bring up clean state.

echo "[setup] tearing down + fresh staging + fixture..."
cleanup
rm -rf "$DATA_DIR"
rm -rf "$HOME/.local/share/tmux/resurrect/$SOCK"
bash "$REPO/scripts/staging.sh" setup >/dev/null 2>&1
bash "$REPO/scripts/staging-fixture.sh" >/dev/null 2>&1 \
  || { echo "FATAL: staging-fixture.sh failed" >&2; exit 1; }

tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_SOFT_DELAY "$SOFT_DELAY"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_HARD_DELAY "$HARD_DELAY"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES "$DEFER_TIMES"

# Snapshot the panes we'll test against.
P0=%0    # main:1.1, claude in staging
P3=%3    # main:3.1, nvim
P0_UUID="$(pane_uuid_of $P0)"
[ -z "$P0_UUID" ] && { echo "FATAL: $P0 has no @claude-pane-id" >&2; exit 1; }

# ---------------------------------------------------------------------------
echo "[1s] suspend_hibernation opt-out bails hibernate-arm (no soft, no hard)"

# Set the per-session knob the `prefix + a` popup writes, then arm. The arm
# must bail before scheduling anything — no marker, no arm.pid, claude never
# Ctrl+Z'd. Scenario 1 (immediately below, same pane) is the positive control:
# with the flag cleared, the identical arm DOES hibernate.
SID_S="$(cat "$DATA_DIR/active/$P0_UUID" 2>/dev/null | head -1 | tr -d '\n')"
assert_nonempty "scenario 1s: P0 has an active session_id" "$SID_S"
SAN0="${P0//[^A-Za-z0-9]/_}"
ARMPID0="$CACHE_DIR/hibernated/$SAN0.arm.pid"
MARKER0="$CACHE_DIR/hibernated/$P0_UUID.json"
rm -f "$ARMPID0" "$MARKER0"
mkdir -p "$DATA_DIR/session-config"
printf '{"suspend_hibernation":true}\n' > "$DATA_DIR/session-config/$SID_S.json"

tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((SOFT_DELAY + 4))

assert "scenario 1s: no hibernated marker (arm bailed)" "0" "$([ -f "$MARKER0" ] && echo 1 || echo 0)"
assert "scenario 1s: no arm.pid scheduled (bailed before the timer)" "0" "$([ -f "$ARMPID0" ] && echo 1 || echo 0)"
assert "scenario 1s: claude still foreground (never Ctrl+Z'd)" "claude" "$(fg_cmd $P0)"

# Clear the flag so the remaining scenarios (the positive controls) arm normally.
rm -f "$DATA_DIR/session-config/$SID_S.json"

# ---------------------------------------------------------------------------
echo "[1] soft hibernation fires on idle claude pane"

tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((SOFT_DELAY + 4))

MARKER="$CACHE_DIR/hibernated/$P0_UUID.json"
assert "scenario 1: hibernated marker exists" "1" "$([ -f "$MARKER" ] && echo 1 || echo 0)"
assert "scenario 1: marker mode=soft" "soft" "$(jq -r '.mode // empty' "$MARKER" 2>/dev/null)"
assert "scenario 1: capture .txt written" "1" "$([ -f "$DATA_DIR/captures/$P0_UUID.txt" ] && echo 1 || echo 0)"
assert "scenario 1: capture .json sidecar written" "1" "$([ -f "$DATA_DIR/captures/$P0_UUID.json" ] && echo 1 || echo 0)"
CAP_CWD="$(jq -r '.cwd // empty' "$DATA_DIR/captures/$P0_UUID.json" 2>/dev/null)"
assert "scenario 1: capture cwd matches pane cwd" "$STAGING_DIR" "$CAP_CWD"
assert_nonempty "scenario 1: capture session_id non-empty" "$(jq -r '.session_id // empty' "$DATA_DIR/captures/$P0_UUID.json" 2>/dev/null)"

# Foreground process is the shell (claude Ctrl+Z'd to background).
assert "scenario 1: pane_current_command is zsh (claude no longer foreground)" "zsh" "$(fg_cmd $P0)"

# The arm function recorded the claude pids it found into the marker.
# Snapshot them — we'll re-check liveness through the resume + hard cycles.
read -r -a SOFT_PIDS <<< "$(marker_pids "$P0_UUID" | tr '\n' ' ')"
assert "scenario 1: marker recorded ≥1 claude pid" "1" "$([ "${#SOFT_PIDS[@]}" -gt 0 ] && echo 1 || echo 0)"
assert "scenario 1: all marker pids alive after soft (suspended, not killed)" "1" "$(pids_all_alive "${SOFT_PIDS[@]}")"
# Bonus: the marker's first pid should be in T state (kernel-level confirmation).
assert "scenario 1: marker's first pid in T (stopped) state" "T" "$(pid_stat "${SOFT_PIDS[0]:-}")"

# ---------------------------------------------------------------------------
echo "[2] soft resume unfreezes claude"

tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-resume #{pane_id}'
sleep 2

assert "scenario 2: marker removed after resume" "0" "$([ -f "$MARKER" ] && echo 1 || echo 0)"
assert_nonempty "scenario 2: capture preserved across resume" "$(ls "$DATA_DIR/captures/$P0_UUID.txt" 2>/dev/null)"
assert "scenario 2: pane_current_command back to claude" "claude" "$(fg_cmd $P0)"
assert "scenario 2: snapshot pids still alive" "1" "$(pids_all_alive "${SOFT_PIDS[@]}")"

# ---------------------------------------------------------------------------
echo "[3] hard escalation fires after HARD_DELAY"

# Re-arm and let it ride through soft → hard.
tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
# Wait long enough for both stages + buffer for the /exit kill sequence.
sleep $((HARD_DELAY + 8))

assert "scenario 3: marker mode=hard after escalation" "hard" "$(jq -r '.mode // empty' "$MARKER" 2>/dev/null)"
assert_nonempty "scenario 3: hard_ts recorded" "$(jq -r '.hard_ts // empty' "$MARKER" 2>/dev/null)"
# Pick up the latest pids the second arm recorded (might match SOFT_PIDS, might be more if claude spawned children).
read -r -a HARD_PIDS <<< "$(marker_pids "$P0_UUID" | tr '\n' ' ')"
assert "scenario 3: all marker pids dead after hard" "1" "$(pids_all_dead "${HARD_PIDS[@]}")"
# Pane should be back at zsh with `clr <sid>` pre-filled.
assert "scenario 3: pane_current_command is zsh" "zsh" "$(fg_cmd $P0)"
PANE_CONTENT="$(tmux -L "$SOCK" capture-pane -p -t $P0 | tail -5)"
HAS_CLR="$(printf '%s' "$PANE_CONTENT" | grep -c '^.*❯ clr [0-9a-f]\{8\}-' || true)"
assert "scenario 3: 'clr <sid>' pre-filled at shell prompt" "1" "$HAS_CLR"

# ---------------------------------------------------------------------------
echo "[3b] hard marker survives focus-in (hibernate-resume is a no-op for hard mode)"

# Locate the window jsonl for this pane so we can read event history.
P0_WIN_LOG="$(grep -l "\"pane_uuid\":\"$P0_UUID\"" "$DATA_DIR"/windows/*.jsonl 2>/dev/null | head -1)"
[ -z "$P0_WIN_LOG" ] && { echo "FATAL: no window log for $P0_UUID" >&2; exit 1; }

# Record current event tail length so we can detect events fired by focus-in.
EVENTS_BEFORE_FOCUSIN="$(wc -l < "$P0_WIN_LOG" | tr -d ' ')"

tmux -L "$SOCK" run-shell -t $P0 'claude-rescue-log hibernate-resume #{pane_id}'
sleep 2

assert "scenario 3b: hard marker still present after focus-in" "1" \
  "$([ -f "$MARKER" ] && echo 1 || echo 0)"
assert "scenario 3b: marker mode still hard" "hard" \
  "$(jq -r '.mode // empty' "$MARKER" 2>/dev/null)"

UNHIB_FROM_FOCUSIN="$(tail -n +"$((EVENTS_BEFORE_FOCUSIN + 1))" "$P0_WIN_LOG" \
  | jq -rc 'select(.kind == "unhibernated" and .pane_uuid == "'"$P0_UUID"'")' \
  | wc -l | tr -d ' ')"
assert "scenario 3b: no unhibernated event emitted by focus-in" "0" "$UNHIB_FROM_FOCUSIN"

assert "scenario 3b: pane still at zsh prompt (claude not back)" "zsh" "$(fg_cmd $P0)"

# ---------------------------------------------------------------------------
echo "[3c] hard marker cleaned up by session_start when claude restarts in pane"

# Read the session_id off the existing `clr <sid>` pre-fill (set in scenario 3).
# Pressing Enter invokes claude-rescue-resume which starts claude --resume <sid>,
# which fires a SessionStart hook → cmd_session_start should clean up the marker.
EVENTS_BEFORE_RESUME="$(wc -l < "$P0_WIN_LOG" | tr -d ' ')"
tmux -L "$SOCK" send-keys -t $P0 Enter

# Wait up to 20s for claude to come back as foreground.
RESUMED=0
for _ in $(seq 1 20); do
  if [ "$(fg_cmd $P0)" = "claude" ]; then RESUMED=1; break; fi
  sleep 1
done
assert "scenario 3c: claude is foreground after Enter on clr pre-fill" "1" "$RESUMED"

# Give the SessionStart hook a moment to run.
sleep 2

assert "scenario 3c: hibernated marker removed by session_start" "0" \
  "$([ -f "$MARKER" ] && echo 1 || echo 0)"

NEW_EVENTS="$(tail -n +"$((EVENTS_BEFORE_RESUME + 1))" "$P0_WIN_LOG")"
SESSION_STARTS="$(printf '%s\n' "$NEW_EVENTS" \
  | jq -rc 'select(.kind == "session_start" and .pane_uuid == "'"$P0_UUID"'")' \
  | wc -l | tr -d ' ')"
assert "scenario 3c: session_start event fired for the resumed claude" "1" \
  "$([ "$SESSION_STARTS" -ge 1 ] && echo 1 || echo 0)"

UNHIB_HARD="$(printf '%s\n' "$NEW_EVENTS" \
  | jq -rc 'select(.kind == "unhibernated" and .pane_uuid == "'"$P0_UUID"'" and .mode == "hard")' \
  | wc -l | tr -d ' ')"
assert "scenario 3c: unhibernated(mode=hard) emitted by session_start cleanup" "1" \
  "$([ "$UNHIB_HARD" -ge 1 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
echo "[4] fast guard skips panes without @claude-pane-id"

P3_UUID="$(pane_uuid_of $P3)"
assert_empty "scenario 4: nvim pane has no @claude-pane-id" "$P3_UUID"

P3_NVIM_PID="$(tmux -L "$SOCK" display-message -p -t $P3 '#{pane_pid}' 2>/dev/null)"
tmux -L "$SOCK" run-shell -t $P3 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep $((SOFT_DELAY + 3))

# Sanitized pane id for the arm pid file naming.
P3_SAN="${P3//[^A-Za-z0-9]/_}"
assert "scenario 4: no arm pid file for nvim pane" "0" \
  "$([ -f "$CACHE_DIR/hibernated/$P3_SAN.arm.pid" ] && echo 1 || echo 0)"
# Marker keyed by pane_uuid — empty for nvim, so the file path would be /captures/.json (malformed). Just check no file was added.
NVIM_MARKERS="$(find "$CACHE_DIR/hibernated" -type f -newer "$MARKER" 2>/dev/null | wc -l | tr -d ' ')"
assert "scenario 4: no new marker after fast-guard reject" "0" "$NVIM_MARKERS"

# ---------------------------------------------------------------------------
echo "[5] orphan arm subshell self-bails on identity mismatch"

# Use %2 (claude in projectB, window 2). %2 is currently focused in its window,
# so to arm we just run hibernate-arm directly via tmux run-shell (same code
# path as the focus-out hook would invoke).
P2=%2
P2_UUID="$(pane_uuid_of $P2)"
[ -z "$P2_UUID" ] && { echo "FATAL: $P2 has no @claude-pane-id" >&2; exit 1; }
P2_SAN="${P2//[^A-Za-z0-9]/_}"
P2_ARM_FILE="$CACHE_DIR/hibernated/$P2_SAN.arm.pid"
P2_MARKER="$CACHE_DIR/hibernated/$P2_UUID.json"

# Capture P2's claude pid up front — we'll verify it's still alive after the
# orphan should have fired (the kill_only_if_comm guard must not let an
# identity-mismatched subshell signal it).
P2_PANE_PID="$(tmux -L "$SOCK" display-message -p -t $P2 '#{pane_pid}' 2>/dev/null)"
P2_CLAUDE_PID="$(pgrep -P "$P2_PANE_PID" claude 2>/dev/null | head -1)"
assert_nonempty "scenario 5: P2's claude pid resolvable before arm" "$P2_CLAUDE_PID"

# Locate P2's window log for event-tail comparison.
P2_WIN_LOG="$(grep -l "\"pane_uuid\":\"$P2_UUID\"" "$DATA_DIR"/windows/*.jsonl 2>/dev/null | head -1)"
[ -z "$P2_WIN_LOG" ] && { echo "FATAL: no window log for $P2_UUID" >&2; exit 1; }
P2_EVENTS_BEFORE="$(wc -l < "$P2_WIN_LOG" | tr -d ' ')"

# Arm the timer.
tmux -L "$SOCK" run-shell -t $P2 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep 1
assert "scenario 5: arm.pid file created" "1" \
  "$([ -f "$P2_ARM_FILE" ] && echo 1 || echo 0)"
P2_ARM_BASHPID="$(cat "$P2_ARM_FILE" 2>/dev/null)"
assert_nonempty "scenario 5: arm subshell pid recorded" "$P2_ARM_BASHPID"

# Invalidate authority: rewrite @claude-pane-id on the pane to a fake uuid.
# This simulates the post-crash-restore / fresh-server case where the pane's
# identity differs from what the orphan recorded at arm time.
tmux -L "$SOCK" set-option -pt $P2 @claude-pane-id "00000000-orphan-test-0000-000000000000"

# Wait past SOFT_DELAY for the subshell to wake and run arm_check.
sleep $((SOFT_DELAY + 3))

assert "scenario 5: arm subshell exited (self-bail)" "0" \
  "$(kill -0 "$P2_ARM_BASHPID" 2>/dev/null && echo 1 || echo 0)"
# No hibernation marker should have been created for either uuid.
assert "scenario 5: no marker for original P2 uuid" "0" \
  "$([ -f "$P2_MARKER" ] && echo 1 || echo 0)"
assert "scenario 5: no marker for the fake uuid" "0" \
  "$([ -f "$CACHE_DIR/hibernated/00000000-orphan-test-0000-000000000000.json" ] && echo 1 || echo 0)"
# No hibernated event in the window log for this pane.
HIB_EVENTS="$(tail -n +"$((P2_EVENTS_BEFORE + 1))" "$P2_WIN_LOG" \
  | jq -rc 'select(.kind == "hibernated" and .pane_uuid == "'"$P2_UUID"'")' \
  | wc -l | tr -d ' ')"
assert "scenario 5: no hibernated event emitted by orphan" "0" "$HIB_EVENTS"
# Claude pid must still be alive — the orphan must NOT have killed it.
assert "scenario 5: P2's claude process still alive (no spurious kill)" "1" \
  "$(kill -0 "$P2_CLAUDE_PID" 2>/dev/null && echo 1 || echo 0)"

# Restore the original uuid so the rest of the validator (if extended) sees a
# clean state. Also clean up arm.pid file in case it lingers.
tmux -L "$SOCK" set-option -pt $P2 @claude-pane-id "$P2_UUID"
rm -f "$P2_ARM_FILE"

# ---------------------------------------------------------------------------
echo "[6] arm-sweep arms all backgrounded claude panes in one shot"

# Start from a clean slate: kill any subshells the previous scenarios left
# behind and wipe arm.pid files so we measure exactly what the sweep adds.
for f in "$CACHE_DIR"/hibernated/*.arm.pid; do
  [ -f "$f" ] || continue
  pid="$(cat "$f" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -f "$f"
done

# Snapshot all claude panes into a "pane_id|focused" line list (bash 3.2 has
# no associative arrays). focused="1" iff window_active==1 && pane_active==1.
CLAUDE_PANE_LINES="$(tmux -L "$SOCK" list-panes -aF $'#{pane_id}\t#{window_active}\t#{pane_active}\t#{@claude-pane-id}' 2>/dev/null \
  | awk -F'\t' '$4 != "" { focused = ($2 "" $3 == "11") ? 1 : 0; print $1 "|" focused }')"
NUM_CLAUDE_PANES="$(printf '%s\n' "$CLAUDE_PANE_LINES" | wc -l | tr -d ' ')"
assert "scenario 6: fixture has 3 claude panes" "3" "$NUM_CLAUDE_PANES"

# Run the sweep (the same code path client-attached / client-session-changed
# fires in production). Invoking directly avoids needing a real attached client.
tmux -L "$SOCK" run-shell -b 'claude-rescue-log arm-sweep'
sleep 1

# Verify each claude pane: focused → no arm.pid; backgrounded → arm.pid with
# a live hibernate-arm subshell.
SWEEP_ARMED=0
while IFS='|' read -r pid_p is_focused; do
  [ -n "$pid_p" ] || continue
  san="${pid_p//[^A-Za-z0-9]/_}"
  af="$CACHE_DIR/hibernated/$san.arm.pid"
  if [ "$is_focused" = "1" ]; then
    continue   # focused panes should NOT be armed; not counted
  fi
  [ -f "$af" ] || continue
  apid="$(cat "$af" 2>/dev/null)"
  [ -n "$apid" ] && kill -0 "$apid" 2>/dev/null || continue
  args="$(ps -o args= -p "$apid" 2>/dev/null)"
  if printf '%s' "$args" | grep -qE "claude-rescue-log (hibernate-arm|arm-sweep)"; then
    SWEEP_ARMED=$((SWEEP_ARMED + 1))
  fi
done <<< "$CLAUDE_PANE_LINES"

# At fixture exit time the active window is window 3 (nvim), so all 3 claude
# panes are backgrounded — all three should be armed after the sweep.
assert "scenario 6: 3 backgrounded claude panes armed by sweep" "3" "$SWEEP_ARMED"

# Idempotency: a second sweep must NOT replace existing live timers. Snapshot
# the current arm pids, sweep again, verify they're unchanged.
PRE_RESWEEP="$(while IFS='|' read -r pid_p is_focused; do
  [ -n "$pid_p" ] || continue
  [ "$is_focused" = "1" ] && continue
  san="${pid_p//[^A-Za-z0-9]/_}"
  printf '%s=%s\n' "$pid_p" "$(cat "$CACHE_DIR/hibernated/$san.arm.pid" 2>/dev/null)"
done <<< "$CLAUDE_PANE_LINES")"
tmux -L "$SOCK" run-shell -b 'claude-rescue-log arm-sweep'
sleep 1
POST_RESWEEP="$(while IFS='|' read -r pid_p is_focused; do
  [ -n "$pid_p" ] || continue
  [ "$is_focused" = "1" ] && continue
  san="${pid_p//[^A-Za-z0-9]/_}"
  printf '%s=%s\n' "$pid_p" "$(cat "$CACHE_DIR/hibernated/$san.arm.pid" 2>/dev/null)"
done <<< "$CLAUDE_PANE_LINES")"
assert "scenario 6: second sweep is idempotent (existing timers untouched)" "$PRE_RESWEEP" "$POST_RESWEEP"

# Fast guard: nvim pane (no @claude-pane-id) must NOT be armed.
P3_SAN_S6="${P3//[^A-Za-z0-9]/_}"
assert "scenario 6: nvim pane not armed by sweep (fast guard)" "0" \
  "$([ -f "$CACHE_DIR/hibernated/$P3_SAN_S6.arm.pid" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
echo "[7] hibernate-resume preserves arm subshell when mode=hard"

# Re-use %2. Clear residual state from scenario 5 / 6.
P2=%2
P2_UUID="$(pane_uuid_of $P2)"
P2_SAN="${P2//[^A-Za-z0-9]/_}"
P2_ARM_FILE="$CACHE_DIR/hibernated/$P2_SAN.arm.pid"
P2_MARKER="$CACHE_DIR/hibernated/$P2_UUID.json"

# Clean slate.
for f in "$CACHE_DIR"/hibernated/*.arm.pid; do
  [ -f "$f" ] || continue
  pid="$(cat "$f" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -f "$f"
done
rm -f "$P2_MARKER"
sleep 1

# Arm %2 — this spawns an arm subshell sleeping toward soft.
tmux -L "$SOCK" run-shell -t $P2 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep 1
assert "scenario 7: arm.pid file created" "1" \
  "$([ -f "$P2_ARM_FILE" ] && echo 1 || echo 0)"
S7_ARM_PID="$(cat "$P2_ARM_FILE" 2>/dev/null)"
assert "scenario 7: arm subshell is alive pre-resume" "1" \
  "$([ -n "$S7_ARM_PID" ] && kill -0 "$S7_ARM_PID" 2>/dev/null && echo 1 || echo 0)"

# Inject a hard-mode marker by hand — this simulates the in-flight state
# right after cmd_hibernate_arm has written mode=hard but before it has
# sent `clr <sid>`. cmd_hibernate_resume should treat this state as
# "subshell is finishing critical cleanup — leave it alone".
jq -nc --arg ts "$(now_iso)" --arg pid_p "$P2" --arg puuid "$P2_UUID" \
  '{pane_id:$pid_p, pane_uuid:$puuid, ts:$ts, mode:"hard", hard_ts:$ts, pids:[]}' \
  > "$P2_MARKER"

# Fire hibernate-resume. Under the bug, this would kill the arm subshell
# because its argv matches the orphan-safety pattern.
tmux -L "$SOCK" run-shell -t $P2 'claude-rescue-log hibernate-resume #{pane_id}'
sleep 1

assert "scenario 7: hard marker survives hibernate-resume (mode=hard no-op)" "1" \
  "$([ -f "$P2_MARKER" ] && echo 1 || echo 0)"
assert "scenario 7: arm subshell NOT killed (hard cleanup must finish)" "1" \
  "$(kill -0 "$S7_ARM_PID" 2>/dev/null && echo 1 || echo 0)"
assert "scenario 7: arm.pid file still present" "1" \
  "$([ -f "$P2_ARM_FILE" ] && echo 1 || echo 0)"

# Negative control: rewrite marker to mode=soft and re-fire hibernate-resume.
# Now the arm subshell SHOULD be killed (this is how a focused soft-hibernated
# pane gets resumed: fg<Enter> + cancel the pending hard escalation).
jq --arg mode "soft" '. + {mode:$mode} | del(.hard_ts)' \
  "$P2_MARKER" > "$P2_MARKER.tmp" && mv "$P2_MARKER.tmp" "$P2_MARKER"
tmux -L "$SOCK" run-shell -t $P2 'claude-rescue-log hibernate-resume #{pane_id}'
sleep 1

assert "scenario 7: arm subshell IS killed when mode=soft (negative control)" "0" \
  "$(kill -0 "$S7_ARM_PID" 2>/dev/null && echo 1 || echo 0)"
assert "scenario 7: arm.pid file removed after soft-mode resume" "0" \
  "$([ -f "$P2_ARM_FILE" ] && echo 1 || echo 0)"

# Cleanup so a re-run starts fresh.
rm -f "$P2_MARKER"

# ---------------------------------------------------------------------------
echo "[8] SessionEnd reaps arm.pid + active session file (keeps @claude-pane-id)"

# Re-use %2. Restore its @claude-pane-id (scenario 5 / 7 cleanup may have left
# residual state). Arm a timer to populate arm.pid, seed an active session
# file by hand, then fire SessionEnd and verify all three side effects.
P2_UUID="$(pane_uuid_of $P2)"
if [ -z "$P2_UUID" ]; then
  # Mint one — earlier scenarios may have unset it.
  P2_UUID="$(uuidgen | tr A-Z a-z)"
  tmux -L "$SOCK" set-option -pt $P2 @claude-pane-id "$P2_UUID"
fi
P2_SAN="${P2//[^A-Za-z0-9]/_}"
P2_ARM_FILE="$CACHE_DIR/hibernated/$P2_SAN.arm.pid"

# Clean slate.
rm -f "$P2_ARM_FILE"
rm -f "$DATA_DIR/active/$P2_UUID"

# Arm a hibernation timer for this pane (creates arm.pid).
tmux -L "$SOCK" run-shell -t $P2 'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
sleep 1
assert "scenario 8: arm.pid created by hibernate-arm" "1" \
  "$([ -f "$P2_ARM_FILE" ] && echo 1 || echo 0)"

# Seed an active session file (simulates a prior cmd_session_start write).
mkdir -p "$DATA_DIR/active"
SID8="11111111-2222-3333-4444-555555555555"
printf '%s\n' "$SID8" > "$DATA_DIR/active/$P2_UUID"

# Fire cmd_session_end (claude exiting cleanly: /exit, dialog dismiss, etc.).
# Write the JSON to a temp file so the run-shell command is shell-quote-safe;
# session_end reads stdin via redirection.
#
# TMUX_PANE has to be set explicitly: staging.sh sets `set-environment -gu
# TMUX_PANE` so claude run *inside* this staging server doesn't pick up an
# outer tmux's pane. run-shell -t resolves `#{}` formats against the target
# but does NOT export TMUX_PANE to the child process — production claude
# already exports it from its own pane context, so the production hook path
# works fine. The test has to mimic that explicitly.
S8_JSON_FILE="$DATA_DIR/scenario8.json"
printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"SessionEnd"}' "$SID8" > "$S8_JSON_FILE"
tmux -L "$SOCK" run-shell -t $P2 "TMUX_PANE=$P2 claude-rescue-log session_end < $S8_JSON_FILE"
sleep 2

assert "scenario 8: SessionEnd removed arm.pid (no orphan)" "0" \
  "$([ -f "$P2_ARM_FILE" ] && echo 1 || echo 0)"
assert "scenario 8: SessionEnd removed active session file" "0" \
  "$([ -f "$DATA_DIR/active/$P2_UUID" ] && echo 1 || echo 0)"
# @claude-pane-id stays — the hibernation marker is keyed by it and cmd_session_start
# needs it as the cleanup bridge if claude returns to this pane.
assert "scenario 8: SessionEnd preserved @claude-pane-id (identity bridge)" "$P2_UUID" \
  "$(pane_uuid_of $P2)"

# ---------------------------------------------------------------------------
echo "[9] arm-sweep detects voluntary-exit (no marker, no busy, cmd != claude)"

# Use %3 (nvim — pane_current_command is nvim, not claude). Set a fake
# @claude-pane-id on it to simulate "this pane used to run claude, but claude
# exited via a path that didn't fire SessionEnd". Seed an active file + arm.pid
# for that fake identity. arm-sweep should detect this and clean up all three.
S9_FAKE_UUID="99999999-aaaa-bbbb-cccc-dddddddddddd"
tmux -L "$SOCK" set-option -pt $P3 @claude-pane-id "$S9_FAKE_UUID"

mkdir -p "$DATA_DIR/active"
printf '%s\n' "deadbeef-1111-2222-3333-444444444444" > "$DATA_DIR/active/$S9_FAKE_UUID"

P3_SAN="${P3//[^A-Za-z0-9]/_}"
P3_ARM_FILE="$CACHE_DIR/hibernated/$P3_SAN.arm.pid"
echo "$$" > "$P3_ARM_FILE"

# Run the sweep (same code path client-attached fires in production).
tmux -L "$SOCK" run-shell -b 'claude-rescue-log arm-sweep'
sleep 1

assert "scenario 9: arm-sweep cleared active file for non-claude pane" "0" \
  "$([ -f "$DATA_DIR/active/$S9_FAKE_UUID" ] && echo 1 || echo 0)"
assert "scenario 9: arm-sweep cleared arm.pid for non-claude pane" "0" \
  "$([ -f "$P3_ARM_FILE" ] && echo 1 || echo 0)"
assert_empty "scenario 9: arm-sweep unset @claude-pane-id on non-claude pane" \
  "$(pane_uuid_of $P3)"

# Negative control: a backgrounded *claude* pane that still has its uuid must
# NOT have any of the three cleaned up. Pick one of the other claude panes
# (the sweep just ran — they should be armed, not cleaned).
P0_UUID_NOW="$(pane_uuid_of $P0)"
assert "scenario 9: claude pane @claude-pane-id preserved by sweep" "1" \
  "$([ -n "$P0_UUID_NOW" ] && echo 1 || echo 0)"

# Cleanup arm.pids the sweep created for the other claude panes.
for f in "$CACHE_DIR"/hibernated/*.arm.pid; do
  [ -f "$f" ] || continue
  pid="$(cat "$f" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -f "$f"
done

# ---------------------------------------------------------------------------
echo "[10] fork guard + reconcile: a forked pane self-heals to its real sid"

# Models `claude --fork-session -r <parent>`: the fork pane is born with
# SessionStart(source=resume, .session_id=<parent>) while <parent> is still live
# in the parent pane. cmd_session_start's guard must decline to stamp it; the
# fork's real id then self-heals via the user_prompt_submit reconcile.
P10_A=$P0        # live "parent" pane (has @claude-pane-id)
P10_B=%2         # "fork" pane — claude uuid kept, active file cleared in scenario 8
A_UUID="$(pane_uuid_of $P10_A)"
B_UUID="$(pane_uuid_of $P10_B)"
[ -z "$B_UUID" ] && { echo "FATAL: $P10_B has no @claude-pane-id" >&2; exit 1; }
PARENT_SID="10000000-0000-4000-8000-000000000001"
UNIQ_SID="30000000-0000-4000-8000-000000000003"
FORK_SID="20000000-0000-4000-8000-000000000002"

mkdir -p "$DATA_DIR/active"
printf '%s\n' "$PARENT_SID" > "$DATA_DIR/active/$A_UUID"   # parent pane live on parent sid
rm -f "$DATA_DIR/active/$B_UUID"                           # fork pane starts clean

# Guard triggers: resume whose sid is live in ANOTHER pane → not stamped.
S10_J1="$DATA_DIR/scenario10-guard.json"
printf '{"session_id":"%s","cwd":"/tmp","source":"resume","hook_event_name":"SessionStart"}' "$PARENT_SID" > "$S10_J1"
tmux -L "$SOCK" run-shell -t $P10_B "TMUX_PANE=$P10_B claude-rescue-log session_start < $S10_J1"
sleep 1
B_WIN_UUID="$(tmux -L "$SOCK" show-options -wv -t $P10_B @claude-window-id 2>/dev/null)"
B_LOG="$DATA_DIR/windows/$B_WIN_UUID.jsonl"

assert "scenario 10: guard declined — B active NOT stamped with parent id" "0" \
  "$([ -f "$DATA_DIR/active/$B_UUID" ] && echo 1 || echo 0)"
assert "scenario 10: guard declined — no session_start{parent} appended for B" "0" \
  "$(jq -rc 'select(.kind=="session_start" and .session_id=="'"$PARENT_SID"'" and .pane_uuid=="'"$B_UUID"'")' "$B_LOG" 2>/dev/null | wc -l | tr -d ' ')"

# Guard is collision-scoped, not all-resume: a resume whose sid is NOT live
# elsewhere is adopted normally (the in-claude /resume path).
S10_J2="$DATA_DIR/scenario10-resume.json"
printf '{"session_id":"%s","cwd":"/tmp","source":"resume","hook_event_name":"SessionStart"}' "$UNIQ_SID" > "$S10_J2"
tmux -L "$SOCK" run-shell -t $P10_B "TMUX_PANE=$P10_B claude-rescue-log session_start < $S10_J2"
sleep 1
assert "scenario 10: normal resume (sid not live elsewhere) IS adopted" "$UNIQ_SID" \
  "$(cat "$DATA_DIR/active/$B_UUID" 2>/dev/null | tr -d '\n')"

# First message on the fork: UserPromptSubmit carries the REAL fork id → heal.
S10_J3="$DATA_DIR/scenario10-heal.json"
printf '{"session_id":"%s","cwd":"/tmp","transcript_path":"/tmp/fork.jsonl","hook_event_name":"UserPromptSubmit"}' "$FORK_SID" > "$S10_J3"
tmux -L "$SOCK" run-shell -t $P10_B "TMUX_PANE=$P10_B claude-rescue-log user_prompt_submit < $S10_J3"
sleep 1
assert "scenario 10: reconcile healed B active to fork id" "$FORK_SID" \
  "$(cat "$DATA_DIR/active/$B_UUID" 2>/dev/null | tr -d '\n')"
assert "scenario 10: parent pane A active unchanged (no cross-pane bleed)" "$PARENT_SID" \
  "$(cat "$DATA_DIR/active/$A_UUID" 2>/dev/null | tr -d '\n')"
assert "scenario 10: reconcile appended session_start{source:reconcile} for fork" "1" \
  "$(jq -rc 'select(.kind=="session_start" and .source=="reconcile" and .session_id=="'"$FORK_SID"'" and .pane_uuid=="'"$B_UUID"'")' "$B_LOG" 2>/dev/null | wc -l | tr -d ' ')"
assert "scenario 10: reconcile emitted NO session_end for parent" "0" \
  "$(jq -rc 'select(.kind=="session_end" and .session_id=="'"$PARENT_SID"'")' "$B_LOG" 2>/dev/null | wc -l | tr -d ' ')"

# Idempotent: re-firing the same fork id is a no-op (early return, no new event).
EV_BEFORE="$(wc -l < "$B_LOG" | tr -d ' ')"
tmux -L "$SOCK" run-shell -t $P10_B "TMUX_PANE=$P10_B claude-rescue-log user_prompt_submit < $S10_J3"
sleep 1
assert "scenario 10: idempotent re-fire appends no new event" "$EV_BEFORE" \
  "$(wc -l < "$B_LOG" | tr -d ' ')"
assert "scenario 10: active still fork after idempotent re-fire" "$FORK_SID" \
  "$(cat "$DATA_DIR/active/$B_UUID" 2>/dev/null | tr -d '\n')"

# ---------------------------------------------------------------------------
echo "[11] on-demand hibernate/restore (prefix + a popup row)"

# Run hibernate-state INSIDE the staging server (so its tmux calls hit -L $SOCK)
# and capture its stdout via a file — run-shell without -b is synchronous, so
# the redirect has landed by the time it returns.
hib_state() {
  local out="$DATA_DIR/hibstate.out"
  rm -f "$out"
  tmux -L "$SOCK" run-shell -t "$1" "claude-rescue-log hibernate-state #{pane_id} > $out 2>/dev/null"
  cat "$out" 2>/dev/null | tr -d '\n '
}

# Drive %1 (main:1.2, projectA) — deliberately NOT P0/P2. Those were left with a
# rewritten/synthetic active session id (scenario 10 stamps PARENT_SID onto P0),
# so their active file no longer matches the real claude in the pane, which would
# make the suspend-clear and `clr <sid>` checks below read the wrong session. %1
# is the one fixture claude pane no earlier scenario mutates, so its active file
# still reflects reality — like a fresh boot. The popup delegates to these same
# subcommands: hibernate-state (row label), hibernate-now (force hard suspend),
# restore-now (bring it back).
P11=%1
P11_UUID="$(pane_uuid_of $P11)"
[ -z "$P11_UUID" ] && { echo "FATAL: $P11 has no @claude-pane-id" >&2; exit 1; }
P11_SAN="${P11//[^A-Za-z0-9]/_}"
P11_MARKER="$CACHE_DIR/hibernated/$P11_UUID.json"
P11_ARM="$CACHE_DIR/hibernated/$P11_SAN.arm.pid"

# Defensive reset to a known live-claude state: scenarios 6/9 ran arm-sweep over
# every backgrounded claude pane (%1 included) and killed the timers again a few
# seconds later. That window is shorter than SOFT_DELAY so %1 should still be
# live, but don't depend on scheduling jitter — cancel any lingering arm timer,
# and if a stray one did fire, resume + clear the marker before testing.
if [ -f "$P11_ARM" ]; then
  P11_AP="$(cat "$P11_ARM" 2>/dev/null)"; [ -n "$P11_AP" ] && kill "$P11_AP" 2>/dev/null || true
  rm -f "$P11_ARM"
fi
if [ -f "$P11_MARKER" ]; then
  tmux -L "$SOCK" run-shell -t $P11 'claude-rescue-log hibernate-resume #{pane_id}'
  sleep 2
  rm -f "$P11_MARKER"
fi

# Precondition: claude is foreground and the pane reports "none".
assert "scenario 11: pane is a live claude before hibernate-now" "claude" "$(fg_cmd $P11)"
assert "scenario 11: hibernate-state is 'none' with no marker" "none" "$(hib_state $P11)"

# Seed suspend_hibernation=true on the pane's active session — hibernate-now must
# clear it (forcing a suspend while "never suspend" is ticked is contradictory).
SID11="$(cat "$DATA_DIR/active/$P11_UUID" 2>/dev/null | head -1 | tr -d '\n')"
assert_nonempty "scenario 11: pane has an active session_id" "$SID11"
mkdir -p "$DATA_DIR/session-config"
printf '{"suspend_hibernation":true}\n' > "$DATA_DIR/session-config/$SID11.json"

# Force the hard hibernation. Internally: no delays, no busy/active guards —
# capture, Ctrl+Z, fg, /exit, `clr <sid>` pre-fill. Give the escalation +
# kill-fallback time to complete.
tmux -L "$SOCK" run-shell -t $P11 'claude-rescue-log hibernate-now #{pane_id}'
sleep 12

# NB: read the flag with a plain `.suspend_hibernation`, NOT `// empty` — jq's
# `//` operator treats `false` as absent, so `false // empty` prints nothing and
# would mask a correctly-cleared flag as "".
assert "scenario 11: suspend_hibernation cleared by hibernate-now" "false" \
  "$(jq -r '.suspend_hibernation' "$DATA_DIR/session-config/$SID11.json" 2>/dev/null)"
assert "scenario 11: marker mode=hard after forced hibernation" "hard" \
  "$(jq -r '.mode // empty' "$P11_MARKER" 2>/dev/null)"
assert "scenario 11: hibernate-state reports 'hard'" "hard" "$(hib_state $P11)"
assert "scenario 11: pane back at zsh (claude /exited)" "zsh" "$(fg_cmd $P11)"
# Poll for the `clr <sid>` pre-fill — claude's /exit + shell redraw can lag a
# couple seconds past the marker write under real-claude latency.
CLR_OK=0
for _ in $(seq 1 10); do
  if tmux -L "$SOCK" capture-pane -p -t $P11 | grep -q '❯ clr [0-9a-f]\{8\}-'; then CLR_OK=1; break; fi
  sleep 1
done
assert "scenario 11: 'clr <sid>' pre-filled at prompt" "1" "$CLR_OK"

# Restore on demand. Hard branch is "smart about a text shell": no suspended job
# to fg, so it types `clr <sid>` at the prompt and runs it → claude --resume.
tmux -L "$SOCK" run-shell -t $P11 'claude-rescue-log restore-now #{pane_id}'
RESTORED=0
for _ in $(seq 1 20); do
  if [ "$(fg_cmd $P11)" = "claude" ]; then RESTORED=1; break; fi
  sleep 1
done
assert "scenario 11: restore-now brought claude back (hard → clr resume)" "1" "$RESTORED"
sleep 2
assert "scenario 11: hard marker cleaned up by session_start after restore" "0" \
  "$([ -f "$P11_MARKER" ] && echo 1 || echo 0)"
assert "scenario 11: hibernate-state back to 'none' after restore" "none" "$(hib_state $P11)"

# Cleanup.
rm -f "$DATA_DIR/session-config/$SID11.json"

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
