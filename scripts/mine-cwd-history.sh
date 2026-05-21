#!/usr/bin/env bash
# mine-cwd-history.sh — reconstruct a pane's cwd timeline from retained
# tmux-resurrect snapshots.
#
# Each `.claude-userops.tsv` sidecar pairs (pane_uuid) with the tmux-side
# (session, window_idx, pane_idx). The paired `.txt` carries the cwd in
# the pane row. Walking both in chronological order yields the cwd this
# pane held at every save (1-min cadence by default).
#
# Two query modes:
#   --uuid <pane_uuid>            — durable identity; recommended.
#   --target <session>:<w>.<p>    — tmux indices; brittle if windows shift
#                                    (e.g. user kills window 1, :2→:1).
#
# Output (TSV): from_ts, to_ts, cwd, sample_snapshot
#   Rows collapse consecutive saves with the same cwd into one range.
#   `sample_snapshot` is the basename of one representative snapshot.
#
# Use cases:
#   - Pinpoint when a pane's cwd drifted from <worktree> to <home>.
#   - Verify whether resurrect-restore landed the pane in the right cwd
#     vs whether a later cd moved it.
#
# Usage:
#   scripts/mine-cwd-history.sh --uuid 64c28c8c-537f-43a1-a621-5ec39da4ac18
#   scripts/mine-cwd-history.sh --target platform-mcpg-ucs:2.1
#   scripts/mine-cwd-history.sh --uuid <u> --dir <alt-resurrect-dir>
#   scripts/mine-cwd-history.sh --uuid <u> --since 20260518T000000

set -eu

RESURRECT_DIR="${RESURRECT_DIR:-$HOME/.local/share/tmux/resurrect/default}"
QUERY_UUID=""
QUERY_TARGET=""
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --uuid)      QUERY_UUID="$2"; shift 2 ;;
    --uuid=*)    QUERY_UUID="${1#--uuid=}"; shift ;;
    --target)    QUERY_TARGET="$2"; shift 2 ;;
    --target=*)  QUERY_TARGET="${1#--target=}"; shift ;;
    --dir)       RESURRECT_DIR="$2"; shift 2 ;;
    --dir=*)     RESURRECT_DIR="${1#--dir=}"; shift ;;
    --since)     SINCE="$2"; shift 2 ;;
    --since=*)   SINCE="${1#--since=}"; shift ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *)           echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$QUERY_UUID" ] && [ -z "$QUERY_TARGET" ]; then
  echo "error: --uuid or --target required" >&2
  exit 2
fi
[ -d "$RESURRECT_DIR" ] || { echo "no such dir: $RESURRECT_DIR" >&2; exit 1; }

# Parse --target into session, window, pane.
T_SESSION=""; T_WINDOW=""; T_PANE=""
if [ -n "$QUERY_TARGET" ]; then
  # Format: session:window.pane
  T_SESSION="${QUERY_TARGET%%:*}"
  rest="${QUERY_TARGET#*:}"
  T_WINDOW="${rest%%.*}"
  T_PANE="${rest#*.}"
fi

# List snapshots in chronological order. Use find rather than glob to avoid
# argument-list-too-long when the dir has many thousands of files.
ALL_TXTS="$(mktemp -t cwd-history.XXXXXX)"
trap 'rm -f "$ALL_TXTS" "$ALL_TXTS.range"' EXIT

find "$RESURRECT_DIR" -maxdepth 1 -name 'tmux_resurrect_*.txt' -type f \
  | sort \
  > "$ALL_TXTS"

if [ -n "$SINCE" ]; then
  awk -v since="tmux_resurrect_${SINCE}.txt" \
      '{ n=split($0,a,"/"); if (a[n] >= since) print }' "$ALL_TXTS" \
      > "$ALL_TXTS.range"
  mv "$ALL_TXTS.range" "$ALL_TXTS"
fi

TOTAL=$(wc -l < "$ALL_TXTS" | tr -d ' ')
echo "# snapshots scanned: $TOTAL" >&2
[ -n "$QUERY_UUID" ]   && echo "# query uuid: $QUERY_UUID" >&2
[ -n "$QUERY_TARGET" ] && echo "# query target: $QUERY_TARGET (session=$T_SESSION win=$T_WINDOW pane=$T_PANE)" >&2

printf 'from_ts\tto_ts\tcwd\tsample_snapshot\n'

prev_cwd=""
range_start_ts=""
range_sample=""
range_end_ts=""

emit_range() {
  if [ -n "$prev_cwd" ] && [ -n "$range_start_ts" ]; then
    printf '%s\t%s\t%s\t%s\n' "$range_start_ts" "$range_end_ts" "$prev_cwd" "$range_sample"
  fi
}

while IFS= read -r txt; do
  base="$(basename "$txt")"
  # ts portion: tmux_resurrect_<YYYYMMDDTHHMMSS>.txt → <YYYYMMDDTHHMMSS>
  ts="${base#tmux_resurrect_}"
  ts="${ts%.txt}"

  # Resolve target indices for this snapshot. If --uuid, look it up in the
  # paired sidecar; sidecars are per-snapshot so the mapping is stable.
  session=""; window_idx=""; pane_idx=""
  if [ -n "$QUERY_UUID" ]; then
    sidecar="${txt%.txt}.claude-userops.tsv"
    [ -f "$sidecar" ] || continue
    row="$(awk -F'\t' -v u="$QUERY_UUID" '$1=="pane" && $5==u {print; exit}' "$sidecar")"
    [ -z "$row" ] && continue
    session="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
    window_idx="$(printf '%s' "$row" | awk -F'\t' '{print $3}')"
    pane_idx="$(printf '%s' "$row" | awk -F'\t' '{print $4}')"
  else
    session="$T_SESSION"
    window_idx="$T_WINDOW"
    pane_idx="$T_PANE"
  fi

  # Extract cwd from the .txt's pane row. The pane line has 11 cols, BUT
  # the cwd's index shifts (col 7 vs col 8) depending on whether the pane
  # has a non-empty pane_title — tmux-resurrect omits the empty title
  # column rather than emitting an empty field. Detect cwd by its `:/`
  # prefix (only cwd has that — window_flags is `:##`/`:*`/etc., and the
  # trailing full_command starts with `:` followed by a command name, not
  # a slash). Strip the `:` prefix on emit.
  cwd="$(awk -F'\t' -v s="$session" -v w="$window_idx" -v p="$pane_idx" \
    '$1=="pane" && $2==s && $3==w && $6==p {
       for (i = 1; i <= NF; i++) {
         if (substr($i,1,2) == ":/" || substr($i,1,2) == ":~") {
           c = $i; sub(/^:/,"",c); print c; exit
         }
       }
     }' "$txt")"
  [ -z "$cwd" ] && continue

  if [ "$cwd" = "$prev_cwd" ]; then
    range_end_ts="$ts"
  else
    emit_range
    prev_cwd="$cwd"
    range_start_ts="$ts"
    range_end_ts="$ts"
    range_sample="$base"
  fi
done < "$ALL_TXTS"

emit_range
