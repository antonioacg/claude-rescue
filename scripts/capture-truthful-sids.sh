#!/usr/bin/env bash
# Capture the truthful (pane -> session_id) map by scraping each claude pane's
# bottom status area. Claude Code renders the active session UUID a few lines
# above the "bypass permissions" footer; that string is the only signal that
# survives /resume, --fork-session, manual jsonl moves, and multi-pane cwds —
# all of which break the mtime-based heuristic used by state-dump.sh's
# restore-plan.tsv and backfill-pane-uuids.sh.
#
# Source per pane (in priority order):
#   1. Live `tmux capture-pane` if pane_current_command is claude.
#   2. Hibernation capture at $DATA/captures/<pane_uuid>.txt if claude has
#      been Ctrl+Z'd (pane_current_command flips to the shell while the
#      claude process sits in T state — but its last visible scrollback,
#      including the UUID footer, is preserved on disk).
#   3. Empty (claude crashed without firing the capture path, or never
#      reached the trust prompt).
#
# Output TSV columns (header row included):
#   session  window_idx  pane_idx  pane_id  pane_uuid  cwd
#   visible_sid  jsonl_path  jsonl_exists  source
#
# - source: live | capture | empty — where the sid was read from.
# - jsonl_exists: yes/no — does the file at jsonl_path exist? "no" means
#   the sid is in-memory only (forked session not yet flushed) and a
#   recap-style prompt is needed before kill-server, or context is lost.
#
# Usage:
#   scripts/capture-truthful-sids.sh                 # stdout
#   scripts/capture-truthful-sids.sh --output FILE   # write to FILE
#   scripts/capture-truthful-sids.sh --tail N        # scrape last N lines per
#                                                    # pane (default 8).
#
# Target tmux server: $CLAUDE_RESCUE_LIVE_SOCKET or `default`.

set -eu

LIVE_SOCKET="${CLAUDE_RESCUE_LIVE_SOCKET:-default}"
TAIL=8
OUTPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output|-o)  OUTPUT="$2"; shift 2 ;;
    --tail)       TAIL="$2"; shift 2 ;;
    -h|--help)    sed -n '2,33p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *)            echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
PROJECTS_ROOT="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
DATA="${CLAUDE_RESCUE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-rescue}"
CAPTURES_DIR="$DATA/captures"

emit() {
  if [ -n "$OUTPUT" ]; then printf '%s\n' "$1" >> "$OUTPUT"
  else printf '%s\n' "$1"
  fi
}

# Reset output file if specified.
[ -n "$OUTPUT" ] && : > "$OUTPUT"

emit $'session\twindow_idx\tpane_idx\tpane_id\tpane_uuid\tcwd\tvisible_sid\tjsonl_path\tjsonl_exists\tsource'

# Iterate every pane that's either currently running claude OR has a
# @claude-pane-id set (covers hibernated / Ctrl+Z'd claudes whose
# pane_current_command shows the shell while claude is suspended).
tmux -L "$LIVE_SOCKET" list-panes -aF \
  $'#{pane_id}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_command}\t#{pane_current_path}\t#{@claude-pane-id}' \
  2>/dev/null \
  | awk -F'\t' '$5=="claude" || $7!=""' \
  | while IFS=$'\t' read -r pane_id sess win pane cmd cwd puuid; do
      sid=""
      source="empty"

      if [ "$cmd" = "claude" ]; then
        # Live pane: scrape current display. tail=8 covers the status area
        # (model line + sid line + bypass-permissions line + footer). The
        # closest-to-bottom UUID is claude's own footer; earlier UUIDs in the
        # captured area (tool output, etc.) lose to `tail -1`.
        sid="$(tmux -L "$LIVE_SOCKET" capture-pane -t "$pane_id" -p 2>/dev/null \
               | tail -"$TAIL" \
               | grep -oE "$UUID_RE" \
               | tail -1)" || sid=""
        [ -n "$sid" ] && source="live"
      fi

      if [ -z "$sid" ] && [ -n "$puuid" ] && [ -f "$CAPTURES_DIR/$puuid.txt" ]; then
        # Hibernated / exited claude: read the on-disk capture saved by
        # cmd_hibernate_arm at SIGTSTP time. ANSI escapes in the capture
        # don't interfere with the UUID regex (UUIDs are alphanumeric +
        # hyphens, no ANSI overlap).
        sid="$(tail -"$TAIL" "$CAPTURES_DIR/$puuid.txt" 2>/dev/null \
               | grep -oE "$UUID_RE" \
               | tail -1)" || sid=""
        [ -n "$sid" ] && source="capture"
      fi

      jsonl_path=""
      jsonl_exists="no"
      if [ -n "$sid" ]; then
        # claude's project-dir encoding: replace both `/` and `.` with `-`.
        encoded="$(printf '%s' "$cwd" | tr '/.' '--')"
        jsonl_path="$PROJECTS_ROOT/$encoded/$sid.jsonl"
        [ -f "$jsonl_path" ] && jsonl_exists="yes"
      fi

      emit "$sess	$win	$pane	$pane_id	$puuid	$cwd	$sid	$jsonl_path	$jsonl_exists	$source"
    done
