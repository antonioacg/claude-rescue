#!/usr/bin/env bash
# #9 regression — wrapper-resume cwd-rescue.
#
# The cd-to-launch-dir rescue added to claude-rescue-resume lives on the
# soft-hibernation / @resurrect-processes RELAUNCH path, not the hard-hibernation
# pre-fill path the default harness exercises. If restore lands a wrapper-resumed
# pane in the wrong $PWD, the wrapper must cd to the session's launch dir before
# `exec claude` so it resumes the SAME session instead of silently starting
# fresh (see docs/operations/rca-2026-06-05-restore-keystroke-race.md, "Residual
# test coverage").
#
# Pins it end-to-end: run a REAL claude in proj-a, SOFT-hibernate it (Ctrl+Z;
# HARD_DELAY set huge so it never escalates) — that writes the capture json whose
# cwd the rescue reads, and leaves the pane saved as a claude the
# @resurrect-processes wrapper relaunches. Save, then EDIT the snapshot's pane
# dir to $HOME to force the wrong cwd, restore, and assert the wrapper landed the
# pane back in proj-a (rescued), resumed sid A (not fresh), and logged the
# cwd-rescue.
set -uo pipefail

SOCK=crdt
export CLAUDE_RESCUE_DATA_HOME=/work/data
export CLAUDE_RESCUE_CACHE_HOME=/work/data/cache
export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
export CLAUDE_RESCUE_SOFT_DELAY="${CLAUDE_RESCUE_SOFT_DELAY:-6}"
export CLAUDE_RESCUE_HARD_DELAY=99999          # keep it SOFT (never escalate)
export CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES=0
export IS_SANDBOX=1
CONF=/opt/claude-rescue/test/docker/container-single-trigger.tmux.conf
RDIR="$CLAUDE_RESCUE_DATA_HOME/resurrect"
ENV_VARS=(CLAUDE_RESCUE_DATA_HOME CLAUDE_RESCUE_CACHE_HOME CLAUDE_PROJECTS_DIR \
          CLAUDE_RESCUE_SOFT_DELAY CLAUDE_RESCUE_HARD_DELAY CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES IS_SANDBOX)

