#!/usr/bin/env bash
# #2 regression — multi-session-per-pane cwd disambiguation.
#
# A pane that hosted more than one session yields >=2 find-sessions rows for a
# single pane_uuid (sorted newest-first by `started`). The post-restore pre-fill
# must anchor the CAPTURED session's cwd (the find-sessions row whose col1 ==
# $sid), NOT find-sessions' newest row (`head -1`). The default harness only
# runs one session per pane, so head -1 == the only row and the fix is never
# exercised (see docs/operations/rca-2026-06-05-restore-keystroke-race.md,
# "Residual test coverage").
#
# This pins it: run a REAL session A in proj-a (capture sid = A, cwd proj-a),
# then FABRICATE a NEWER find-sessions row — session B in proj-b for the SAME
# pane_uuid (append a session to the window meta + create its jsonl, started far
# in the future so it sorts first). Now `head -1` = B@proj-b (the WRONG anchor)
# and `col1 == $A` = proj-a (the RIGHT anchor). After save -> crash -> restore,
# assert the pre-fill is `cd proj-a && clr A` and NEVER `cd proj-b`. A revert to
# `head -1` would emit `cd proj-b` and fail.
#
# Single-trigger config: one clean restore pass (this scenario is about cwd
# resolution, not trigger count; the dual-trigger scramble is covered elsewhere).
set -uo pipefail

SOCK=crdt
export CLAUDE_RESCUE_DATA_HOME=/work/data
export CLAUDE_RESCUE_CACHE_HOME=/work/data/cache
export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
export CLAUDE_RESCUE_SOFT_DELAY="${CLAUDE_RESCUE_SOFT_DELAY:-6}"
export CLAUDE_RESCUE_HARD_DELAY="${CLAUDE_RESCUE_HARD_DELAY:-12}"
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

PROJA=/work/proj-a PROJB=/work/proj-b
mkdir -p "$CLAUDE_PROJECTS_DIR" "$PROJA" "$PROJB"
for p in "$PROJA" "$PROJB"; do
  t="$(mktemp)"; jq --arg p "$p" \
    '.projects[$p]={hasTrustDialogAccepted:true,hasTrustDialogHooksAccepted:true,hasCompletedProjectOnboarding:true,bypassPermissionsModeAccepted:true}' \
    "$HOME/.claude.json" > "$t" && mv "$t" "$HOME/.claude.json"
done

log "BOOT 1"
boot_server; sleep 2

log "session A — real claude in $PROJA"
PANE="$(tmux_ new-window -t main -c "$PROJA" -P -F '#{pane_id}')"
tmux_ send-keys -t "$PANE" "cl" Enter
wait_cmd "$PANE" claude 40 || { tmux_ capture-pane -p -t "$PANE" | tail -20; exit 1; }
sleep 3
tmux_ send-keys -t "$PANE" "Reply with exactly: READY" Enter
U=""; for ((w=0;w<45;w++)); do U="$(pane_uuid "$PANE")"; [ -n "$U" ] && break; sleep 1; done
[ -n "$U" ] || { echo "  no @claude-pane-id"; tmux_ capture-pane -p -t "$PANE" | tail -15; exit 1; }
sleep 6
echo "  pane=$PANE uuid=$U"

# Park focus, then hard-hibernate so the capture sid = the real session A.
tmux_ new-window -t main -c /work; sleep 1
log "hard-hibernate the pane (capture sid = session A)"
for ((w=0;w<40;w++)); do [ -f "$CLAUDE_RESCUE_CACHE_HOME/busy/$U" ] || break; sleep 1; done
pp="$(tmux_ display-message -p -t "$PANE" '#{pane_id}')"
ppid="$(tmux_ display-message -p -t "$PANE" '#{pane_pid}')"
tmux_ run-shell "claude-rescue-log hibernate-arm $pp $ppid"
for ((w=0;w<CLAUDE_RESCUE_HARD_DELAY+20;w++)); do
  [ "$(jq -r '.mode//empty' "$CLAUDE_RESCUE_CACHE_HOME/hibernated/$U.json" 2>/dev/null)" = hard ] && break; sleep 1
done
SIDA="$(jq -r '.session_id//empty' "$CLAUDE_RESCUE_DATA_HOME/captures/$U.json" 2>/dev/null)"
eq "captured session A sid present" "1" "$([ -n "$SIDA" ] && echo 1 || echo 0)"
eq "pane back at shell after hard hibernation" "zsh" "$(fg_cmd "$PANE")"
[ -n "$SIDA" ] || { echo "no SIDA; abort"; exit 1; }
echo "  SIDA=$SIDA"

