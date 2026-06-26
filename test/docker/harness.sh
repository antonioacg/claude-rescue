#!/usr/bin/env bash
# In-container harness for the dual-trigger restore idempotency test.
#
# Runs a REAL stack — real claude (authenticated via the injected token), real
# tmux 3.6a, real tmux-resurrect + tmux-continuum — in full isolation, so the
# test server is the ONLY tmux server. That makes continuum's own auto-restore
# fire AND the boot-guard restore-wrapper fire on the same boot: the genuine
# production DUAL restore-trigger that caused the 2026-06-05 incident.
#
# Flow: boot tmux -> N real claude panes -> hard-hibernate each -> save ->
# kill -9 the server (crash) -> reboot (dual-trigger restore) -> assert each
# pane's pre-fill is exactly-once (idempotency guard), cwd-anchored, no garble.
#
# Exits 0 on all-pass, non-zero otherwise.
set -uo pipefail

SOCK=crdt
export CLAUDE_RESCUE_DATA_HOME=/work/data
export CLAUDE_RESCUE_CACHE_HOME=/work/data/cache
export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
export CLAUDE_RESCUE_SOFT_DELAY="${CLAUDE_RESCUE_SOFT_DELAY:-6}"
export CLAUDE_RESCUE_HARD_DELAY="${CLAUDE_RESCUE_HARD_DELAY:-12}"
export CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES=0
# Tell claude it's in a sandbox so `--permission-mode bypassPermissions` (used by
# the cl/clr aliases) doesn't show the interactive "accept bypass mode" warning.
export IS_SANDBOX=1
CONF=/opt/claude-rescue/test/docker/container.tmux.conf
RDIR="$CLAUDE_RESCUE_DATA_HOME/resurrect"
NPANES="${NPANES:-2}"
ENV_VARS=(CLAUDE_RESCUE_DATA_HOME CLAUDE_RESCUE_CACHE_HOME CLAUDE_PROJECTS_DIR \
          CLAUDE_RESCUE_SOFT_DELAY CLAUDE_RESCUE_HARD_DELAY CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES \
          IS_SANDBOX)

PASS=0 FAIL=0; RESULTS=()
ok(){   RESULTS+=("PASS  $1"); PASS=$((PASS+1)); }
no(){   RESULTS+=("FAIL  $1"); FAIL=$((FAIL+1)); }
eq(){   [ "$2" = "$3" ] && ok "$1" || no "$1 (expected '$2' got '$3')"; }

log(){ printf '\n=== %s ===\n' "$*"; }

tmux_(){ tmux -L "$SOCK" "$@"; }

boot_server(){
  local envassign=()
  local v; for v in "${ENV_VARS[@]}"; do envassign+=("$v=${!v}"); done
  env "${envassign[@]}" tmux -L "$SOCK" -f "$CONF" new-session -d -s main -x 220 -y 50
  for v in "${ENV_VARS[@]}"; do tmux_ set-environment -g "$v" "${!v}"; done
}

wait_cmd(){ # pane target_cmd timeout
  local p="$1" want="$2" t="${3:-30}" i cmd
  for ((i=0;i<t;i++)); do
    cmd="$(tmux_ display-message -p -t "$p" '#{pane_current_command}' 2>/dev/null || true)"
    [ "$cmd" = "$want" ] && return 0
    sleep 1
  done
  echo "  wait_cmd: $p never became '$want' (last='$cmd')" >&2; return 1
}

pane_uuid(){ tmux_ show-options -pv -t "$1" @claude-pane-id 2>/dev/null; }
fg_cmd(){ tmux_ display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null; }

# --- per-project trust --------------------------------------------------------
# Credentials, claude-rescue tracking hooks, and global onboarding/bypass flags
# are seeded by entrypoint.sh (so an interactive shell is also ready). Here we
# only add each test project dir to the trust list so claude doesn't prompt on
# first open of /work/projN.
mkdir -p "$CLAUDE_PROJECTS_DIR" /work
for ((n=1;n<=NPANES;n++)); do
  mkdir -p "/work/proj$n"
  tmp_cfg="$(mktemp)"
  jq --arg p "/work/proj$n" \
    '.projects[$p]={hasTrustDialogAccepted:true,hasTrustDialogHooksAccepted:true,hasCompletedProjectOnboarding:true,bypassPermissionsModeAccepted:true}' \
    "$HOME/.claude.json" > "$tmp_cfg" && mv "$tmp_cfg" "$HOME/.claude.json"
done

