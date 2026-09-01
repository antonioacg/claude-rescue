#!/usr/bin/env bash
# End-to-end validation against an isolated tmux server.
#
# Spins up `tmux -L claude-rescue-validate` with the *production* rescue.tmux.conf
# sourced (the same one chezmoi installs into ~/.tmux.conf), uses a temp
# CLAUDE_RESCUE_DATA_HOME, and exercises every scenario from PLAN.md.
#
# Touches NOTHING in your live tmux server, your ~/.tmux.conf, or your
# ~/.claude/settings.json. Cleans up on exit.
#
# Output: PASS/FAIL per scenario. Non-zero exit on any failure.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="claude-rescue-validate"
HOME_DIR="$(mktemp -d -t claude-rescue-validate.XXXXXX)"
PASS=0
FAIL=0
RESULTS=()

cleanup() {
  CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" \
    "$REPO/bin/claude-rescue-state" stop >/dev/null 2>&1 || true
  watcher_pid_file="$HOME_DIR/watcher-$SOCK.pid"
  if [ -f "$watcher_pid_file" ]; then
    watcher_pid="$(cat "$watcher_pid_file" 2>/dev/null || true)"
    [ -n "$watcher_pid" ] && kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$HOME_DIR"
}
trap cleanup EXIT

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

# ---------------------------------------------------------------------------
# Bring up the isolated server with production conf.

# The State Owner inherits this environment from the tmux server, so retention
# tuning has to be set before the server starts. Keep hot_keep above what any
# other scenario writes into a checkpoint dir so only scenario 16 sees a prune.
export CLAUDE_RESCUE_HOT_KEEP=8
# The orphan grace window guards one interleaving: a blob row written just
# before the save row that references it, with a maintenance pass landing
# between the two. The single writer serializes requests, so that ordering
# needs a crash to occur at all and cannot be produced synchronously here —
# the window would only defer scenario 16g's assertion past the end of the run.
export CLAUDE_RESCUE_HISTORY_ORPHAN_GRACE_SECONDS=0

CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" CLAUDE_RESCUE_REPO="$REPO" PATH="$REPO/bin:$PATH" \
  tmux -L "$SOCK" -f "$REPO/tmux/test/test.conf" \
    new-session -d -s t1 -x 200 -y 50

tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_DATA_HOME "$HOME_DIR"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_CACHE_HOME "$HOME_DIR/cache"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_REPO "$REPO"
tmux -L "$SOCK" set-environment -g PATH "$REPO/bin:$PATH"

STATE_OWNER_READY=no
for _ in $(seq 1 30); do
  if CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" \
    "$REPO/bin/claude-rescue-state" status >/dev/null 2>&1; then
    STATE_OWNER_READY=yes
    break
  fi
  sleep 0.1
done
assert "tmux config starts the State Owner" "yes" "$STATE_OWNER_READY"

P0=$(tmux -L "$SOCK" display-message -p -t t1 -F '#{pane_id}')

emit_session_start() {
  local pane="$1" sid="$2" cwd="$3" source="$4"
  tmux -L "$SOCK" send-keys -t "$pane" \
    "echo '{\"session_id\":\"$sid\",\"cwd\":\"$cwd\",\"source\":\"$source\",\"model\":\"x\",\"transcript_path\":\"\",\"hook_event_name\":\"SessionStart\"}' | claude-rescue-log session_start" \
    Enter
}

# send-keys silently no-ops if the shell hasn't drawn its first prompt yet,
# which causes flaky scenario 1 on busy machines. Block until a sentinel
# command actually executes.
wait_for_shell() {
  local pane="$1" marker="$HOME_DIR/.ready.${pane//[^a-zA-Z0-9]/_}"
  rm -f "$marker"
  local i j
  for i in $(seq 1 20); do
    # Startup work can make an early send-keys disappear before zsh begins
    # reading input. Retry an idempotent probe at a low cadence. Send literal
    # text separately so tmux never tries to parse any part as a key name.
    tmux -L "$SOCK" send-keys -t "$pane" C-u
    tmux -L "$SOCK" send-keys -l -t "$pane" "touch '$marker'"
    tmux -L "$SOCK" send-keys -t "$pane" Enter
    for j in $(seq 1 10); do
      [ -f "$marker" ] && { rm -f "$marker"; return 0; }
      sleep 0.1
    done
  done
  echo "wait_for_shell: pane $pane never became interactive" >&2
  return 1
}

# ---------------------------------------------------------------------------
echo "[scenario 1] first session in new window mints @claude-window-id"
SID1=$(uuidgen|tr A-Z a-z)
wait_for_shell "$P0"
emit_session_start "$P0" "$SID1" "/tmp/s1" startup
sleep 3
U1=$(tmux -L "$SOCK" show-options -wv -t "$P0" @claude-window-id)
assert_nonempty "scenario 1: window UUID stamped" "$U1"
assert "scenario 1: session_start logged" "1" \
  "$(cat "$HOME_DIR/windows/"*.jsonl 2>/dev/null | grep -c '"kind":"session_start"')"

# ---------------------------------------------------------------------------
echo "[scenario 2] /clear emits session_end + new session, same window"
SID2=$(uuidgen|tr A-Z a-z)
emit_session_start "$P0" "$SID2" "/tmp/s1" clear
sleep 3
U2=$(tmux -L "$SOCK" show-options -wv -t "$P0" @claude-window-id)
assert "scenario 2: same window UUID" "$U1" "$U2"
assert "scenario 2: session_end emitted with reason:clear" "1" \
  "$(cat "$HOME_DIR/windows/"*.jsonl 2>/dev/null | grep -c '"reason":"clear"')"

# ---------------------------------------------------------------------------
echo "[scenario 3] two concurrent panes share the window UUID"
tmux -L "$SOCK" split-window -h -t "$P0"
PA=$(tmux -L "$SOCK" list-panes -t t1:0 -F '#{pane_id}' | sed -n 1p)
PB=$(tmux -L "$SOCK" list-panes -t t1:0 -F '#{pane_id}' | sed -n 2p)
SA=$(uuidgen|tr A-Z a-z); SB=$(uuidgen|tr A-Z a-z)
emit_session_start "$PA" "$SA" "/tmp/sA" startup
emit_session_start "$PB" "$SB" "/tmp/sB" startup
sleep 2
UA=$(tmux -L "$SOCK" show-options -wv -t "$PA" @claude-window-id)
UB=$(tmux -L "$SOCK" show-options -wv -t "$PB" @claude-window-id)
assert "scenario 3: concurrent panes share window UUID" "$UA" "$UB"

# ---------------------------------------------------------------------------
echo "[scenario 4] title debounce — flicker collapses to one event"
tmux -L "$SOCK" send-keys -t "$PA" "claude-rescue-log title $PA 'first'" Enter
sleep 1
tmux -L "$SOCK" send-keys -t "$PA" "claude-rescue-log title $PA 'second'" Enter
sleep 1
tmux -L "$SOCK" send-keys -t "$PA" "claude-rescue-log title $PA 'final'" Enter
sleep 7
TITLES=$(cat "$HOME_DIR/windows/"*.jsonl 2>/dev/null | grep -c '"title":"final"')
assert "scenario 4: only the settled title was logged" "1" "$TITLES"