# --- fabricate a NEWER find-sessions row: session B in proj-b, same pane_uuid -
log "fabricate a newer session B in $PROJB for the same pane_uuid"
SIDB="$(uuidgen | tr 'A-Z' 'a-z')"
META="$(grep -l "\"$U\"" "$CLAUDE_RESCUE_DATA_HOME/windows/"*.meta.json 2>/dev/null | head -1)"
[ -n "$META" ] || { echo "  no window meta.json holds the pane_uuid"; exit 1; }
t="$(mktemp)"
jq --arg sid "$SIDB" --arg pu "$U" --arg cwd "$PROJB" --arg ts "2099-01-01T00:00:00Z" \
   '.sessions += [{session_id:$sid, pane_uuid:$pu, started:$ts, ended:null, cwd:$cwd, source:"startup", last_title:"B"}]' \
   "$META" > "$t" && mv "$t" "$META"
ENCB="${PROJB//\//-}"; ENCB="${ENCB//./-}"
mkdir -p "$CLAUDE_PROJECTS_DIR/$ENCB"
printf '{"type":"summary"}\n' > "$CLAUDE_PROJECTS_DIR/$ENCB/$SIDB.jsonl"
echo "  SIDB=$SIDB (started 2099 -> newest -> find-sessions head -1)"

# Confirm the divergence exists: head -1 is B@proj-b, col1==SIDA is A@proj-a.
ROWS="$(claude-rescue find-sessions --pane-uuid "$U" 2>/dev/null)"
nrows="$(printf '%s\n' "$ROWS" | grep -c .)"
head1_cwd="$(printf '%s' "$ROWS" | head -1 | awk -v FS=$'\x1f' '{print $6}')"
sida_cwd="$(printf '%s' "$ROWS" | awk -v FS=$'\x1f' -v s="$SIDA" '$1==s{print $6; exit}')"
eq "find-sessions returns >=2 rows for the pane" "1" "$([ "${nrows:-0}" -ge 2 ] && echo 1 || echo 0)"
eq "head -1 row is the NEWER session (cwd proj-b) — the wrong anchor" "$PROJB" "$head1_cwd"
eq "col1==SIDA row is session A (cwd proj-a) — the right anchor"      "$PROJA" "$sida_cwd"

# --- save -> crash -> restore ----------------------------------------------
log "save -> crash -> restore (single trigger)"
tmux_ run-shell "$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh" 2>/dev/null || true
sleep 3
OLD="$(tmux_ display-message -p '#{pid}')"; kill -9 "$OLD" 2>/dev/null || true
for i in 1 2 3 4 5; do tmux_ has-session 2>/dev/null || break; sleep 1; done
: > "$CLAUDE_RESCUE_DATA_HOME/send-keys.log" 2>/dev/null || true
rm -rf "$CLAUDE_RESCUE_CACHE_HOME/post-restore-claims" 2>/dev/null || true
boot_server probe; sleep 18

# --- assert the pre-fill anchors session A's cwd (proj-a), never proj-b ------
log "VERIFY — pre-fill anchors the CAPTURED session's cwd (col1==sid, not head -1)"
echo "  restored panes:"
tmux_ list-panes -aF '    #{pane_id} cmd=#{pane_current_command} cwd=#{pane_current_path} puid=#{@claude-pane-id}' 2>/dev/null
goodA=0 badB=0
while read -r rp; do
  [ -n "$rp" ] || continue
  buf="$(tmux_ capture-pane -p -t "$rp" -S - 2>/dev/null)"
  printf '%s' "$buf" | grep -qF "cd $PROJA && clr $SIDA" && goodA=$((goodA+1))
  printf '%s' "$buf" | grep -qF "cd $PROJB && clr $SIDA" && badB=$((badB+1))
done < <(tmux_ list-panes -aF '#{pane_id}' 2>/dev/null)
eq "#2: pre-fill anchors the captured session's cwd ('cd proj-a && clr A')" "1" "$goodA"
eq "#2: pre-fill never uses the newer row's cwd ('cd proj-b') [head-1 regression guard]" "0" "$badB"

log "RESULTS"; for r in "${RESULTS[@]}"; do echo "  $r"; done
echo ""; echo "TOTAL: $PASS passed, $FAIL failed"
printf 'RESULT_JSON: {"scenario":"multisession","pass":%s,"fail":%s}\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