log "BOOT 1 — setup server (only tmux server in container)"
boot_server
sleep 2
echo "tmux server pid=$(tmux_ display-message -p '#{pid}')  tmux $(tmux_ -V 2>/dev/null || tmux -V)"

# --- set up N real claude panes, then hard-hibernate each ----------------------
declare -a PANE_IDS PANE_UUIDS PANE_SIDS PANE_CWDS
for ((n=1;n<=NPANES;n++)); do
  cwd="/work/proj$n"; mkdir -p "$cwd"
  log "pane $n — launch real claude in $cwd"
  if [ "$n" -eq 1 ]; then
    tmux_ send-keys -t main:1 "cd $cwd && cl" Enter
    pane="main:1.1"
  else
    tmux_ new-window -t main -c "$cwd"
    tmux_ send-keys -t "main:$n" "cl" Enter
    pane="main:$n.1"
  fi
  wait_cmd "$pane" claude 40 || { echo "claude failed to start in $pane"; tmux_ capture-pane -p -t "$pane" | tail -20; exit 1; }
  sleep 3
  # Drive a prompt so a transcript is written (find-sessions needs the jsonl).
  tmux_ send-keys -t "$pane" "Reply with exactly: READY" Enter
  # Poll until the SessionStart hook mints @claude-pane-id (claude fully up +
  # tracked). A fixed sleep races slower panes — that left pane 2 untracked.
  uuid=""
  for ((w=0;w<45;w++)); do uuid="$(pane_uuid "$pane")"; [ -n "$uuid" ] && break; sleep 1; done
  [ -n "$uuid" ] || { echo "  pane $n: @claude-pane-id never set"; tmux_ capture-pane -p -t "$pane" | tail -15; exit 1; }
  sleep 6   # let the prompt response land so the transcript exists for find-sessions
  echo "  pane=$pane uuid=$uuid cmd=$(fg_cmd "$pane")"
  PANE_IDS[$n]="$pane"; PANE_UUIDS[$n]="$uuid"; PANE_CWDS[$n]="$cwd"
done

# Park focus on a non-claude window so EVERY claude pane is backgrounded.
# hibernate-arm intentionally bails on the ACTIVE pane (hibernation is
# focus-driven — you don't suspend the pane you're looking at), so the
# currently-focused claude window would never hibernate otherwise.
tmux_ new-window -t main -c /work
sleep 1

log "hard-hibernate every claude pane (serial: wait idle -> arm -> verify)"
for ((n=1;n<=NPANES;n++)); do
  p="${PANE_IDS[$n]}"; u="${PANE_UUIDS[$n]}"
  # Wait for claude to go idle first (hibernate-arm skips a busy pane).
  for ((w=0;w<40;w++)); do [ -f "$CLAUDE_RESCUE_CACHE_HOME/busy/$u" ] || break; sleep 1; done
  # Resolve the pane id + pid EXPLICITLY for the target. `run-shell -t X
  # "...#{pane_id}..."` expands the format against the ACTIVE pane, not X — so
  # arming a non-active window would otherwise re-arm the active pane and leave
  # this one untouched.
  pid_pane="$(tmux_ display-message -p -t "$p" '#{pane_id}')"
  pid_pid="$(tmux_ display-message -p -t "$p" '#{pane_pid}')"
  tmux_ run-shell "claude-rescue-log hibernate-arm $pid_pane $pid_pid"
  # Wait out the soft->hard escalation for THIS pane before moving on.
  for ((w=0; w<CLAUDE_RESCUE_HARD_DELAY+20; w++)); do
    [ "$(jq -r '.mode // empty' "$CLAUDE_RESCUE_CACHE_HOME/hibernated/$u.json" 2>/dev/null)" = hard ] && break
    sleep 1
  done
done
for ((n=1;n<=NPANES;n++)); do
  u="${PANE_UUIDS[$n]}"
  mode="$(jq -r '.mode // empty' "$CLAUDE_RESCUE_CACHE_HOME/hibernated/$u.json" 2>/dev/null || true)"
  sid="$(jq -r '.session_id // empty' "$CLAUDE_RESCUE_DATA_HOME/captures/$u.json" 2>/dev/null || true)"
  PANE_SIDS[$n]="$sid"
  eq "pane $n hard-hibernated (marker mode=hard)" "hard" "$mode"
  eq "pane $n back at shell (claude exited)" "zsh" "$(fg_cmd "${PANE_IDS[$n]}")"
  echo "  pane $n: uuid=$u sid=${sid:-<none>} cwd=${PANE_CWDS[$n]}"
