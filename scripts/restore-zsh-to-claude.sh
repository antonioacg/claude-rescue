#!/usr/bin/env bash
# For each pane that has @claude-pane-id set but is NOT currently running
# claude, look up its session_id via `claude-rescue find-sessions
# --pane-uuid <uuid>` and send `clr <sid>` to relaunch claude. Used to
# recover after tmux-resurrect's restore_pane_process (in
# process_restore_helpers.sh:38) fires send-keys without waiting for
# shell readiness — for a server with many panes restoring in a burst,
# most panes lose their send-keys and come back as bare shells.
#
# Inter-pane delay is critical. Without it, this script would suffer the
# same race we're recovering FROM.
#
# Usage:
#   scripts/restore-zsh-to-claude.sh             # send for real
#   scripts/restore-zsh-to-claude.sh --dry-run   # preview only
#
# Env: CLAUDE_RESCUE_LIVE_SOCKET (default: "default"). When invoked from
# an operator pane on a different socket, set this to target the live
# server.

set -eu

LIVE_SOCKET="${CLAUDE_RESCUE_LIVE_SOCKET:-default}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DELAY_SECONDS="${CLAUDE_RESCUE_RESTORE_DELAY:-0.25}"

dry=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) dry=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

echo "Targeting tmux socket: $LIVE_SOCKET (override with CLAUDE_RESCUE_LIVE_SOCKET)"
echo "Inter-pane delay: ${DELAY_SECONDS}s (override with CLAUDE_RESCUE_RESTORE_DELAY)"
[ "$dry" = 1 ] && echo "(dry-run — no keys will be sent)"
echo

# US (Unit Separator, \x1f) avoids the tab-collapse-on-read issue:
# bash's `read` with IFS=$'\t' still treats tab as whitespace and collapses
# consecutive empties. \x1f isn't whitespace, so empty internal fields
# (like a missing @claude-pane-id) preserve their position.
US=$'\x1f'

sent=0
skip_already_claude=0
skip_no_uuid=0
skip_no_sid=0

# Snapshot panes to a file first so the loop body can run without depending
# on the streaming tmux command staying alive across the sleeps.
tmpfile="$(mktemp -t restore-zsh.XXXXXX)"
trap 'rm -f "$tmpfile"' EXIT

tmux -L "$LIVE_SOCKET" list-panes -aF \
  "#{pane_id}${US}#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{pane_current_command}${US}#{@claude-pane-id}" \
  > "$tmpfile" 2>/dev/null || { echo "Failed to list panes on socket $LIVE_SOCKET" >&2; exit 1; }

total_panes=$(wc -l < "$tmpfile" | tr -d ' ')
candidates=$(awk -F"$US" '$5!="claude" && $6!=""' "$tmpfile" | wc -l | tr -d ' ')
echo "Survey: $total_panes total panes, $candidates need recovery (have @claude-pane-id, not running claude)."
echo

while IFS="$US" read -r pane_id sess win_idx pane_idx live_cmd pane_uuid; do
  # Skip panes already running claude.
  if [ "$live_cmd" = "claude" ]; then
    skip_already_claude=$((skip_already_claude + 1))
    continue
  fi
  # Skip panes that never ran claude (no @claude-pane-id from sidecar).
  if [ -z "$pane_uuid" ]; then
    skip_no_uuid=$((skip_no_uuid + 1))
    continue
  fi

  # Resolve resume target via find-sessions (same path the wrapper uses).
  sid="$("$REPO/bin/claude-rescue" find-sessions --pane-uuid "$pane_uuid" 2>/dev/null \
         | head -1 | awk -v FS="$US" '{print $1}')"
  if [ -z "$sid" ]; then
    printf 'SKIP %s (%s:w%s.p%s) uuid=%s — find-sessions returned no row\n' \
      "$pane_id" "$sess" "$win_idx" "$pane_idx" "$pane_uuid"
    skip_no_sid=$((skip_no_sid + 1))
    continue
  fi

  # Live re-check just before sending — pane state may have changed since
  # the list-panes snapshot above (this matters if the loop runs slowly).
  current_cmd="$(tmux -L "$LIVE_SOCKET" display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || echo '')"
  if [ "$current_cmd" = "claude" ]; then
    printf 'SKIP %s (%s:w%s.p%s) — became claude since snapshot\n' "$pane_id" "$sess" "$win_idx" "$pane_idx"
    skip_already_claude=$((skip_already_claude + 1))
    continue
  fi

  if [ "$dry" = 1 ]; then
    printf 'WOULD %s (%s:w%s.p%s) → clr %s\n' "$pane_id" "$sess" "$win_idx" "$pane_idx" "$sid"
  else
    printf 'SEND  %s (%s:w%s.p%s) → clr %s\n' "$pane_id" "$sess" "$win_idx" "$pane_idx" "$sid"
    tmux -L "$LIVE_SOCKET" send-keys -t "$pane_id" "clr $sid" Enter
    sleep "$DELAY_SECONDS"
  fi
  sent=$((sent + 1))
done < "$tmpfile"

echo
echo "Summary: ${sent} sent  ${skip_already_claude} already-claude  ${skip_no_uuid} no-uuid  ${skip_no_sid} no-sid"
echo

if [ "$dry" = 1 ]; then
  echo "(dry-run — nothing was sent)"
  exit 0
fi

# Post-send verification: wait briefly for claudes to start, then check.
echo "Verifying (waiting 5s for claude processes to come up)..."
sleep 5
still_zsh=$(tmux -L "$LIVE_SOCKET" list-panes -aF "#{pane_id}${US}#{pane_current_command}${US}#{@claude-pane-id}" 2>/dev/null \
            | awk -F"$US" '$3!="" && $2!="claude"' | wc -l | tr -d ' ')
total_should=$(tmux -L "$LIVE_SOCKET" list-panes -aF "#{@claude-pane-id}" 2>/dev/null \
               | awk 'NF>0' | wc -l | tr -d ' ')
echo "Panes that should have claude (have @claude-pane-id): $total_should"
echo "Still zsh (not yet claude): $still_zsh"
if [ "$still_zsh" -gt 0 ]; then
  echo
  echo "Still-zsh panes (worth a manual look):" >&2
  tmux -L "$LIVE_SOCKET" list-panes -aF "#{pane_id}${US}#{session_name}:#{window_index}.#{pane_index}${US}#{pane_current_command}${US}#{@claude-pane-id}" 2>/dev/null \
    | awk -F"$US" '$4!="" && $3!="claude" {printf "  %s %s cmd=%s\n", $1, $2, $3}' >&2
fi