# ---------------------------------------------------------------------------
echo "[scenario 5] pane-died forces title flush"
# Send via PA (warm shell from earlier scenarios) — PB's shell may not be ready
# enough yet for send-keys to deliver reliably under the test's tight timing.
tmux -L "$SOCK" send-keys -t "$PA" "claude-rescue-log title $PA 'unflushed'" Enter
sleep 2
tmux -L "$SOCK" send-keys -t "$PA" "claude-rescue-log pane-died $PA" Enter
sleep 3
assert "scenario 5: pane_died event logged" "1" \
  "$(cat "$HOME_DIR/windows/"*.jsonl 2>/dev/null | grep -c '"kind":"pane_died"')"
assert "scenario 5: forced title flush captured" "1" \
  "$(cat "$HOME_DIR/windows/"*.jsonl 2>/dev/null | grep -c '"forced":true')"

# The Watcher Adapter detects death after tmux has already removed the pane.
# It must use the identities retained in its previous snapshot rather than
# asking tmux to resolve options on a pane that no longer exists.
echo "[scenario 5b] watcher attributes a pane that already disappeared"
tmux -L "$SOCK" new-window -t t1
S5B_P=$(tmux -L "$SOCK" display-message -p -t t1 -F '#{pane_id}')
wait_for_shell "$S5B_P"
emit_session_start "$S5B_P" "$(uuidgen|tr A-Z a-z)" "/tmp/s5b" startup
sleep 2
S5B_PUUID=$(tmux -L "$SOCK" show-options -pv -t "$S5B_P" @claude-pane-id)
tmux -L "$SOCK" kill-pane -t "$S5B_P"
S5B_DIED=no
for _ in $(seq 1 30); do
  if grep -h '"kind":"pane_died"' "$HOME_DIR/windows/"*.jsonl 2>/dev/null \
     | grep -Fq "\"pane_uuid\":\"$S5B_PUUID\""; then
    S5B_DIED=yes
    break
  fi
  sleep 0.1
done
assert "scenario 5b: watcher retains identity for an already-dead pane" "yes" "$S5B_DIED"

# ---------------------------------------------------------------------------
echo "[scenario 6] resurrect save → kill-server → restore preserves UUID"
ORIG=$(tmux -L "$SOCK" show-options -wv -t "$PB" @claude-window-id)
tmux -L "$SOCK" run-shell "$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh quiet"
sleep 1
tmux -L "$SOCK" kill-server 2>/dev/null
sleep 1
CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" CLAUDE_RESCUE_REPO="$REPO" PATH="$REPO/bin:$PATH" \
  tmux -L "$SOCK" -f "$REPO/tmux/test/test.conf" new-session -d -s t1 -x 200 -y 50
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_DATA_HOME "$HOME_DIR"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_CACHE_HOME "$HOME_DIR/cache"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_REPO "$REPO"
tmux -L "$SOCK" set-environment -g PATH "$REPO/bin:$PATH"
sleep 1
tmux -L "$SOCK" run-shell "$HOME/.config/tmux/plugins/tmux-resurrect/scripts/restore.sh"
sleep 2
RESTORED=$(tmux -L "$SOCK" list-windows -aF '#{@claude-window-id}' | head -1)
assert "scenario 6: @claude-window-id survived resurrect cycle" "$ORIG" "$RESTORED"

# ---------------------------------------------------------------------------
echo "[scenario 7] window rearrangement preserves UUID"
tmux -L "$SOCK" new-window -t t1
tmux -L "$SOCK" new-window -t t1
BEFORE=$(tmux -L "$SOCK" show-options -wv -t t1:0 @claude-window-id)
tmux -L "$SOCK" swap-window -s t1:0 -t t1:2
AFTER=$(tmux -L "$SOCK" show-options -wv -t t1:2 @claude-window-id)
assert "scenario 7: UUID rode the swap" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
echo "[scenario 8] claude run outside tmux → no-tmux fallback"
SNT=$(uuidgen|tr A-Z a-z)
env -u TMUX -u TMUX_PANE \
  bash -c "echo '{\"session_id\":\"$SNT\",\"cwd\":\"/tmp/notmux\",\"source\":\"startup\",\"model\":\"x\",\"transcript_path\":\"\",\"hook_event_name\":\"SessionStart\"}' | CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log session_start"
