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
# burned a diagnostic loop. If the user's rendered ~/.tmux.conf exists,
# scan it for the bad pattern.
echo "[tmux-conf] source-file directives don't rely on tilde expansion"
if [ -f "$HOME/.tmux.conf" ]; then
  BAD_TILDE=$(grep -nE "^[[:space:]]*source-file[[:space:]]+(-q[[:space:]]+)?['\"]~" "$HOME/.tmux.conf" || true)
  if [ -n "$BAD_TILDE" ]; then
    RESULTS+=("FAIL  ~/.tmux.conf has source-file with tilde path: $BAD_TILDE  (use \$HOME or absolute)")
    FAIL=$((FAIL + 1))
  else
    RESULTS+=("PASS  ~/.tmux.conf source-file directives use \$HOME or absolute paths")
    PASS=$((PASS + 1))
  fi
else
  RESULTS+=("PASS  ~/.tmux.conf not present — skipped tilde scan")
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
