#!/usr/bin/env bash
# cleanup-resurrect-snapshots.sh — prune accumulated tmux-resurrect snapshots.
#
# tmux-resurrect has built-in rotation via @resurrect-delete-backup-after
# (default 30 days, keep 5 most recent). The implementation in
# tmux-resurrect/scripts/save.sh uses a shell glob:
#
#   files=($(ls -t <dir>/tmux_resurrect_*.txt | tail -n +6))
#
# which hits "argument list too long" once the dir has more than ~6000
# files. The cleanup silently fails (errors → /dev/null), the dir keeps
# growing, and future cleanup runs fail too — the rotation is stuck
# until the dir is manually trimmed.
#
# This script does the same job using find + sort + sed, safe at any
# scale. Defaults to keeping the newest 200 (about 3 hours' worth at
# @continuum-save-interval=1).
#
# Each kept .txt also keeps its paired .claude-userops.tsv (the
# claude-rescue UUID sidecar). pane_contents.tar.gz is shared across
# snapshots and is left untouched. The current `last` symlink target
# is preserved unconditionally even if it would fall outside --keep.
#
# Usage:
#   scripts/cleanup-resurrect-snapshots.sh                  # keep newest 200
#   scripts/cleanup-resurrect-snapshots.sh --keep 500       # custom retention
#   scripts/cleanup-resurrect-snapshots.sh --dry-run        # preview
#   scripts/cleanup-resurrect-snapshots.sh --dir <path>     # alternate dir

set -euo pipefail

RESURRECT_DIR="${RESURRECT_DIR:-$HOME/.local/share/tmux/resurrect/default}"
KEEP=200
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)      KEEP="$2"; shift 2 ;;
    --keep=*)    KEEP="${1#--keep=}"; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --dir)       RESURRECT_DIR="$2"; shift 2 ;;
    --dir=*)     RESURRECT_DIR="${1#--dir=}"; shift ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -d "$RESURRECT_DIR" ] || { echo "No such dir: $RESURRECT_DIR" >&2; exit 1; }
[[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "--keep must be a non-negative integer" >&2; exit 2; }

# Snapshot pointed at by `last` — preserved unconditionally.
LAST_TARGET=""
if [ -L "$RESURRECT_DIR/last" ]; then
  LAST_TARGET="$(readlink "$RESURRECT_DIR/last")"
fi

# Newest-first list of all snapshot .txt files. find + stat avoids any
# shell glob expansion (which would blow up at scale).
TMPLIST="$(mktemp -t cleanup-resurrect-snapshots.XXXXXX)"
trap 'rm -f "$TMPLIST"' EXIT

find "$RESURRECT_DIR" -maxdepth 1 -name 'tmux_resurrect_*.txt' -type f \
  -exec stat -f '%m %N' {} \; \
  | sort -rn \
  | awk '{$1=""; sub(/^ /,""); print}' \
  > "$TMPLIST"

TOTAL=$(wc -l < "$TMPLIST" | tr -d ' ')

echo "Snapshot dir: $RESURRECT_DIR"
echo "Total snapshots: $TOTAL"
echo "Keep: $KEEP newest"
[ -n "$LAST_TARGET" ] && echo "Preserved: \`last\` → $LAST_TARGET"

if [ "$TOTAL" -le "$KEEP" ]; then
  echo "Nothing to delete."
  exit 0
fi

# Candidates = entries beyond the top $KEEP.
# Excluding the `last` target if it happens to fall outside the top N.
DEL_LIST="$(mktemp -t cleanup-resurrect-snapshots-del.XXXXXX)"
trap 'rm -f "$TMPLIST" "$DEL_LIST"' EXIT
if [ -n "$LAST_TARGET" ]; then
  tail -n +$((KEEP + 1)) "$TMPLIST" | grep -vF "/$LAST_TARGET" > "$DEL_LIST" || true
else
  tail -n +$((KEEP + 1)) "$TMPLIST" > "$DEL_LIST"
fi

DEL_COUNT=$(wc -l < "$DEL_LIST" | tr -d ' ')
echo "Will delete: $DEL_COUNT .txt + paired .claude-userops.tsv (where present)"

if [ "$DRY_RUN" = 1 ]; then
  echo "(dry-run — no files removed)"
  echo "First 5 candidates:"
  head -5 "$DEL_LIST"
  exit 0
fi

# Delete. Use a while-read loop (handles arbitrary-length lists; no argv limits).
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  rm -- "$f"
  sidecar="${f%.txt}.claude-userops.tsv"
  [ -f "$sidecar" ] && rm -- "$sidecar"
done < "$DEL_LIST"

REMAINING=$(find "$RESURRECT_DIR" -maxdepth 1 -name 'tmux_resurrect_*.txt' -type f | wc -l | tr -d ' ')
echo "Done. Snapshots remaining: $REMAINING"