NTBUCKETS=$(find "$HOME_DIR/no-tmux" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
assert "scenario 8: no-tmux bucket created" "1" "$NTBUCKETS"

# ---------------------------------------------------------------------------
# Regression: find-sessions must encode BOTH `/` and `.` to `-` when looking
# up the claude projects dir. Prod rollout caught a silent filter-out of all
# dotfile-cwd sessions (e.g. ~/.local/share/chezmoi). Build a meta.json and
# fake transcript directly so the test exercises ONLY the encoding logic.
echo "[scenario 9] find-sessions resolves a dotfile cwd"
DOTCWD="/tmp/.dotfile-cwd-validate-$$"
DOTENC="-tmp--dotfile-cwd-validate-$$"  # / and . both map to -
PROJ_ROOT="$HOME_DIR/fake-projects"
mkdir -p "$PROJ_ROOT/$DOTENC"
SID9=$(uuidgen|tr A-Z a-z)
PUUID9=$(uuidgen|tr A-Z a-z)
WUUID9=$(uuidgen|tr A-Z a-z)
: > "$PROJ_ROOT/$DOTENC/$SID9.jsonl"
mkdir -p "$HOME_DIR/windows"
jq -n --arg wu "$WUUID9" --arg sid "$SID9" --arg pu "$PUUID9" --arg cwd "$DOTCWD" '{
  window_uuid: $wu, window_name: "validate-dotfile",
  sessions: [{
    session_id: $sid, pane_uuid: $pu, cwd: $cwd,
    source: "validate", started: "2026-01-01T00:00:00Z", ended: null
  }]
}' > "$HOME_DIR/windows/$WUUID9.meta.json"
RES9=$(CLAUDE_PROJECTS_DIR="$PROJ_ROOT" CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" \
       "$REPO/bin/claude-rescue" find-sessions --pane-uuid "$PUUID9" 2>/dev/null \
       | head -1 | awk -v FS=$'\x1f' '{print $1}')
assert "scenario 9: dotfile cwd session resolves" "$SID9" "$RES9"
# Also confirm a dot-free cwd still works (regression guard on the chained
# parameter expansion: `/` mapping must survive the `.` mapping).
PLAINCWD="/tmp/plaincwd-validate-$$"
PLAINENC="-tmp-plaincwd-validate-$$"
mkdir -p "$PROJ_ROOT/$PLAINENC"
SID9B=$(uuidgen|tr A-Z a-z)
PUUID9B=$(uuidgen|tr A-Z a-z)
WUUID9B=$(uuidgen|tr A-Z a-z)
: > "$PROJ_ROOT/$PLAINENC/$SID9B.jsonl"
jq -n --arg wu "$WUUID9B" --arg sid "$SID9B" --arg pu "$PUUID9B" --arg cwd "$PLAINCWD" '{
  window_uuid: $wu, window_name: "validate-plain",
  sessions: [{
    session_id: $sid, pane_uuid: $pu, cwd: $cwd,
    source: "validate", started: "2026-01-01T00:00:00Z", ended: null
  }]
}' > "$HOME_DIR/windows/$WUUID9B.meta.json"
RES9B=$(CLAUDE_PROJECTS_DIR="$PROJ_ROOT" CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" \
        "$REPO/bin/claude-rescue" find-sessions --pane-uuid "$PUUID9B" 2>/dev/null \
        | head -1 | awk -v FS=$'\x1f' '{print $1}')
assert "scenario 9: plain cwd session still resolves" "$SID9B" "$RES9B"

# ---------------------------------------------------------------------------
# Regression: bash's `IFS=$'\t' read` collapses consecutive tabs, so an
# empty `window_name` in the sidecar row would silently shift the uuid
# into col4 and leave col5 empty — restore then dispatches to the legacy
# 4-col branch and calls `set-option -wt window:<session>` (literal
# "window" as session name, since col1 was "window" and got treated as
# the session marker). Caught in prod rollout on bufferbloat-wr741 w3.
# Fix: sentinel-encode internal empties in cmd_resurrect_save's awk.
echo "[scenario 10] resurrect-save sentinel-encodes empty window_name"
# Create a new window with empty name. Disable automatic-rename so tmux
# doesn't immediately overwrite our empty name with the command name.
tmux -L "$SOCK" set-window-option -g automatic-rename off
tmux -L "$SOCK" new-window -t t1 -n "scenario10-placeholder"
S10_WIN_ID="$(tmux -L "$SOCK" display-message -p -t t1 -F '#{window_id}')"
tmux -L "$SOCK" rename-window -t "$S10_WIN_ID" ""
S10_TEST_UUID="$(uuidgen|tr A-Z a-z)"
tmux -L "$SOCK" set-option -wt "$S10_WIN_ID" @claude-window-id "$S10_TEST_UUID"
# Trigger cmd_resurrect_save via run-shell so its tmux calls hit $SOCK.
S10_FAKE_STATE="$HOME_DIR/scenario10.txt"
echo "fake-tmux-resurrect-state" > "$S10_FAKE_STATE"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-save $S10_FAKE_STATE"
sleep 1
S10_SIDECAR="${S10_FAKE_STATE%.txt}.claude-userops.tsv"
# Find the sidecar row for our test UUID. Sentinel-encoded col4 should be "-".
S10_COL4=$(awk -F'\t' -v u="$S10_TEST_UUID" '$5==u {print $4; exit}' "$S10_SIDECAR" 2>/dev/null)
assert "scenario 10: empty window_name encoded as sentinel" "-" "$S10_COL4"
# Also exercise the reader: set up a `last` symlink and call resurrect-restore.
# Stderr from the hook lands in rescue-log.err — assert no set-option failures
# for our test window. Use a dedicated resurrect-dir under HOME_DIR so we
# don't touch the user's real one.
S10_RDIR="$HOME_DIR/resurrect-scenario10"
mkdir -p "$S10_RDIR"
cp "$S10_FAKE_STATE" "$S10_RDIR/scenario10.txt"
cp "$S10_SIDECAR"    "$S10_RDIR/scenario10.claude-userops.tsv"
ln -sf scenario10.txt "$S10_RDIR/last"
tmux -L "$SOCK" set-option -g @resurrect-dir "$S10_RDIR"
S10_RESCUE_ERR="$HOME_DIR/scenario10-restore.err"
: > "$S10_RESCUE_ERR"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-restore 2>>$S10_RESCUE_ERR"
sleep 1
# The hook logs to $CLAUDE_RESCUE_CACHE_HOME/rescue-log.err. Grep for the
# specific failure mode (set-option ... failed) on a line from this scenario's
# restore call. Pre-existing entries from earlier scenarios should be empty.
S10_FAIL=$(grep -c "set-option .* failed" "$HOME_DIR/cache/rescue-log.err" 2>/dev/null)
[ -z "$S10_FAIL" ] && S10_FAIL=0
assert "scenario 10: restore reads sentinel'd sidecar without set-option failures" "0" "$S10_FAIL"
# Restore automatic-rename for any later scenarios (none in this file but defensive).
tmux -L "$SOCK" set-window-option -g automatic-rename on

# ---------------------------------------------------------------------------
# Active session_id file lifecycle. Written by cmd_session_start on every
# source, removed by cmd_session_end / cmd_pane_died. SessionEnd also unsets
# @claude-pane-id so a pane no longer running claude carries no claude
# identity. resurrect-restore bulk-clears the dir.
echo "[scenario 11] active session_id file lifecycle"

tmux -L "$SOCK" new-window -t t1
S11_P=$(tmux -L "$SOCK" display-message -p -t t1 -F '#{pane_id}')
wait_for_shell "$S11_P"

# (a) Initial SessionStart writes the active file.
SID11A=$(uuidgen|tr A-Z a-z)
emit_session_start "$S11_P" "$SID11A" "/tmp/s11" startup
sleep 2
S11_PUUID=$(tmux -L "$SOCK" show-options -pv -t "$S11_P" @claude-pane-id)
assert_nonempty "scenario 11: @claude-pane-id minted on first SessionStart" "$S11_PUUID"
S11_ACTIVE_A=$(cat "$HOME_DIR/active/$S11_PUUID" 2>/dev/null | tr -d '\n')
assert "scenario 11a: active file contains initial sid" "$SID11A" "$S11_ACTIVE_A"

# (b) Second SessionStart (simulating in-claude /resume) overwrites with new sid.
SID11B=$(uuidgen|tr A-Z a-z)
emit_session_start "$S11_P" "$SID11B" "/tmp/s11" resume
sleep 2
S11_ACTIVE_B=$(cat "$HOME_DIR/active/$S11_PUUID" 2>/dev/null | tr -d '\n')
assert "scenario 11b: in-claude /resume overwrites active file" "$SID11B" "$S11_ACTIVE_B"

# (c) SessionEnd clears active file but KEEPS @claude-pane-id (identity bridge
# for the hibernation marker and find-sessions lookups when claude returns).
tmux -L "$SOCK" send-keys -t "$S11_P" \
  "echo '{\"session_id\":\"$SID11B\",\"cwd\":\"/tmp/s11\",\"hook_event_name\":\"SessionEnd\"}' | claude-rescue-log session_end" \
  Enter
sleep 2
[ -f "$HOME_DIR/active/$S11_PUUID" ] && S11_AFTER=present || S11_AFTER=absent
assert "scenario 11c: SessionEnd clears active file" "absent" "$S11_AFTER"
S11_PUUID_AFTER=$(tmux -L "$SOCK" show-options -pv -t "$S11_P" @claude-pane-id 2>/dev/null)
assert "scenario 11c: SessionEnd preserves @claude-pane-id" "$S11_PUUID" "$S11_PUUID_AFTER"

# (d) resurrect-restore PRESERVES active files. The truthful "which session
# is loaded" set by SessionStart hooks (keyed by durable pane_uuid) is the
# only signal that survives stale saved -r (set at launch, never updated on
# in-process /resume) and stale event-log meta. Orphans for vanished
# pane_uuids are harmless because the wrapper only queries by live pane_uuid.
mkdir -p "$HOME_DIR/active"
S11_ORPHAN="orphan-puuid-$$-$(date +%s)"
touch "$HOME_DIR/active/$S11_ORPHAN"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-restore"
sleep 1
[ -f "$HOME_DIR/active/$S11_ORPHAN" ] && S11_ORPHAN_STATE=present || S11_ORPHAN_STATE=absent
assert "scenario 11d: resurrect-restore preserves active dir" "present" "$S11_ORPHAN_STATE"

# (e) SessionEnd PRESERVES active when a hibernation marker is present. The
# hard-hibernate timer fires `/exit` on claude, which triggers SessionEnd;
# without this gate the sid mapping the user needs to resume is destroyed
# (hibernated/<uuid>.json carries no sid). Hit 21 panes in production
# (postmortem 2026-05-19) — every hard-hibernated pane lost its resume target
# and fell through to find-sessions's most-recent heuristic.
SID11E=$(uuidgen|tr A-Z a-z)
emit_session_start "$S11_P" "$SID11E" "/tmp/s11" startup
sleep 1
# Simulate a hibernation arm having written the marker.
mkdir -p "$HOME_DIR/cache/hibernated"
cat > "$HOME_DIR/cache/hibernated/$S11_PUUID.json" <<EOF
{"pane_id":"$S11_P","pane_uuid":"$S11_PUUID","ts":"2026-01-01T00:00:00Z","mode":"hard","pids":["1"],"hard_ts":"2026-01-01T00:00:01Z"}
EOF
tmux -L "$SOCK" send-keys -t "$S11_P" \
  "echo '{\"session_id\":\"$SID11E\",\"cwd\":\"/tmp/s11\",\"hook_event_name\":\"SessionEnd\"}' | claude-rescue-log session_end" \
  Enter
sleep 2
S11E_ACTIVE_CONTENT=$(cat "$HOME_DIR/active/$S11_PUUID" 2>/dev/null | tr -d '\n')
assert "scenario 11e: SessionEnd preserves active sid when hibernated marker exists" "$SID11E" "$S11E_ACTIVE_CONTENT"
# Clean up the marker so it doesn't bleed into later scenarios.
rm -f "$HOME_DIR/cache/hibernated/$S11_PUUID.json"

# ---------------------------------------------------------------------------
# resurrect-save now diffs the new snapshot against the previous one (same
# source-of-truth and dedupe key as bin/claude-rescue-backfill). Cross-server
# isolation is structural — each server's resurrect-dir holds its own
# snapshots, so the prev-lookup never crosses servers.
#
# The snapshot-diff title/pane-died inference was RETIRED in 4e99ce9: the
# 1Hz watcher (cmd_title_now / cmd_pane_died) owns those events now, and
# cmd_resurrect_save deliberately emits nothing (a diff here would duplicate
# the watcher events). This scenario pins the retirement — a regression
# that re-adds emission would double every title event.
#
# Test that saves — first, changed-title, unchanged-title, and with a
# sibling resurrect-dir present — emit ZERO title events, while the sidecar
# (resurrect-save remaining job) is still written.
echo "[scenario 12] resurrect-save emits no title events (diff retired; sidecar still written)"

# Set up a fresh pane with @claude-* options; previous scenarios may have
# killed off $PA's window. The diff resolves uuids via the sidecar, which
# cmd_resurrect_save writes from live tmux state — so the test pane must
# exist with both @claude-window-id and @claude-pane-id set.
tmux -L "$SOCK" new-window -t t1
S12_P=$(tmux -L "$SOCK" display-message -p -t t1 -F '#{pane_id}')
wait_for_shell "$S12_P"
emit_session_start "$S12_P" "$(uuidgen|tr A-Z a-z)" "/tmp/s12" startup
sleep 2
S12_SN=$(tmux -L "$SOCK" display-message -p -t "$S12_P" '#{session_name}')
S12_WI=$(tmux -L "$SOCK" display-message -p -t "$S12_P" '#{window_index}')
S12_PI=$(tmux -L "$SOCK" display-message -p -t "$S12_P" '#{pane_index}')
S12_WU=$(tmux -L "$SOCK" show-options -wv -t "$S12_P" @claude-window-id)

# Helper: write a fake resurrect snapshot containing one pane line. Other
# fields are placeholders; resurrect-save only reads cols 1, 2, 3, 6, 7, 10.
write_fake_snap() {
  local path="$1" title="$2"
  printf 'pane\t%s\t%s\t1\t:flags\t%s\t%s\t:dir\t1\tclaude\t:cmd\n' \
    "$S12_SN" "$S12_WI" "$S12_PI" "$title" > "$path"
}

S12_DIR="$HOME_DIR/resurrect-scenario12"
mkdir -p "$S12_DIR"
S12_LOG="$HOME_DIR/windows/$S12_WU.jsonl"
# Pause the asynchronous watcher so this scenario measures only the
# resurrect-save hook. Otherwise a legitimate title-now event can land between
# the baseline read and assertion and make the retired-diff test flaky.
S12_WATCHER_PID_FILE="$HOME_DIR/watcher-$SOCK.pid"
S12_WATCHER_PID="$(cat "$S12_WATCHER_PID_FILE" 2>/dev/null || true)"
if [ -n "$S12_WATCHER_PID" ]; then
  kill -TERM "$S12_WATCHER_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$S12_WATCHER_PID" 2>/dev/null || break
    sleep 0.1
  done
fi
S12_BASE=$(grep '"kind":"title"' "$S12_LOG" 2>/dev/null | wc -l | tr -d ' ')

# (a) First save — no prev snapshot in this dir → no diff → no event.
S12_T1="$S12_DIR/tmux_resurrect_20260101T000001.txt"
write_fake_snap "$S12_T1" "alpha"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-save $S12_T1"
sleep 1
S12_AFTER1=$(grep '"kind":"title"' "$S12_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert "scenario 12a: first save (no prev) emits no title event" "$S12_BASE" "$S12_AFTER1"

# (b) Second save with changed title — exactly one new title event.
sleep 1  # ensure mtime ordering for the prev-lookup
S12_T2="$S12_DIR/tmux_resurrect_20260101T000002.txt"
write_fake_snap "$S12_T2" "beta"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-save $S12_T2"
sleep 1
S12_AFTER2=$(grep '"kind":"title"' "$S12_LOG" 2>/dev/null | wc -l | tr -d ' ')
S12_DELTA2=$((S12_AFTER2 - S12_AFTER1))
assert "scenario 12b: changed title emits NO event (diff retired; watcher owns titles)" "0" "$S12_DELTA2"
# The sidecar is resurrect-save remaining job — assert it landed.
assert "scenario 12b: sidecar written alongside the save" "1" \
  "$([ -f "${S12_T2%.txt}.claude-userops.tsv" ] && echo 1 || echo 0)"

# (c) Third save with unchanged title — no new event.
sleep 1
S12_T3="$S12_DIR/tmux_resurrect_20260101T000003.txt"
write_fake_snap "$S12_T3" "beta"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-save $S12_T3"
sleep 1
S12_AFTER3=$(grep '"kind":"title"' "$S12_LOG" 2>/dev/null | wc -l | tr -d ' ')
S12_DELTA3=$((S12_AFTER3 - S12_AFTER2))
assert "scenario 12c: further saves emit no title events" "0" "$S12_DELTA3"

# (d) A sibling resurrect-dir's snapshot does not become the prev for this dir.
S12_OTHER="$HOME_DIR/resurrect-scenario12-other"
mkdir -p "$S12_OTHER"
S12_OT1="$S12_OTHER/tmux_resurrect_20260101T000010.txt"
write_fake_snap "$S12_OT1" "from-other-server"
# Touch the other dir's snapshot to a NEWER mtime than this dir's latest.
touch "$S12_OT1"
sleep 1
S12_T4="$S12_DIR/tmux_resurrect_20260101T000004.txt"
write_fake_snap "$S12_T4" "beta"   # still "beta"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-save $S12_T4"
sleep 1
S12_AFTER4=$(grep '"kind":"title"' "$S12_LOG" 2>/dev/null | wc -l | tr -d ' ')
S12_DELTA4=$((S12_AFTER4 - S12_AFTER3))
assert "scenario 12d: sibling resurrect-dir present — still no title events" "0" "$S12_DELTA4"

# Resume normal asynchronous Capture/title tracking for later scenarios.
tmux -L "$SOCK" run-shell -b "claude-rescue-watcher-ensure"
for _ in $(seq 1 30); do
  S12_NEW_WATCHER_PID="$(cat "$S12_WATCHER_PID_FILE" 2>/dev/null || true)"
  [ -n "$S12_NEW_WATCHER_PID" ] && kill -0 "$S12_NEW_WATCHER_PID" 2>/dev/null && break
  sleep 0.1
done

# ---------------------------------------------------------------------------
# Snapshot-race lock: continuum's status-bar-interval save can fire DURING
# tmux-resurrect's restore window, capturing partial state and rotating
# `last` to point at it. The next `cmd_resurrect_restore` reads the new
# `last`, finds either no sidecar or one written before @claude-pane-id was
# set, and bails — @claude-pane-id never re-applies. We close that window
# with a `.restoring` lock file:
#   pre-restore-all hook creates it
#   save-guarded.sh bails if it exists
#   post-restore-all hook removes it
echo "[scenario 13] snapshot-race lock prevents save during restore"

S13_DIR="$HOME_DIR/resurrect-scenario13"
mkdir -p "$S13_DIR"

# Point @resurrect-dir at the fake dir so our hooks find the right lock path.
tmux -L "$SOCK" set-option -g @resurrect-dir "$S13_DIR"

# (a) pre-restore-all creates the lock.
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-pre-restore-all"
sleep 1
[ -f "$S13_DIR/.restoring" ] && S13_LOCK_A=present || S13_LOCK_A=absent
assert "scenario 13a: pre-restore-all creates .restoring lock" "present" "$S13_LOCK_A"

# (b) save-guarded.sh bails when the lock exists. We mock the inner save
# script with a sentinel that writes a marker file; if save-guarded calls
# through, the marker appears. With the lock present, it must NOT appear.
# Propagate the override via `tmux set-environment` — env vars set in the
# calling shell do NOT cross tmux's run-shell boundary.
S13_MARKER="$S13_DIR/save-was-called"
S13_MOCK="$HOME_DIR/mock-save.sh"
cat > "$S13_MOCK" <<EOF
#!/bin/sh
touch "$S13_MARKER"
EOF
chmod +x "$S13_MOCK"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_RESURRECT_SAVE "$S13_MOCK"

rm -f "$S13_MARKER"
tmux -L "$SOCK" run-shell "$REPO/scripts/save-guarded.sh quiet"
sleep 1
[ -f "$S13_MARKER" ] && S13_RAN_LOCKED=ran || S13_RAN_LOCKED=bailed
assert "scenario 13b: save-guarded.sh bails when lock present" "bailed" "$S13_RAN_LOCKED"

# (c) post-restore-all removes the lock.
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-post-restore-all"
sleep 1
[ -f "$S13_DIR/.restoring" ] && S13_LOCK_C=present || S13_LOCK_C=absent
assert "scenario 13c: post-restore-all removes .restoring lock" "absent" "$S13_LOCK_C"

# (d) save-guarded.sh runs through when the lock is gone.
rm -f "$S13_MARKER"
tmux -L "$SOCK" run-shell "$REPO/scripts/save-guarded.sh quiet"
sleep 1
[ -f "$S13_MARKER" ] && S13_RAN_UNLOCKED=ran || S13_RAN_UNLOCKED=bailed
assert "scenario 13d: save-guarded.sh runs when lock absent" "ran" "$S13_RAN_UNLOCKED"
tmux -L "$SOCK" set-environment -gu CLAUDE_RESCUE_RESURRECT_SAVE

# Reset @resurrect-dir to the test fixture's default for downstream scenarios.
tmux -L "$SOCK" set-option -g @resurrect-dir "$HOME_DIR/resurrect-default"

# ---------------------------------------------------------------------------
# Wrapper resolution: find-sessions must run even when the saved tmux-resurrect
# cmdline still has `-r <stale_sid>` in argv. Pre-fix the wrapper gated the
# find-sessions block behind "no existing -r", so any /resume'd pane silently
# resumed the original pre-/resume session (P3 won over P2). We removed both
# the gate AND the P3 fallback — the wrapper now goes active → find-sessions
# → fresh, and the saved -r is stripped from final_args but never used as a
# resume target.
echo "[scenario 14] wrapper resolves via find-sessions with stale -r in argv"

# Set up a pane with @claude-pane-id pointing at a window whose meta has a
# known session_id. Clear the active file so P1 misses; the only path left
# that can produce a target_uuid is P2 (find-sessions).
tmux -L "$SOCK" new-window -t t1
S14_P=$(tmux -L "$SOCK" display-message -p -t t1 -F '#{pane_id}')
wait_for_shell "$S14_P"
SID14=$(uuidgen|tr A-Z a-z)
STALE14=$(uuidgen|tr A-Z a-z)
emit_session_start "$S14_P" "$SID14" "/tmp/s14" startup
sleep 2
S14_PUUID=$(tmux -L "$SOCK" show-options -pv -t "$S14_P" @claude-pane-id)
# Drop the active file written by SessionStart so P1 can't satisfy the lookup.
rm -f "$HOME_DIR/active/$S14_PUUID"

# Create a transcript on disk for find-sessions's existence filter to pass.
S14_PROJECTS="$HOME_DIR/projects"
S14_ENC="$(printf '%s' /tmp/s14 | tr '/.' '--')"
mkdir -p "$S14_PROJECTS/$S14_ENC"
touch "$S14_PROJECTS/$S14_ENC/$SID14.jsonl"

# Run the wrapper in debug mode with a STALE -r argv. The output's "resume
# target" line tells us which sid won. Pre-fix: target = STALE14. Post-fix:
# target = SID14 (from find-sessions, ignoring argv).
#
# The wrapper uses bare `tmux` to read @claude-pane-id, which defaults to
# the system socket. Point it at the test server by setting $TMUX explicitly
# (the format tmux's clients use internally: socket_path,server_pid,-1).
S14_TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path},#{pid},-1')"
S14_OUTPUT=$(
  TMUX="$S14_TMUX" \
  TMUX_PANE="$S14_P" \
  CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" \
  CLAUDE_PROJECTS_DIR="$S14_PROJECTS" \
  bash "$REPO/bin/claude-rescue-resume" --debug \
    --add-dir /tmp -r "$STALE14" 2>&1 < /dev/null
)
S14_TARGET=$(printf '%s\n' "$S14_OUTPUT" | awk -F': ' '/resume target/{gsub(/ .*$/,"",$2); print $2}')
assert "scenario 14: wrapper uses find-sessions sid, not stale -r" "$SID14" "$S14_TARGET"

# ---------------------------------------------------------------------------
# arm-sweep voluntary-exit detection has a guard against the case where
# claude is alive in the pane's process tree but pane_current_command is
# momentarily a tool subprocess (Bash, etc.). Without the guard, arm-sweep
# clears @claude-pane-id + active-session + arm.pid out from under a
# perfectly healthy claude. Observed on the 2026-05-12 rollout follow-up:
# pane %10's @claude-pane-id was wiped despite claude (-r ff9f468c) being
# the running process — pane_current_command had transiently flipped while
# claude exec'd a tool.
echo "[scenario 15] arm-sweep guards a live claude in the pane subtree"

# Build a pane whose pane_current_command is the shell (NOT claude), but
# which has a process named `claude` alive as a direct child of pane_pid.
# `pgrep -x claude` matches against the argv[0] basename — so we need a
# process invoked as `.../claude`. A shell script with shebang gets the
# interpreter's comm (`sh`/`bash`); `cp /bin/sleep $TMP/claude` works on
# Linux but on macOS the copy fails code-signing and is SIGKILL'd. A
# symlink to /bin/sleep keeps the original binary's signature AND makes
# argv[0]'s basename "claude" — best of both.
S15_DIR="$HOME_DIR/scenario15"
mkdir -p "$S15_DIR"
ln -sf /bin/sleep "$S15_DIR/claude"

tmux -L "$SOCK" new-window -t t1
S15_P=$(tmux -L "$SOCK" display-message -p -t t1 -F '#{pane_id}')
wait_for_shell "$S15_P"
# Stamp @claude-pane-id + write active file so arm-sweep sees a "claude
# pane" candidate. Without these the pane fails the puuid gate and
# arm-sweep skips it before reaching voluntary-exit.
S15_PUUID=$(uuidgen|tr A-Z a-z)
S15_SID=$(uuidgen|tr A-Z a-z)
tmux -L "$SOCK" set-option -pt "$S15_P" @claude-pane-id "$S15_PUUID"
mkdir -p "$HOME_DIR/active"
printf '%s' "$S15_SID" > "$HOME_DIR/active/$S15_PUUID"

# Spawn the sentinel `claude` (= /bin/sleep) as a direct child of the
# pane shell. 9999s is well past the test's lifetime; the cleanup kill
# below removes it.
tmux -L "$SOCK" send-keys -t "$S15_P" "$S15_DIR/claude 9999 &" Enter
sleep 1
S15_PANE_PID=$(tmux -L "$SOCK" display-message -p -t "$S15_P" '#{pane_pid}')
S15_SENTINEL_PID=$(pgrep -P "$S15_PANE_PID" -x claude 2>/dev/null | head -1)
assert_nonempty "scenario 15 setup: sentinel claude alive under pane shell" "$S15_SENTINEL_PID"
# pane_current_command should be the shell, not claude — confirms the
# transient-tool-exec setup we want to test against.
S15_CUR_CMD=$(tmux -L "$SOCK" display-message -p -t "$S15_P" '#{pane_current_command}')
[ "$S15_CUR_CMD" != "claude" ] || echo "WARN scenario 15: pane_current_command=$S15_CUR_CMD (expected non-claude)"

# Trigger arm-sweep.
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log arm-sweep"
sleep 1

# The guard must have kept @claude-pane-id + active file intact.
S15_PUUID_AFTER=$(tmux -L "$SOCK" show-options -pv -t "$S15_P" @claude-pane-id 2>/dev/null)
assert "scenario 15: arm-sweep preserves @claude-pane-id when claude is alive in subtree" "$S15_PUUID" "$S15_PUUID_AFTER"
[ -f "$HOME_DIR/active/$S15_PUUID" ] && S15_ACTIVE_AFTER=present || S15_ACTIVE_AFTER=absent
assert "scenario 15: arm-sweep preserves active file when claude is alive in subtree" "present" "$S15_ACTIVE_AFTER"

# Cleanup: kill the sentinel so it doesn't haunt the test server.
[ -n "$S15_SENTINEL_PID" ] && kill -TERM "$S15_SENTINEL_PID" 2>/dev/null

# ---------------------------------------------------------------------------
# Fork vs duplicate-resume. Claude Code <= 2.1.213 announced a --fork-session
# pane as source=resume carrying the PARENT's id; from 2.1.214 it reports
# source=fork carrying the fork's OWN id (verified on 2.1.257). Neither the
# fork path nor the duplicate-resume guard had any coverage, so the guard could
# silently stop matching reality on a Claude Code upgrade.
echo "[scenario 17] fork stamps its own id; duplicate resume is declined"

tmux -L "$SOCK" new-window -t t1
S17_PA=$(tmux -L "$SOCK" display-message -p -t t1 -F '#{pane_id}')
wait_for_shell "$S17_PA"
tmux -L "$SOCK" new-window -t t1
S17_PB=$(tmux -L "$SOCK" display-message -p -t t1 -F '#{pane_id}')
wait_for_shell "$S17_PB"

# Pane A owns a session.
S17_PARENT=$(uuidgen|tr A-Z a-z)
emit_session_start "$S17_PA" "$S17_PARENT" "/tmp/s17" startup
sleep 2
S17_UA=$(tmux -L "$SOCK" show-options -pv -t "$S17_PA" @claude-pane-id)
assert "scenario 17a: parent pane owns the session" \
  "$S17_PARENT" "$(cat "$HOME_DIR/active/$S17_UA" 2>/dev/null | tr -d '\n')"

# (b) Pane B forks: source=fork with its OWN new id. The guard must NOT fire —
# the id is unique, so declining it would leave the fork untracked.
S17_FORK=$(uuidgen|tr A-Z a-z)
emit_session_start "$S17_PB" "$S17_FORK" "/tmp/s17" fork
sleep 2
S17_UB=$(tmux -L "$SOCK" show-options -pv -t "$S17_PB" @claude-pane-id)
assert "scenario 17b: forked pane is stamped with its own id" \
  "$S17_FORK" "$(cat "$HOME_DIR/active/$S17_UB" 2>/dev/null | tr -d '\n')"
assert "scenario 17c: fork does not disturb the parent pane" \
  "$S17_PARENT" "$(cat "$HOME_DIR/active/$S17_UA" 2>/dev/null | tr -d '\n')"

# (d) Duplicate resume: pane B resumes the id pane A still holds. The guard
# MUST decline, or two live panes collide on one id.
emit_session_start "$S17_PB" "$S17_PARENT" "/tmp/s17" resume
sleep 2
assert "scenario 17d: duplicate resume does not steal the parent's id" \
  "$S17_FORK" "$(cat "$HOME_DIR/active/$S17_UB" 2>/dev/null | tr -d '\n')"

# ---------------------------------------------------------------------------
# Retention on the DEFAULT route. Every earlier resurrect-save assertion runs
# either without claude-rescue-state on PATH or against the retired legacy
# archive path, so the route production actually takes had no coverage — which
# is how hot-dir and debug pruning were lost when checkpoints moved behind the
# State Owner. This drives the real hook and asserts every store it must bound.
echo "[scenario 16] default save route bounds every store"

S16_RD="$HOME_DIR/retention-hot"
mkdir -p "$S16_RD"

# More checkpoints than CLAUDE_RESCUE_HOT_KEEP, each with its sidecar.
S16_TOTAL=20
for i in $(seq 1 $S16_TOTAL); do
  S16_STAMP=$(printf '20260521T0000%02d' "$i")
  printf 'window\tsess\t1\t1\t:\twuuid-A\npane\tsess\t1\t1\twuuid-A\tpuuid-A\n' \
    > "$S16_RD/tmux_resurrect_$S16_STAMP.txt"
  printf 'pane\tsess\t1\t1\tpuuid-A\n' \
    > "$S16_RD/tmux_resurrect_$S16_STAMP.claude-userops.tsv"
done
# Sidecars whose checkpoint upstream rotation already removed. Pairing sidecar
# deletion to checkpoint deletion can never reach these.
for i in $(seq 1 7); do
  printf 'stray\n' > "$S16_RD/tmux_resurrect_20260520T0000$(printf '%02d' "$i").claude-userops.tsv"
done
printf 'content-A' > "$S16_RD/pane_contents.tar.gz"
# A debug log old enough to be outside the keep window.
mkdir -p "$HOME_DIR/debug"
printf 'row\n' > "$HOME_DIR/debug/scenario16-2026-01-01.log"
touch -t 202601010000 "$HOME_DIR/debug/scenario16-2026-01-01.log"

# The real hook, through tmux, with the State Owner reachable on PATH.
tmux -L "$SOCK" run-shell "$REPO/bin/claude-rescue-log resurrect-save $S16_RD/tmux_resurrect_20260521T000020.txt"
sleep 0.5

S16_INDEXED=$(CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache \
  "$REPO/bin/claude-rescue-state" status 2>/dev/null | jq -r '.archive_saves // 0')
[ "$S16_INDEXED" -gt 0 ] && S16_INGESTED=yes || S16_INGESTED=no
assert "scenario 16a: default route indexes the checkpoint" "yes" "$S16_INGESTED"

# `last` must outrank age — it is what a restore actually loads.
ln -sf "tmux_resurrect_20260521T000001.txt" "$S16_RD/last"

CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache \
  "$REPO/bin/claude-rescue-state" retention-run --all >/dev/null 2>&1

# The orphan check is `created_at < now - grace`, strictly — which is what
# stops a blob from being collected in the same second it was written, before
# the save row referencing it lands. With grace pinned to 0 here, a blob whose
# save is thinned in the same second as the pass survives that pass by design.
# Step past the boundary and drain again so 16g reads a settled state instead
# of a one-second window (observed flaking ~1 run in 6).
sleep 1.1
CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache \
  "$REPO/bin/claude-rescue-state" retention-run --all >/dev/null 2>&1

S16_STATES=$(find "$S16_RD" -maxdepth 1 -name 'tmux_resurrect_*.txt' -type f | wc -l | tr -d ' ')
[ "$S16_STATES" -le $((CLAUDE_RESCUE_HOT_KEEP + 1)) ] && S16_HOT_BOUNDED=yes || S16_HOT_BOUNDED=no
assert "scenario 16b: hot dir is bounded on the default route" "yes" "$S16_HOT_BOUNDED"

[ -f "$S16_RD/tmux_resurrect_20260521T000001.txt" ] && S16_PINNED=yes || S16_PINNED=no
assert "scenario 16c: restore target survives the prune" "yes" "$S16_PINNED"

S16_ORPHANS=$(find "$S16_RD" -maxdepth 1 -name 'tmux_resurrect_20260520T*.claude-userops.tsv' | wc -l | tr -d ' ')
assert "scenario 16d: sidecars without a checkpoint are collected" "0" "$S16_ORPHANS"

# Every surviving sidecar still pairs with a surviving checkpoint.
S16_UNPAIRED=0
while IFS= read -r S16_TSV; do
  [ -f "${S16_TSV%.claude-userops.tsv}.txt" ] || S16_UNPAIRED=$((S16_UNPAIRED + 1))
done < <(find "$S16_RD" -maxdepth 1 -name '*.claude-userops.tsv' -type f)
assert "scenario 16e: no sidecar outlives its checkpoint" "0" "$S16_UNPAIRED"

[ -f "$HOME_DIR/debug/scenario16-2026-01-01.log" ] && S16_DEBUG=present || S16_DEBUG=absent
assert "scenario 16f: aged debug logs are collected" "absent" "$S16_DEBUG"

# A blob whose last save row is gone can never be read again — the .hash file
# went with the save — so it must not wait out the age window on disk.
S16_ORPHAN_BLOB=$(CLAUDE_RESCUE_DATA_HOME=$HOME_DIR python3 - <<'PY'
import os, sqlite3
db = os.path.join(os.environ["CLAUDE_RESCUE_DATA_HOME"], "state", "state.db")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
print(con.execute(
    "SELECT COUNT(*) FROM archive_blobs b WHERE NOT EXISTS ("
    "SELECT 1 FROM archive_saves s WHERE s.capture_hash = b.capture_hash)"
).fetchone()[0])
PY
)
assert "scenario 16g: unreferenced blobs are not retained" "0" "$S16_ORPHAN_BLOB"

# The owner learns the hot dir from what it is handed; nothing configures it.
S16_KNOWN_DIR=$(CLAUDE_RESCUE_DATA_HOME=$HOME_DIR python3 - <<'PY'
import os, sqlite3
db = os.path.join(os.environ["CLAUDE_RESCUE_DATA_HOME"], "state", "state.db")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = con.execute(
    "SELECT COUNT(*) FROM state_owner_meta WHERE key LIKE 'checkpoint_dir:%'"
).fetchone()[0]
print("yes" if rows else "no")
PY
)
assert "scenario 16h: retention learns the hot dir from ingest" "yes" "$S16_KNOWN_DIR"

rm -rf "$S16_RD"

# ---------------------------------------------------------------------------
echo "[state-owner] durable event journal, spooling, and single-writer lifecycle"
S17_STATUS=$(CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" \
  "$REPO/bin/claude-rescue-state" status 2>/dev/null || echo '{}')
S17_HISTORY_COUNT=$(printf '%s' "$S17_STATUS" | jq -r '.event_count // 0')
[ "$S17_HISTORY_COUNT" -gt 0 ] && S17_HISTORY_PRESENT=yes || S17_HISTORY_PRESENT=no
assert "legacy window events mirror into History Events" "yes" "$S17_HISTORY_PRESENT"
S17_ARCHIVE_COUNT=$(printf '%s' "$S17_STATUS" | jq -r '.archive_saves // 0')
[ "$S17_ARCHIVE_COUNT" -gt 0 ] && S17_ARCHIVE_INDEXED=yes || S17_ARCHIVE_INDEXED=no
assert "recovery checkpoints are indexed by the State Owner" "yes" "$S17_ARCHIVE_INDEXED"
S17_CAPTURE_COUNT=$(printf '%s' "$S17_STATUS" | jq -r '.capture_current // 0')
[ "$S17_CAPTURE_COUNT" -gt 0 ] && S17_CAPTURES_INDEXED=yes || S17_CAPTURES_INDEXED=no
assert "watcher Captures are indexed by the State Owner" "yes" "$S17_CAPTURES_INDEXED"
S17_LABEL_COUNT=$(tmux -L "$SOCK" list-windows -aF '#{@claude-window-label}' | grep -c . || true)
[ "$S17_LABEL_COUNT" -gt 0 ] && S17_LABELS_CACHED=yes || S17_LABELS_CACHED=no
assert "watcher caches process-free tmux window labels" "yes" "$S17_LABELS_CACHED"
S17_SESSION_STARTS=$(
  CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" \
    "$REPO/bin/claude-rescue-state" events --limit 1000 2>/dev/null \
    | grep -c '"kind":"session_start"' || true
)
[ "$S17_SESSION_STARTS" -gt 0 ] && S17_SESSION_HISTORY=yes || S17_SESSION_HISTORY=no
assert "session_start is queryable from the History Event journal" "yes" "$S17_SESSION_HISTORY"

S17_OUTPUT="$HOME_DIR/state-owner-tests.log"
if PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s "$REPO/test" -p 'test_*.py' >"$S17_OUTPUT" 2>&1; then
  S17_RESULT=pass
else
  S17_RESULT=fail
  cat "$S17_OUTPUT" >&2
fi
assert "state owner unit suite" "pass" "$S17_RESULT"

# A stale PID file may point at a live, unrelated recycled pid. The ensure path
# must replace it rather than suppressing the watcher indefinitely.
S17_WATCHER_PID_FILE="$HOME_DIR/watcher-$SOCK.pid"
S17_OLD_WATCHER_PID="$(cat "$S17_WATCHER_PID_FILE" 2>/dev/null || true)"
if [ -n "$S17_OLD_WATCHER_PID" ]; then
  kill -TERM "$S17_OLD_WATCHER_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$S17_OLD_WATCHER_PID" 2>/dev/null || break
    sleep 0.1
  done
fi
printf '%s\n' "$$" > "$S17_WATCHER_PID_FILE"
tmux -L "$SOCK" run-shell -b "$REPO/bin/claude-rescue-watcher-ensure"
S17_REPAIRED_WATCHER=no
for _ in $(seq 1 30); do
  S17_WATCHER_PID="$(cat "$S17_WATCHER_PID_FILE" 2>/dev/null || true)"
  if [ -n "$S17_WATCHER_PID" ] && [ "$S17_WATCHER_PID" != "$$" ] \
     && ps -o command= -p "$S17_WATCHER_PID" 2>/dev/null \
        | grep -Fq "$REPO/bin/claude-rescue-state watch"; then
    S17_REPAIRED_WATCHER=yes
    break
  fi
  sleep 0.1
done
assert "watcher ensure rejects a live unrelated recycled pid" "yes" "$S17_REPAIRED_WATCHER"
kill -0 $$ 2>/dev/null && S17_VALIDATOR_LIVE=yes || S17_VALIDATOR_LIVE=no
assert "watcher ensure does not signal the recycled pid target" "yes" "$S17_VALIDATOR_LIVE"

# The watcher used to trap TERM by removing its pid file without exiting,
# leaving an orphan that could attach to a later server reusing the socket.
S17_WATCHER_PID="$(cat "$S17_WATCHER_PID_FILE" 2>/dev/null || true)"
if [ -n "$S17_WATCHER_PID" ] && kill -0 "$S17_WATCHER_PID" 2>/dev/null; then
  kill -TERM "$S17_WATCHER_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$S17_WATCHER_PID" 2>/dev/null || break
    sleep 0.1
  done
fi
if [ -n "$S17_WATCHER_PID" ] && kill -0 "$S17_WATCHER_PID" 2>/dev/null; then
  S17_WATCHER_STOPPED=no
else
  S17_WATCHER_STOPPED=yes
fi
assert "watcher exits on TERM" "yes" "$S17_WATCHER_STOPPED"

# ---------------------------------------------------------------------------
echo "[picker] data subcommands return well-formed TSV/JSON"
WIN_TSV=$(CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache "$REPO/bin/claude-rescue" list-windows | head -1)
assert_nonempty "picker: list-windows returns at least one row" "$WIN_TSV"
TOP_UUID=$(printf '%s' "$WIN_TSV" | cut -f1)
PREVIEW=$(CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache "$REPO/bin/claude-rescue" preview-window "$TOP_UUID" | head -1)
assert_nonempty "picker: preview-window returns content" "$PREVIEW"

# ---------------------------------------------------------------------------
echo "[install.sh] dry-run accounts for every binary in bin/"
# Counts both "ln -s" (would link) and "already linked" (idempotent skip).
EXPECTED_BINS=$(find "$REPO/bin" -maxdepth 1 -type f | wc -l | tr -d ' ')
DR=$(bash "$REPO/scripts/install.sh" --dry-run 2>&1 | grep -cE "ln -s|already linked")
assert "install.sh dry-run accounts for all binaries" "$EXPECTED_BINS" "$DR"

# ---------------------------------------------------------------------------
# Regression: tmux's `source-file` does NOT expand `~`. A directive like
# `source-file -q '~/dev/.../rescue.tmux.conf'` silently fails (the `-q`
# eats the error), leaving all hooks unset. Prod rollout hit this and
# burned a diagnostic loop.
#
# When chezmoi source is present, scan ONLY that — it's the source of
# truth that the next `chezmoi apply` will deploy. Scanning the live
# ~/.tmux.conf in addition produced a false positive on pre-rollout
# machines: the chezmoi source is fixed but the live config is still
# the older buggy version because the operator hasn't run apply yet.
# That tripped this check at runbook step 2 (before step 4's apply),
# making the runbook's own validate gate unreachable. Falling back to
# live configs when there's no chezmoi (unmanaged machines).
echo "[tmux-conf] source-file directives don't rely on tilde expansion"
TMUX_SCAN_PATHS=()
CHEZMOI_SRC="$HOME/.local/share/chezmoi"
if [ -d "$CHEZMOI_SRC" ]; then
  [ -f "$CHEZMOI_SRC/dot_tmux.conf" ]      && TMUX_SCAN_PATHS+=("$CHEZMOI_SRC/dot_tmux.conf")
  [ -f "$CHEZMOI_SRC/dot_tmux.conf.tmpl" ] && TMUX_SCAN_PATHS+=("$CHEZMOI_SRC/dot_tmux.conf.tmpl")
  if [ -d "$CHEZMOI_SRC/dot_config/tmux" ]; then
    while IFS= read -r -d '' f; do
      TMUX_SCAN_PATHS+=("$f")
    done < <(find "$CHEZMOI_SRC/dot_config/tmux" -type f \
      \( -name '*.conf' -o -name '*.tmux' -o -name '*.conf.tmpl' -o -name '*.tmux.tmpl' \) \
      -print0)
  fi
else
  # Unmanaged machine — scan whatever's live.
  [ -f "$HOME/.tmux.conf" ] && TMUX_SCAN_PATHS+=("$HOME/.tmux.conf")
  if [ -d "$HOME/.config/tmux" ]; then
    while IFS= read -r -d '' f; do
      TMUX_SCAN_PATHS+=("$f")
    done < <(find "$HOME/.config/tmux" -type f \
      \( -name '*.conf' -o -name '*.tmux' \) -print0)
  fi
fi

# Match: source-file [-q] then optional quote then literal ~ — covers
# single-quoted, double-quoted, and bare tilde paths. All three are
# silently broken because tmux doesn't expand ~ regardless of quoting.
TILDE_PAT="^[[:space:]]*source-file([[:space:]]+-q)?[[:space:]]+['\"]?~"
TMUX_BAD_REPORT=""
for f in "${TMUX_SCAN_PATHS[@]}"; do
  [ -f "$f" ] || continue
  HITS=$(grep -nE "$TILDE_PAT" "$f" 2>/dev/null || true)
  if [ -n "$HITS" ]; then
    TMUX_BAD_REPORT="$TMUX_BAD_REPORT$f: $HITS; "
  fi
done

if [ -n "$TMUX_BAD_REPORT" ]; then
  RESULTS+=("FAIL  source-file with tilde path (tmux won't expand): $TMUX_BAD_REPORT  (use \$HOME or absolute)")
  FAIL=$((FAIL + 1))
elif [ "${#TMUX_SCAN_PATHS[@]}" -eq 0 ]; then
  RESULTS+=("PASS  no tmux configs to scan (fresh checkout)")
  PASS=$((PASS + 1))
else
  RESULTS+=("PASS  ${#TMUX_SCAN_PATHS[@]} tmux config(s) scanned, no tilde-path source-file directives")
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo "[json] all window logs are valid JSONL"
INVALID=0
for f in "$HOME_DIR/windows/"*.jsonl; do
  [ -f "$f" ] || continue
  if ! jq empty "$f" >/dev/null 2>&1; then
    INVALID=$((INVALID + 1))
  fi
done
assert "all window logs are valid JSON" "0" "$INVALID"

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
