#!/usr/bin/env bash
# 2026-10-01 regression — relaunch through the resume wrapper.
#
# One crash + restore, three panes, one per failure seen on the host:
#   A  live claude whose saved argv holds a glob char (`tag[1m]`). With the old
#      `claude->claude-rescue-resume *` mapping resurrect typed that arg into
#      zsh unquoted, zsh failed with `no matches found`, and the wrapper never
#      ran. Asserts the wrapper relaunches it with the arg intact, from
#      @claude-rescue-resume-cmd, and resumes the same session.
#   B  live claude whose relaunch dies (the snapshot gets an unknown flag, so
#      claude exits before SessionStart). Used to leave a bare shell, then
#      arm-sweep read it as a voluntary exit and wiped @claude-pane-id.
#      Asserts the failed-relaunch watch pre-fills it and its identity survives
#      arm-sweep.
#   C  claude soft-hibernated under a NESTED shell, so resurrect saves the pane
#      as a shell and never relaunches it. Crash-promote used to skip it
#      anyway, leaving it blank. Asserts it gets a plain hard marker and the
#      normal print + pre-fill.
set -uo pipefail

SOCK=crrl
export CLAUDE_RESCUE_DATA_HOME=/work/data
export CLAUDE_RESCUE_CACHE_HOME=/work/data/cache
export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
export CLAUDE_RESCUE_SOFT_DELAY="${CLAUDE_RESCUE_SOFT_DELAY:-6}"
export CLAUDE_RESCUE_HARD_DELAY=99999          # keep soft panes SOFT
export CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES=0
export IS_SANDBOX=1
# CLR_MODE as for harness.sh (compose defaults it to dual). dual: continuum's
# own auto-restore fires too, so restore runs twice on one boot and the second
# pass meets panes whose relaunch is already under way. single: restore-wrapper
# is the sole restore path, as the dotfiles deploy it.
MODE="${CLR_MODE:-dual}"
CONF=/opt/claude-rescue/test/docker/container-single-trigger.tmux.conf
[ "$MODE" = dual ] && CONF=/opt/claude-rescue/test/docker/container.tmux.conf
RDIR="$CLAUDE_RESCUE_DATA_HOME/resurrect"
KEYLOG="$CLAUDE_RESCUE_DATA_HOME/send-keys.log"
ENV_VARS=(CLAUDE_RESCUE_DATA_HOME CLAUDE_RESCUE_CACHE_HOME CLAUDE_PROJECTS_DIR \
          CLAUDE_RESCUE_SOFT_DELAY CLAUDE_RESCUE_HARD_DELAY CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES IS_SANDBOX)

