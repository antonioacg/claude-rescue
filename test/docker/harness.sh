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
# Trigger mode: "dual" (default) = both restore triggers (continuum + boot-guard),
# the 2026-06-05 production wiring. "single" = the cleanup variant (continuum off,
# restore-wrapper as sole path). Each selects its container config.
MODE="${CLR_MODE:-dual}"
if [ "$MODE" = single ]; then
  CONF="${CLR_CONF:-/opt/claude-rescue/test/docker/container-single-trigger.tmux.conf}"
else
  CONF="${CLR_CONF:-/opt/claude-rescue/test/docker/container.tmux.conf}"
fi
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
  # $1 = initial session name (default "main"). BOOT 1 (setup) uses "main" so
  # the SAVED session is "main". BOOT 2 (reboot) must use a DIFFERENT name: the
  # boot session is created before restore runs, and tmux-resurrect restores the
  # saved session by NAME — if the boot session is also "main", resurrect's
  # `new-session main` fails ("duplicate session: main") and the saved session's
  # FIRST window (pane 1) is dropped. Booting a throwaway name lets restore
  # recreate "main" cleanly with all its windows. (Production avoids this because
  # the boot/probe session name doesn't collide with the saved session names.)
  local sess="${1:-main}"
  local envassign=()
  local v; for v in "${ENV_VARS[@]}"; do envassign+=("$v=${!v}"); done
  env "${envassign[@]}" tmux -L "$SOCK" -f "$CONF" new-session -d -s "$sess" -x 220 -y 50
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
  # ALWAYS a fresh window (capture its pane_id) — never reuse the session's
  # initial window (win 1). The first window restores via resurrect's
  # session-create path and can come back holding a different pane (e.g. an
  # nvim window lands there), so the sidecar reapplies that pane's
  # @claude-pane-id onto the wrong pane. Keeping every claude pane in win >=2
  # makes them restore stably (win 1 stays a throwaway shell with no uuid).
  pane="$(tmux_ new-window -t main -c "$cwd" -P -F '#{pane_id}')"
  tmux_ send-keys -t "$pane" "cl" Enter
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

# --- nvim pane — proves restore brings back NON-claude processes too ---------
# Directly answers "would the cleanup still restore nvim?": nvim is restored by
# the same stock restore.sh (via @resurrect-processes + @resurrect-strategy-nvim)
# no matter which trigger fires it. Verified after restore in BOTH modes.
NVIM_FILE=/work/nvim-restore-test.md
printf 'alpha\nBRAVO-EDIT-MARKER\ncharlie\n' > "$NVIM_FILE"
NVIM_PANE="$(tmux_ new-window -t main -c /work -P -F '#{pane_id}')"
tmux_ send-keys -t "$NVIM_PANE" "nvim $NVIM_FILE" Enter
wait_cmd "$NVIM_PANE" nvim 30 || echo "  warn: nvim did not start in $NVIM_PANE"
sleep 2
echo "  nvim pane=$NVIM_PANE file=$NVIM_FILE"

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
# Diagnostic: what restore command did resurrect save for the nvim pane?
echo "  snapshot nvim line: $(grep -a nvim "$RDIR/last" 2>/dev/null | head -1 | cut -c1-180)"

OLD_PID="$(tmux_ display-message -p '#{pid}')"
log "CRASH — kill -9 the tmux server (pid=$OLD_PID)"
kill -9 "$OLD_PID" 2>/dev/null || true
for i in 1 2 3 4 5; do tmux_ has-session 2>/dev/null || break; sleep 1; done
tmux_ has-session 2>/dev/null && { echo "server still alive after kill"; exit 1; }
: > "$CLAUDE_RESCUE_DATA_HOME/send-keys.log" 2>/dev/null || true   # scope post-restore counts
rm -rf "$CLAUDE_RESCUE_CACHE_HOME/post-restore-claims" 2>/dev/null || true

if [ "$MODE" = single ]; then
  log "BOOT 2 — reboot server => SINGLE-trigger restore (restore-wrapper only)"
else
  log "BOOT 2 — reboot server => DUAL-trigger restore (continuum + boot-guard)"
fi
# Throwaway boot session name so restore recreates the saved "main" cleanly
# (see boot_server) — otherwise the saved session's first window (pane 1) is
# dropped to a "duplicate session: main" collision.
boot_server probe
NEW_PID="$(tmux_ display-message -p '#{pid}')"
echo "new server pid=$NEW_PID (old=$OLD_PID)"
# Wait out both post-restore subshells (each: 5s sleep + sends) plus restore.
sleep 18