PASS=0 FAIL=0; RESULTS=()
ok(){ RESULTS+=("PASS  $1"); PASS=$((PASS+1)); }
no(){ RESULTS+=("FAIL  $1"); FAIL=$((FAIL+1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (expected '$2' got '$3')"; }
log(){ printf '\n=== %s ===\n' "$*"; }
tmux_(){ tmux -L "$SOCK" "$@"; }
boot_server(){
  local sess="${1:-main}" ea=() v
  for v in "${ENV_VARS[@]}"; do ea+=("$v=${!v}"); done
  env "${ea[@]}" tmux -L "$SOCK" -f "$CONF" new-session -d -s "$sess" -x 220 -y 50
  for v in "${ENV_VARS[@]}"; do tmux_ set-environment -g "$v" "${!v}"; done
}
wait_cmd(){ local p="$1" want="$2" t="${3:-30}" i cmd
  for ((i=0;i<t;i++)); do cmd="$(tmux_ display-message -p -t "$p" '#{pane_current_command}' 2>/dev/null||true)"
    [ "$cmd" = "$want" ] && return 0; sleep 1; done
  echo "  wait_cmd: $p never '$want' (last='$cmd')" >&2; return 1; }
pane_uuid(){ tmux_ show-options -pv -t "$1" @claude-pane-id 2>/dev/null; }
fg_cmd(){ tmux_ display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null; }

PROJA=/work/proj-a
mkdir -p "$CLAUDE_PROJECTS_DIR" "$PROJA"
t="$(mktemp)"; jq --arg p "$PROJA" \
  '.projects[$p]={hasTrustDialogAccepted:true,hasTrustDialogHooksAccepted:true,hasCompletedProjectOnboarding:true,bypassPermissionsModeAccepted:true}' \
  "$HOME/.claude.json" > "$t" && mv "$t" "$HOME/.claude.json"

log "BOOT 1"
boot_server; sleep 2

log "real claude in $PROJA"
PANE="$(tmux_ new-window -t main -c "$PROJA" -P -F '#{pane_id}')"
tmux_ send-keys -t "$PANE" "cl" Enter
wait_cmd "$PANE" claude 40 || { tmux_ capture-pane -p -t "$PANE" | tail -20; exit 1; }
sleep 3
tmux_ send-keys -t "$PANE" "Reply with exactly: READY" Enter
U=""; for ((w=0;w<45;w++)); do U="$(pane_uuid "$PANE")"; [ -n "$U" ] && break; sleep 1; done
[ -n "$U" ] || { echo "  no @claude-pane-id"; tmux_ capture-pane -p -t "$PANE" | tail -15; exit 1; }
sleep 6
SIDA="$(cat "$CLAUDE_RESCUE_DATA_HOME/active/$U" 2>/dev/null | head -1 | tr -d '\n')"
eq "active-file holds session A sid" "1" "$([ -n "$SIDA" ] && echo 1 || echo 0)"
[ -n "$SIDA" ] || { echo "no SIDA; abort"; exit 1; }
echo "  pane=$PANE uuid=$U sid=$SIDA"

# Park focus, then SOFT-hibernate (Ctrl+Z). HARD_DELAY is huge so it stays soft.
# Soft hibernation writes captures/<uuid>.json (cwd=proj-a) — the cd-rescue's
# candidate — and leaves the pane as a claude the wrapper relaunches on restore.
tmux_ new-window -t main -c /work; sleep 1
log "soft-hibernate the pane (Ctrl+Z; stays soft)"
for ((w=0;w<40;w++)); do [ -f "$CLAUDE_RESCUE_CACHE_HOME/busy/$U" ] || break; sleep 1; done
pp="$(tmux_ display-message -p -t "$PANE" '#{pane_id}')"
ppid="$(tmux_ display-message -p -t "$PANE" '#{pane_pid}')"
tmux_ run-shell "claude-rescue-log hibernate-arm $pp $ppid"
swait=$((CLAUDE_RESCUE_SOFT_DELAY + 30))
for ((w=0;w<swait;w++)); do
  [ "$(jq -r '.mode//empty' "$CLAUDE_RESCUE_CACHE_HOME/hibernated/$U.json" 2>/dev/null)" = soft ] && break
  sleep 1
done
MODE0="$(jq -r '.mode//empty' "$CLAUDE_RESCUE_CACHE_HOME/hibernated/$U.json" 2>/dev/null)"
eq "marker is soft (not escalated)" "soft" "$MODE0"
CAP_CWD="$(jq -r '.cwd//empty' "$CLAUDE_RESCUE_DATA_HOME/captures/$U.json" 2>/dev/null)"
eq "capture json cwd is proj-a (the cd-rescue candidate)" "$PROJA" "$CAP_CWD"

log "save -> snapshot dir edit (force \$HOME) -> crash -> restore"
tmux_ run-shell "$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh" 2>/dev/null || true
sleep 3
SNAP="$(readlink -f "$RDIR/last" 2>/dev/null || true)"
[ -n "$SNAP" ] && [ -f "$SNAP" ] || { echo "  no snapshot file"; exit 1; }
# Show the claude pane line, then rewrite its dir field (col 8 = :cwd) to $HOME.
echo "  claude pane line BEFORE:"; grep -aE '^pane.*claude' "$SNAP" | head -1 | cut -c1-160
awk 'BEGIN{FS=OFS="\t"} $1=="pane" && $8==":'"$PROJA"'"{$8=":"ENVIRON["HOME"]} 1' "$SNAP" > "$SNAP.tmp" && mv "$SNAP.tmp" "$SNAP"
echo "  claude pane line AFTER:";  grep -aE '^pane.*claude' "$SNAP" | head -1 | cut -c1-160
eq "snapshot pane dir forced to \$HOME" "1" "$(grep -aE '^pane.*claude' "$SNAP" | head -1 | grep -cF ":$HOME"$'\t')"

OLD="$(tmux_ display-message -p '#{pid}')"; kill -9 "$OLD" 2>/dev/null || true
for i in 1 2 3 4 5; do tmux_ has-session 2>/dev/null || break; sleep 1; done
boot_server probe
sleep 18
# Give the wrapper-launched claude time to boot + fire SessionStart.
for ((w=0;w<30;w++)); do
  RP="$(tmux_ list-panes -aF '#{pane_id} #{@claude-pane-id}' 2>/dev/null | awk -v u="$U" '$2==u{print $1; exit}')"
  [ -n "${RP:-}" ] && [ "$(fg_cmd "$RP")" = claude ] && break; sleep 1
done

log "VERIFY — wrapper rescued the cwd and resumed the same session"
echo "  restored panes:"
tmux_ list-panes -aF '    #{pane_id} cmd=#{pane_current_command} cwd=#{pane_current_path} puid=#{@claude-pane-id}' 2>/dev/null
RP="$(tmux_ list-panes -aF '#{pane_id} #{@claude-pane-id}' 2>/dev/null | awk -v u="$U" '$2==u{print $1; exit}')"
eq "restored claude pane found by pane_uuid" "1" "$([ -n "${RP:-}" ] && echo 1 || echo 0)"
if [ -n "${RP:-}" ]; then
  eq "wrapper relaunched claude" "claude" "$(fg_cmd "$RP")"
  eq "#9: pane cwd rescued to proj-a (not \$HOME)" "$PROJA" "$(tmux_ display-message -p -t "$RP" '#{pane_current_path}' 2>/dev/null)"
  rp_pid="$(tmux_ display-message -p -t "$RP" '#{pane_pid}' 2>/dev/null)"
  cargs=""; for c in $(pgrep -P "${rp_pid:-0}" 2>/dev/null); do
    [ "$(ps -o comm= -p "$c" 2>/dev/null | sed 's|.*/||')" = claude ] && { cargs="$(ps -o args= -p "$c" 2>/dev/null)"; break; }
  done
  eq "#9: claude resumed session A (-r SIDA in argv)" "1" "$(printf '%s' "$cargs" | grep -qF -- "-r $SIDA" && echo 1 || echo 0)"
  # Resume vs fresh: a successful resume keeps the same sid in the active file.
  NEWSID="$(cat "$CLAUDE_RESCUE_DATA_HOME/active/$U" 2>/dev/null | head -1 | tr -d '\n')"
  eq "#9: resumed the SAME session (active-file still SIDA, not a fresh sid)" "$SIDA" "$NEWSID"
fi
echo "  wrapper.log cwd-rescue lines:"; grep -aF "cwd-rescue" "$CLAUDE_RESCUE_DATA_HOME/wrapper.log" 2>/dev/null | tail -3
eq "#9: wrapper logged the cwd-rescue cd to proj-a" "1" \
   "$(grep -aqF "cwd-rescue: cd $PROJA" "$CLAUDE_RESCUE_DATA_HOME/wrapper.log" 2>/dev/null && echo 1 || echo 0)"

log "RESULTS"; for r in "${RESULTS[@]}"; do echo "  $r"; done
echo ""; echo "TOTAL: $PASS passed, $FAIL failed"
printf 'RESULT_JSON: {"scenario":"wrapper-resume","pass":%s,"fail":%s}\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