PASS=0 FAIL=0; RESULTS=()
ok(){ RESULTS+=("PASS  $1"); PASS=$((PASS+1)); }
no(){ RESULTS+=("FAIL  $1"); FAIL=$((FAIL+1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (expected '$2' got '$3')"; }
yes(){ eq "$1" 1 "$( (eval "$2") >/dev/null 2>&1 && echo 1 || echo 0)"; }
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
pane_by_uuid(){ tmux_ list-panes -aF '#{pane_id} #{@claude-pane-id}' 2>/dev/null | awk -v u="$1" '$2==u{print $1; exit}'; }
marker(){ jq -r "${2:-.}" "$CLAUDE_RESCUE_CACHE_HOME/hibernated/$1.json" 2>/dev/null; }
claude_args(){ local pp c; pp="$(tmux_ display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)"
  for c in $(pgrep -P "${pp:-0}" 2>/dev/null); do
    [ "$(ps -o comm= -p "$c" 2>/dev/null | sed 's|.*/||')" = claude ] && { ps -o args= -p "$c"; return; }
  done; }

# Start a real claude in pane $1 (zsh line $2), give it a transcript, and print
# "<uuid> <sid>" once SessionStart has stamped both.
start_claude(){ local p="$1" line="$2" u="" sid="" w
  tmux_ send-keys -t "$p" "$line" Enter
  wait_cmd "$p" claude 40 || { tmux_ capture-pane -p -t "$p" | tail -15 >&2; return 1; }
  for ((w=0;w<45;w++)); do
    u="$(pane_uuid "$p")"; [ -n "$u" ] && break
    # Org-managed settings: approve them in this throwaway container (option 1
    # is preselected). Only the first claude per container asks.
    if tmux_ capture-pane -p -t "$p" | grep -q "Yes, I trust these settings"; then
      echo "  $p: accepted managed-settings approval" >&2
      tmux_ send-keys -t "$p" Enter; sleep 2
    fi
    sleep 1
  done
  sid="$(head -1 "$CLAUDE_RESCUE_DATA_HOME/active/$u" 2>/dev/null | tr -d '\n')"
  [ -n "$u" ] && [ -n "$sid" ] || { echo "  no uuid/sid for $p (uuid='$u')" >&2
    tmux_ capture-pane -p -t "$p" | sed '/^[[:space:]]*$/d' | tail -12 >&2
    ls -la "$CLAUDE_RESCUE_DATA_HOME/active" >&2; tail -5 "$CLAUDE_RESCUE_CACHE_HOME/rescue-log.err" >&2
    return 1; }
  # Resumable only once claude has written the transcript (find-sessions and
  # `claude -r` both need it), i.e. after a first message. Keys sent while
  # claude is still booting are dropped, so resend until the transcript lands.
  for ((w=0;w<90;w++)); do
    find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name "$sid.jsonl" | grep -q . && break
    if [ $((w % 15)) -eq 0 ]; then
      tmux_ send-keys -t "$p" C-u "Reply with exactly: READY"; sleep 1
      tmux_ send-keys -t "$p" Enter
    fi
    sleep 1
  done
  find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name "$sid.jsonl" | grep -q . \
    || { echo "  no transcript for $sid" >&2
         tmux_ capture-pane -p -J -t "$p" -S - | sed '/^[[:space:]]*$/d' | tail -25 >&2
         ls -R "$CLAUDE_PROJECTS_DIR" | tail -8 >&2; return 1; }
  echo "$u $sid"
}

PROJ=/work/proj-rl
mkdir -p "$CLAUDE_PROJECTS_DIR" "$PROJ"
t="$(mktemp)"; jq --arg p "$PROJ" \
  '.projects[$p]={hasTrustDialogAccepted:true,hasTrustDialogHooksAccepted:true,hasCompletedProjectOnboarding:true,bypassPermissionsModeAccepted:true}' \
  "$HOME/.claude.json" > "$t" && mv "$t" "$HOME/.claude.json"

log "BOOT 1"
boot_server; sleep 2

log "A: live claude with a glob char in its argv"
PA="$(tmux_ new-window -t main -c "$PROJ" -P -F '#{pane_id}')"
read -r UA SIDA < <(start_claude "$PA" "cl --append-system-prompt 'tag[1m]'") || exit 1
echo "  A pane=$PA uuid=$UA sid=$SIDA"

log "B: live claude whose relaunch will die"
PB="$(tmux_ new-window -t main -c "$PROJ" -P -F '#{pane_id}')"
read -r UB SIDB < <(start_claude "$PB" "cl") || exit 1
echo "  B pane=$PB uuid=$UB sid=$SIDB"

log "C: claude under a nested shell, soft-hibernated"
PC="$(tmux_ new-window -t main -c "$PROJ" -P -F '#{pane_id}')"
tmux_ send-keys -t "$PC" "zsh" Enter; sleep 2
read -r UC SIDC < <(start_claude "$PC" "cl") || exit 1
echo "  C pane=$PC uuid=$UC sid=$SIDC"
tmux_ new-window -t main -c /work; sleep 1      # park focus away from C
for ((w=0;w<40;w++)); do [ -f "$CLAUDE_RESCUE_CACHE_HOME/busy/$UC" ] || break; sleep 1; done
tmux_ run-shell "claude-rescue-log hibernate-arm $PC $(tmux_ display-message -p -t "$PC" '#{pane_pid}')"
for ((w=0;w<CLAUDE_RESCUE_SOFT_DELAY+30;w++)); do
  [ "$(marker "$UC" '.mode // empty')" = soft ] && break; sleep 1
done
eq "C: marker is soft before the crash" "soft" "$(marker "$UC" '.mode // empty')"

log "save -> B gets an unknown flag -> crash -> restore"
tmux_ run-shell "$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh" 2>/dev/null || true
sleep 3
SNAP="$(readlink -f "$RDIR/last" 2>/dev/null || true)"
[ -n "$SNAP" ] && [ -f "$SNAP" ] || { echo "  no snapshot file"; exit 1; }
WA="$(tmux_ display-message -p -t "$PA" '#{window_index}')"
WB="$(tmux_ display-message -p -t "$PB" '#{window_index}')"
WC="$(tmux_ display-message -p -t "$PC" '#{window_index}')"
snap_cmd(){ awk -F'\t' -v w="$1" '$1=="pane" && $2=="main" && $3==w {print $11; exit}' "$SNAP"; }
echo "  A saved: $(snap_cmd "$WA" | cut -c1-150)"
echo "  C saved: $(snap_cmd "$WC")"
yes "A: snapshot holds the glob arg" '[[ "$(snap_cmd "$WA")" == *"tag[1m]"* ]]'
yes "C: snapshot does NOT show claude (nested shell)" '! [[ "$(snap_cmd "$WC")" =~ ^:claude( |$) ]]'
awk 'BEGIN{FS=OFS="\t"} $1=="pane" && $2=="main" && $3=='"$WB"' && $11 ~ /^:claude / {$11=$11" --no-such-flag-xyz"} 1' \
  "$SNAP" > "$SNAP.tmp" && mv "$SNAP.tmp" "$SNAP"
yes "B: snapshot now carries the bad flag" '[[ "$(snap_cmd "$WB")" == *"--no-such-flag-xyz" ]]'

OLD="$(tmux_ display-message -p '#{pid}')"; kill -9 "$OLD" 2>/dev/null || true
for i in 1 2 3 4 5; do tmux_ has-session 2>/dev/null || break; sleep 1; done
boot_server probe

# A comes back as claude; B's watch fires once its relaunch dies; C is
# pre-filled by the normal pass. Wait for all three, bounded.
RA="" RB="" RC=""
for ((w=0;w<90;w++)); do
  RA="$(pane_by_uuid "$UA")"; RB="$(pane_by_uuid "$UB")"; RC="$(pane_by_uuid "$UC")"
  a_ok=0; [ -n "$RA" ] && [ "$(fg_cmd "$RA")" = claude ] && [ ! -f "$CLAUDE_RESCUE_CACHE_HOME/hibernated/$UA.json" ] && a_ok=1
  b_ok=0; grep -aq "reason=relaunch-failed-clr pane=${RB:-none} .*clr\\\\ $SIDB" "$KEYLOG" 2>/dev/null && b_ok=1
  c_ok=0; grep -aq "reason=post-restore-clr pane=${RC:-none} .*clr\\\\ $SIDC" "$KEYLOG" 2>/dev/null && c_ok=1
  [ "$a_ok$b_ok$c_ok" = 111 ] && break
  sleep 2
done

log "VERIFY"
tmux_ list-panes -aF '    #{pane_id} cmd=#{pane_current_command} puid=#{@claude-pane-id}' 2>/dev/null
echo "  send-keys.log:"; tail -8 "$KEYLOG" 2>/dev/null | cut -c1-170 | sed 's/^/    /'
echo "  wrapper.log:"; tail -6 "$CLAUDE_RESCUE_DATA_HOME/wrapper.log" 2>/dev/null | cut -c1-260 | sed 's/^/    /'
echo "  rescue-log.err:"; grep -a 'resurrect-restore' "$CLAUDE_RESCUE_CACHE_HOME/rescue-log.err" 2>/dev/null | tail -6 | sed 's/^/    /'
echo "  active files:"; for u in "$UA" "$UB" "$UC"; do echo "    $u=$(head -1 "$CLAUDE_RESCUE_DATA_HOME/active/$u" 2>/dev/null)"; done
echo "  rescue-log.err (B):"; grep -a "$UB\|${RB:-none} " "$CLAUDE_RESCUE_CACHE_HOME/rescue-log.err" 2>/dev/null | tail -6 | sed 's/^/    /'
echo "  restore-keys.err:"; tail -5 "$CLAUDE_RESCUE_CACHE_HOME/restore-keys.err" 2>/dev/null | sed 's/^/    /'
for p in "$RA" "$RB"; do
  echo "  pane $p screen:"; tmux_ capture-pane -p -J -t "$p" -S - 2>/dev/null | sed '/^\s*$/d' | tail -12 | cut -c1-200 | sed 's/^/    /'
done

# A
eq "A: pane restored and found by uuid" 1 "$([ -n "$RA" ] && echo 1 || echo 0)"
eq "A: wrapper relaunched claude" claude "$(fg_cmd "$RA")"
ARGS_A="$(claude_args "$RA")"; echo "  A claude argv: ${ARGS_A:0:200}"
yes "A: glob arg reached claude intact" '[[ "$ARGS_A" == *"tag[1m]"* ]]'
yes "A: resumed session A (-r SIDA)" '[[ "$ARGS_A" == *"-r $SIDA"* ]]'
yes "A: no zsh nomatch error in the pane" '! tmux_ capture-pane -p -t "$RA" -S - | grep -q "no matches found"'
yes "A: wrapper logged args from @claude-rescue-resume-cmd" \
    'grep -aq "saved-args .*pane=$RA .*from @claude-rescue-resume-cmd" "$CLAUDE_RESCUE_DATA_HOME/wrapper.log"'
eq "A: @claude-rescue-resume-cmd consumed" "" "$(tmux_ show-options -pqv -t "$RA" @claude-rescue-resume-cmd)"
yes "A: crash-promote marker cleared by SessionStart" '[ ! -f "$CLAUDE_RESCUE_CACHE_HOME/hibernated/$UA.json" ]'
yes "A: no restore keys typed into the relaunched claude" '! grep -aqE "reason=(post-restore|relaunch-failed)-[a-z]+ pane=$RA " "$KEYLOG"'

# B
eq "B: pane restored and found by uuid" 1 "$([ -n "$RB" ] && echo 1 || echo 0)"
yes "B: relaunch-failed pre-fill sent with session B" \
    'grep -aq "reason=relaunch-failed-clr pane=$RB .*clr\\\\ $SIDB" "$KEYLOG"'
eq "B: marker demoted to plain hard" "hard -" "$(marker "$UB" '"\(.mode) \(.hard_source // "-")"')"
yes "B: pane shows the pre-fill" 'tmux_ capture-pane -p -t "$RB" | grep -q "clr $SIDB"'
tmux_ run-shell -b "claude-rescue-log arm-sweep" 2>/dev/null || true; sleep 5   # -b, as wired in tmux
eq "B: @claude-pane-id survives arm-sweep" "$UB" "$(pane_uuid "$RB")"

# C
eq "C: pane restored and found by uuid" 1 "$([ -n "$RC" ] && echo 1 || echo 0)"
eq "C: marker is plain hard (not crash-promote)" "hard -" "$(marker "$UC" '"\(.mode) \(.hard_source // "-")"')"
yes "C: post-restore pre-fill sent with session C" \
    'grep -aq "reason=post-restore-clr pane=$RC .*clr\\\\ $SIDC" "$KEYLOG"'
yes "C: pane shows the pre-fill" 'tmux_ capture-pane -p -t "$RC" | grep -q "clr $SIDC"'

log "RESULTS"; for r in "${RESULTS[@]}"; do echo "  $r"; done
echo ""; echo "TOTAL: $PASS passed, $FAIL failed"
printf 'RESULT_JSON: {"scenario":"relaunch","mode":"%s","pass":%s,"fail":%s}\n' "$MODE" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