# --- assertions ----------------------------------------------------------------
log "VERIFY — dual trigger fired, pre-fill idempotent + cwd-anchored"
# Evidence both restore triggers ran: two pre-restore-pane-processes hook fires.
HOOK_FIRES="$(grep -c 'resurrect-restore: hook fired' "$CLAUDE_RESCUE_CACHE_HOME/rescue-log.err" 2>/dev/null || true)"
if [ "$MODE" = single ]; then
  echo "  resurrect-restore hook fires this boot: ${HOOK_FIRES:-0} (expect EXACTLY 1 for single-trigger cleanup)"
  eq "single-trigger: restore hook fired exactly once (continuum off, restore-wrapper sole path)" "1" "${HOOK_FIRES:-0}"
else
  echo "  resurrect-restore hook fires this boot: ${HOOK_FIRES:-0} (expect >=2 for dual-trigger)"
  [ "${HOOK_FIRES:-0}" -ge 2 ] && ok "dual trigger: restore hook fired >=2x" || no "dual trigger: restore hook fired >=2x (got ${HOOK_FIRES:-0})"
fi

for ((n=1;n<=NPANES;n++)); do
  u="${PANE_UUIDS[$n]}"; sid="${PANE_SIDS[$n]}"; cwd="${PANE_CWDS[$n]}"
  [ -n "$sid" ] || { no "pane $n has a captured sid"; continue; }
  # #3 (find-sessions PRIMARY path): real claude wrote a real transcript, so
  # the pre-fill's cwd anchor comes from find-sessions (jsonl-validated col 6
  # for THIS sid), NOT the capture-json fallback. Assert the authoritative
  # source returns the right launch cwd for the sid — proving the primary path
  # is exercised, and (since find-sessions only returns jsonl-backed rows) that
  # `cd <launch-cwd>` lands where `claude -r <sid>` will actually resolve.
  fs_cwd="$(claude-rescue find-sessions --pane-uuid "$u" 2>/dev/null \
            | awk -v FS=$'\x1f' -v s="$sid" '$1==s {print $6; exit}')"
  eq "pane $n: find-sessions resolves launch cwd for the sid (primary path)" "$cwd" "$fs_cwd"
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

log "VERIFY — nvim (non-claude process) restored"
# Diagnostic: every restored pane + its command, so a miss is debuggable.
echo "  restored panes:"
tmux_ list-panes -aF '    #{pane_id} sess=#{session_name} win=#{window_index} cmd=#{pane_current_command} cwd=#{pane_current_path} puid=#{@claude-pane-id}' 2>/dev/null
echo "  pane tails (last non-empty line each):"
while read -r rp; do
  [ -n "$rp" ] || continue
  echo "    $rp: $(tmux_ capture-pane -p -t "$rp" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)"
done < <(tmux_ list-panes -aF '#{pane_id}' 2>/dev/null)
# Poll — nvim (esp. nvim -S <session>) can relaunch slightly slower than the
# 18s settle, and may briefly read as the shell mid-exec.
nvim_back=0 nvim_content=0 nvim_pane=""
for ((w=0; w<15; w++)); do
  while read -r rp; do
    [ -n "$rp" ] || continue
    if [ "$(fg_cmd "$rp")" = nvim ]; then nvim_back=1; nvim_pane="$rp"; break; fi
  done < <(tmux_ list-panes -aF '#{pane_id}' 2>/dev/null)
  [ "$nvim_back" = 1 ] && break
  sleep 1
done
# Buffer check: assert the restored nvim PROCESS is editing the saved file
# (its argv contains the file). The rendered-content capture-grep is
# rendering/startup-config dependent (the user's nvim may open a dashboard) and
# flaky; the process args are deterministic and prove the file buffer is back.
if [ -n "$nvim_pane" ]; then
  np_shell="$(tmux_ display-message -p -t "$nvim_pane" '#{pane_pid}' 2>/dev/null)"
  for c in $(pgrep -P "${np_shell:-0}" 2>/dev/null); do
    if [ "$(ps -o comm= -p "$c" 2>/dev/null | sed 's|.*/||')" = nvim ]; then
      ps -o args= -p "$c" 2>/dev/null | grep -q "nvim-restore-test.md" && nvim_content=1
      break
    fi
  done
fi
eq "nvim process restored after $MODE-trigger restore" "1" "$nvim_back"
eq "nvim restored editing the saved file (buffer back)" "1" "$nvim_content"

log "RESULTS"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
# Machine-readable summary for orchestrate.py to aggregate across parallel runs.
printf 'RESULT_JSON: {"mode":"%s","npanes":%s,"pass":%s,"fail":%s}\n' "$MODE" "$NPANES" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