done

log "save (resurrect) — writes snapshot + sidecar"
tmux_ run-shell "$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh" 2>/dev/null || true
sleep 3
[ -e "$RDIR/last" ] && ok "resurrect snapshot written" || no "resurrect snapshot written"

OLD_PID="$(tmux_ display-message -p '#{pid}')"
log "CRASH — kill -9 the tmux server (pid=$OLD_PID)"
kill -9 "$OLD_PID" 2>/dev/null || true
for i in 1 2 3 4 5; do tmux_ has-session 2>/dev/null || break; sleep 1; done
tmux_ has-session 2>/dev/null && { echo "server still alive after kill"; exit 1; }
: > "$CLAUDE_RESCUE_DATA_HOME/send-keys.log" 2>/dev/null || true   # scope post-restore counts
rm -rf "$CLAUDE_RESCUE_CACHE_HOME/post-restore-claims" 2>/dev/null || true

log "BOOT 2 — reboot server => DUAL-TRIGGER restore (continuum + boot-guard)"
boot_server
NEW_PID="$(tmux_ display-message -p '#{pid}')"
echo "new server pid=$NEW_PID (old=$OLD_PID)"
# Wait out both post-restore subshells (each: 5s sleep + sends) plus restore.
sleep 18

# --- assertions ----------------------------------------------------------------
log "VERIFY — dual trigger fired, pre-fill idempotent + cwd-anchored"
# Evidence both restore triggers ran: two pre-restore-pane-processes hook fires.
HOOK_FIRES="$(grep -c 'resurrect-restore: hook fired' "$CLAUDE_RESCUE_CACHE_HOME/rescue-log.err" 2>/dev/null || true)"
echo "  resurrect-restore hook fires this boot: ${HOOK_FIRES:-0} (expect >=2 for dual-trigger)"
[ "${HOOK_FIRES:-0}" -ge 2 ] && ok "dual trigger: restore hook fired >=2x" || no "dual trigger: restore hook fired >=2x (got ${HOOK_FIRES:-0})"

for ((n=1;n<=NPANES;n++)); do
  u="${PANE_UUIDS[$n]}"; sid="${PANE_SIDS[$n]}"; cwd="${PANE_CWDS[$n]}"
  [ -n "$sid" ] || { no "pane $n has a captured sid"; continue; }
  # exactly ONE pre-fill for this session despite two concurrent restore passes
  c="$(grep -c "post-restore-clr.*$sid" "$CLAUDE_RESCUE_DATA_HOME/send-keys.log" 2>/dev/null || true)"
  eq "pane $n: exactly one post-restore-clr (idempotent under dual-trigger)" "1" "${c:-0}"
  # exactly one claim dir for the pane
  cd_count="$(find "$CLAUDE_RESCUE_CACHE_HOME/post-restore-claims" -mindepth 1 -maxdepth 1 -type d -name "*__$u" 2>/dev/null | wc -l | tr -d ' ')"
  eq "pane $n: exactly one idempotency claim dir" "1" "${cd_count:-0}"
  # Scan ALL restored panes' content for this session's cwd-anchored pre-fill.
  # Robust to the dual-restore creating duplicate/extra panes (uuid lookup is
  # fragile there). The idempotency guard means exactly ONE pane should carry it.
  match=0 garble=0 nonshell=0
  while read -r rp; do
    [ -n "$rp" ] || continue
    buf="$(tmux_ capture-pane -p -t "$rp" -S - 2>/dev/null)"
    if printf '%s' "$buf" | grep -qE "cd $cwd && clr $sid"; then
      match=$((match+1))
      [ "$(fg_cmd "$rp")" = zsh ] || nonshell=$((nonshell+1))
      printf '%s' "$buf" | grep -qE "clr ${sid}[A-Za-z]" && garble=$((garble+1))
    fi
  done < <(tmux_ list-panes -aF '#{pane_id}' 2>/dev/null)
  eq "pane $n: cwd-anchored pre-fill 'cd $cwd && clr <sid>' in exactly one pane" "1" "$match"
  eq "pane $n: pre-fill pane at shell (no executed garble)" "0" "$nonshell"
  eq "pane $n: no garbled concatenation after sid" "0" "$garble"
done

log "RESULTS"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
# Machine-readable summary for orchestrate.py to aggregate across parallel runs.
printf 'RESULT_JSON: {"npanes":%s,"pass":%s,"fail":%s}\n' "$NPANES" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
