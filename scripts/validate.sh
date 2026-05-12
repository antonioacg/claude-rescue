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

CLAUDE_RESCUE_DATA_HOME="$HOME_DIR" CLAUDE_RESCUE_CACHE_HOME="$HOME_DIR/cache" CLAUDE_RESCUE_REPO="$REPO" PATH="$REPO/bin:$PATH" \
  tmux -L "$SOCK" -f "$REPO/tmux/test/test.conf" \
    new-session -d -s t1 -x 200 -y 50

tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_DATA_HOME "$HOME_DIR"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_CACHE_HOME "$HOME_DIR/cache"
tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_REPO "$REPO"
tmux -L "$SOCK" set-environment -g PATH "$REPO/bin:$PATH"

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
  tmux -L "$SOCK" send-keys -t "$pane" "touch '$marker'" Enter
  local i
  for i in $(seq 1 50); do
    [ -f "$marker" ] && { rm -f "$marker"; return 0; }
    sleep 0.2
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

# (d) resurrect-restore bulk-clears the active dir.
mkdir -p "$HOME_DIR/active"
S11_ORPHAN="orphan-puuid-$$-$(date +%s)"
touch "$HOME_DIR/active/$S11_ORPHAN"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-restore"
sleep 1
[ -f "$HOME_DIR/active/$S11_ORPHAN" ] && S11_ORPHAN_STATE=present || S11_ORPHAN_STATE=absent
assert "scenario 11d: resurrect-restore bulk-clears active dir" "absent" "$S11_ORPHAN_STATE"

# ---------------------------------------------------------------------------
# resurrect-save now diffs the new snapshot against the previous one (same
# source-of-truth and dedupe key as bin/claude-rescue-backfill). Cross-server
# isolation is structural — each server's resurrect-dir holds its own
# snapshots, so the prev-lookup never crosses servers.
#
# Test that:
#  (a) first save in a fresh resurrect-dir emits no title event (no prev)
#  (b) second save with a changed title emits exactly one title event
#  (c) third save with an unchanged title emits zero new title events
#  (d) a snapshot in a sibling resurrect-dir does NOT influence the diff
echo "[scenario 12] resurrect-save snapshot-diff"

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
assert "scenario 12b: changed title emits exactly one event" "1" "$S12_DELTA2"
# Verify the emitted title is the new one.
S12_LAST_TITLE=$(grep '"kind":"title"' "$S12_LOG" 2>/dev/null | tail -1 | jq -r '.title')
assert "scenario 12b: emitted title is the new value" "beta" "$S12_LAST_TITLE"

# (c) Third save with unchanged title — no new event.
sleep 1
S12_T3="$S12_DIR/tmux_resurrect_20260101T000003.txt"
write_fake_snap "$S12_T3" "beta"
tmux -L "$SOCK" run-shell "CLAUDE_RESCUE_DATA_HOME=$HOME_DIR CLAUDE_RESCUE_CACHE_HOME=$HOME_DIR/cache $REPO/bin/claude-rescue-log resurrect-save $S12_T3"
sleep 1
S12_AFTER3=$(grep '"kind":"title"' "$S12_LOG" 2>/dev/null | wc -l | tr -d ' ')
S12_DELTA3=$((S12_AFTER3 - S12_AFTER2))
assert "scenario 12c: unchanged title emits no new event" "0" "$S12_DELTA3"

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
assert "scenario 12d: sibling resurrect-dir snapshots don't pollute prev-lookup" "0" "$S12_DELTA4"

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
shopt -s globstar nullglob
TMUX_SCAN_PATHS=()
CHEZMOI_SRC="$HOME/.local/share/chezmoi"
if [ -d "$CHEZMOI_SRC" ]; then
  [ -f "$CHEZMOI_SRC/dot_tmux.conf" ]      && TMUX_SCAN_PATHS+=("$CHEZMOI_SRC/dot_tmux.conf")
  [ -f "$CHEZMOI_SRC/dot_tmux.conf.tmpl" ] && TMUX_SCAN_PATHS+=("$CHEZMOI_SRC/dot_tmux.conf.tmpl")
  if [ -d "$CHEZMOI_SRC/dot_config/tmux" ]; then
    TMUX_SCAN_PATHS+=(
      "$CHEZMOI_SRC"/dot_config/tmux/**/*.conf
      "$CHEZMOI_SRC"/dot_config/tmux/**/*.tmux
      "$CHEZMOI_SRC"/dot_config/tmux/**/*.conf.tmpl
      "$CHEZMOI_SRC"/dot_config/tmux/**/*.tmux.tmpl
    )
  fi
else
  # Unmanaged machine — scan whatever's live.
  [ -f "$HOME/.tmux.conf" ] && TMUX_SCAN_PATHS+=("$HOME/.tmux.conf")
  [ -d "$HOME/.config/tmux" ] && TMUX_SCAN_PATHS+=( "$HOME"/.config/tmux/**/*.conf "$HOME"/.config/tmux/**/*.tmux )
fi
shopt -u globstar nullglob

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
