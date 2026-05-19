#!/usr/bin/env bash
# verify-pane-sessions.sh — audit every pane with @claude-pane-id and confirm
# its session_id mapping resolves to a transcript jsonl on disk.
#
# Pre-restart sanity check: before a Mac reboot / kill-server you want to
# know that EVERY pane carrying a claude identity (live or hibernated) has
# enough state for the wrapper to resume the exact original session, not
# fall through to find-sessions's most-recent heuristic.
#
# Lookup chain per pane (matches bin/claude-rescue-resume's resolver):
#   1. active/<pane_uuid>            — written by SessionStart hooks; survives
#                                       kill-server; cleared by SessionEnd
#                                       (unless a hibernation marker exists)
#   2. captures/<pane_uuid>.json     — written by cmd_hibernate_arm at the
#                                       SIGTSTP capture point; carries the
#                                       session_id resolved at hibernation
#   3. (no fallback to find-sessions here — verify is read-only; if neither
#       active/ nor captures/ has a sid, the pane has no deterministic
#       resume target and we mark it MISSING.)
#
# Each resolved sid is checked against PROJECTS_ROOT/<encoded-cwd>/<sid>.jsonl
# using the same cwd encoding Claude Code does (see encode_cwd_for_projects
# in lib/common.sh).
#
# Usage:
#   scripts/verify-pane-sessions.sh                       # print TSV report
#   scripts/verify-pane-sessions.sh --quiet               # exit code only
#   scripts/verify-pane-sessions.sh --socket <name>       # alt tmux socket
#
# Exit codes: 0 = all panes pass, 1 = at least one MISSING, 2 = arg error.

set -eu

__script="$0"
while [ -L "$__script" ]; do
  __link="$(readlink "$__script")"
  case "$__link" in
    /*) __script="$__link" ;;
    *)  __script="$(cd "$(dirname "$__script")" && pwd)/$__link" ;;
  esac
done
REPO="$(cd "$(dirname "$__script")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$REPO/lib/common.sh"

LIVE_SOCKET="${CLAUDE_RESCUE_LIVE_SOCKET:-default}"
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|-q)   QUIET=1; shift ;;
    --socket)     LIVE_SOCKET="$2"; shift 2 ;;
    --socket=*)   LIVE_SOCKET="${1#--socket=}"; shift ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *)            echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

PROJECTS_ROOT="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
ACTIVE_DIR="$CLAUDE_RESCUE_DATA_HOME/active"
CAPTURES_DIR="$CLAUDE_RESCUE_DATA_HOME/captures"

emit() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"; }

emit $'pane_id\tcmd\tpane_uuid\tcwd\tsid_source\tsid\tjsonl_status'

total=0
missing=0

# Use Unit Separator (\x1f) instead of \t between tmux fields. With IFS=\t,
# bash's read collapses runs of whitespace-IFS, dropping the empty
# @claude-pane-id field — every shell-only pane then misparses with the
# next column shifted in. \x1f is non-whitespace, so read preserves empties.
US=$'\x1f'
while IFS="$US" read -r pane_id cmd puuid cwd; do
  [ -z "$puuid" ] && continue
  total=$((total + 1))

  sid=""
  source=""
  # Resolve the session's true cwd: captures/<uuid>.json has the cwd recorded
  # at hibernation time. Pane's current cwd can drift (user cd'd, or
  # tmux-resurrect's restore fell back to $HOME if the saved dir was missing).
  # Falling back on pane_current_path produces false MISSINGs when the
  # session's jsonl exists in a different project dir than where the pane
  # currently sits — the wrapper resolves correctly because it cds before
  # exec, but our audit needs the same view.
  session_cwd="$cwd"
  if [ -f "$CAPTURES_DIR/$puuid.json" ]; then
    cap_cwd="$(jq -r '.cwd // empty' "$CAPTURES_DIR/$puuid.json" 2>/dev/null)"
    [ -n "$cap_cwd" ] && session_cwd="$cap_cwd"
  fi

  if [ -f "$ACTIVE_DIR/$puuid" ]; then
    sid="$(head -1 "$ACTIVE_DIR/$puuid" 2>/dev/null | tr -d '\n')"
    [ -n "$sid" ] && source="active"
  fi

  if [ -z "$sid" ] && [ -f "$CAPTURES_DIR/$puuid.json" ]; then
    cap_sid="$(jq -r '.session_id // empty' "$CAPTURES_DIR/$puuid.json" 2>/dev/null)"
    if [ -z "$cap_sid" ] && [ -f "$CAPTURES_DIR/$puuid.txt" ]; then
      # Capture json missing sid but the txt was saved — recover via the
      # shared scraper (this is exactly the %10 scenario from 2026-05-19).
      cap_sid="$(scrape_session_id_from_capture "$CAPTURES_DIR/$puuid.txt")"
    fi
    if [ -n "$cap_sid" ]; then
      sid="$cap_sid"
      source="capture"
    fi
  fi

  if [ -z "$sid" ]; then
    emit "$pane_id"$'\t'"$cmd"$'\t'"$puuid"$'\t'"$cwd"$'\t'NONE$'\t'$'\t'MISSING
    missing=$((missing + 1))
    continue
  fi

  encoded="$(encode_cwd_for_projects "$session_cwd")"
  jpath="$PROJECTS_ROOT/$encoded/$sid.jsonl"
  if [ -f "$jpath" ]; then
    emit "$pane_id"$'\t'"$cmd"$'\t'"$puuid"$'\t'"$session_cwd"$'\t'"$source"$'\t'"$sid"$'\t'OK
  else
    # jsonl missing at the cwd-derived path. Could be:
    #  - session_cwd is stale and the jsonl moved (search by sid as a hint)
    #  - jsonl genuinely gone (compaction, manual delete)
    alt="$(find "$PROJECTS_ROOT" -maxdepth 2 -name "$sid.jsonl" -type f 2>/dev/null | head -1)"
    if [ -n "$alt" ]; then
      emit "$pane_id"$'\t'"$cmd"$'\t'"$puuid"$'\t'"$session_cwd"$'\t'"$source"$'\t'"$sid"$'\t'"OK_ALT ($alt)"
    else
      emit "$pane_id"$'\t'"$cmd"$'\t'"$puuid"$'\t'"$session_cwd"$'\t'"$source"$'\t'"$sid"$'\t'"NO_JSONL ($jpath)"
      missing=$((missing + 1))
    fi
  fi
done < <(
  tmux -L "$LIVE_SOCKET" list-panes -aF \
    "#{pane_id}${US}#{pane_current_command}${US}#{@claude-pane-id}${US}#{pane_current_path}" \
    2>/dev/null
)

emit ""
emit "total_panes_with_uuid=$total missing=$missing"

[ "$missing" -eq 0 ] || exit 1
