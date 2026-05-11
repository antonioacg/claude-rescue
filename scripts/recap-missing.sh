#!/usr/bin/env bash
# Send a short "please recap" prompt to claude panes whose on-disk
# transcript is missing, so they regenerate a .jsonl (with a usable
# summary in it) before a server restart or other cutover wipes their
# in-memory state.
#
# Targets come from a state-dump dir's restore-plan.tsv — rows where the
# latest_session_id column is empty. The pane's live pane_current_command
# is re-checked at send time: we never send-keys into a pane that isn't
# currently running claude, to avoid typing the prompt into a shell.
#
# Usage:
#   scripts/recap-missing.sh                       # latest dump
#   scripts/recap-missing.sh <dump-dir>            # explicit dump dir
#   scripts/recap-missing.sh --dry-run             # latest dump, no send

set -eu

PROMPT='Please recap what we built in this session and what is left to do, so I can pick it up later.'

dry=0
dump=""
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) dry=1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *) dump="$arg" ;;
  esac
done

if [ -z "$dump" ]; then
  dump="$(/bin/ls -td "$HOME/claude-rescue-dumps"/dump-* 2>/dev/null | head -1)"
  if [ -z "$dump" ]; then
    echo "No dump found under ~/claude-rescue-dumps/. Run scripts/state-dump.sh first." >&2
    exit 1
  fi
fi

plan="$dump/restore-plan.tsv"
[ -f "$plan" ] || { echo "Missing $plan" >&2; exit 1; }

echo "Using: $plan"
[ "$dry" = 1 ] && echo "(dry-run — no keys will be sent)"
echo

# restore-plan.tsv columns: session, window_idx, window_name, pane_idx,
# pane_id, cwd, latest_session_id, latest_transcript_mtime, claude_pane_uuid
awk -F'\t' 'NR>1 && $7=="" {print $5"\t"$1"\t"$2"\t"$4"\t"$6}' "$plan" \
  | while IFS=$'\t' read -r pane_id sess win pane cwd; do
      # The dump can be minutes/hours old; re-check live state. If the
      # pane isn't currently in claude (user might have hit `/exit`, or
      # the pane went away), skip — we won't type the prompt into a
      # shell where Enter would execute it.
      live_cmd="$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || echo '')"
      label="$pane_id ($sess:$win.$pane) cwd=$cwd"
      if [ "$live_cmd" != "claude" ]; then
        printf 'SKIP  %s  — live cmd is %s\n' "$label" "${live_cmd:-<gone>}"
        continue
      fi
      if [ "$dry" = 1 ]; then
        printf 'WOULD %s\n' "$label"
      else
        printf 'SEND  %s\n' "$label"
        tmux send-keys -t "$pane_id" "$PROMPT" Enter
      fi
    done
