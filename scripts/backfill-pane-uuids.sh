#!/usr/bin/env bash
# For each currently-running claude pane that lacks @claude-pane-id, mint a
# pane UUID + window UUID, write a session_start_backfill event linking the
# UUID to one of the cwd's claude transcripts, and rebuild the affected
# windows' meta files.
#
# After this runs (followed by a resurrect save with the new post-save-layout
# hook loaded), the saved sidecar covers all claude panes. On kill-server +
# restore, the pre-restore-pane-processes hook re-applies @claude-pane-id,
# claude-rescue-resume's find-sessions lookup returns a session_id, and
# claude resumes with -r.
#
# Without this step, panes whose saved tmux-resurrect command lacks
# `-r <UUID>` (because claude was launched fresh and never resumed) start
# as new claude sessions on restore, losing their in-memory context.
#
# Distinct-session assignment: when multiple Type-D panes share a cwd, each
# gets a different session_id (Nth-most-recent transcript to Nth pane).
# claude can only resume a given session in one place; assigning the same
# session_id to multiple panes would race and at best fork. Where there are
# fewer transcripts than panes in a cwd, the extras are skipped — backfill
# cannot conjure a session out of nothing.
#
# Usage:
#   scripts/backfill-pane-uuids.sh                 # latest dump
#   scripts/backfill-pane-uuids.sh <dump-dir>      # explicit dump dir
#   scripts/backfill-pane-uuids.sh --dry-run       # preview, no writes

set -eu

LIVE_SOCKET="${CLAUDE_RESCUE_LIVE_SOCKET:-default}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$REPO/lib/common.sh"

# --- args -----------------------------------------------------------------
dry=0
dump=""
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) dry=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    *)
      if [ -z "$dump" ]; then dump="$arg"
      else echo "Unknown arg: $arg" >&2; exit 2
      fi
      ;;
  esac
done

if [ -z "$dump" ]; then
  dump="$(/bin/ls -td "$HOME/claude-rescue-dumps"/dump-* 2>/dev/null | head -1)"
fi
[ -d "$dump" ] || { echo "No dump dir under ~/claude-rescue-dumps/ — run state-dump.sh first" >&2; exit 1; }
plan="$dump/restore-plan.tsv"
[ -f "$plan" ] || { echo "Missing $plan" >&2; exit 1; }

# Socket cross-check (same as recap-missing).
if [ -f "$dump/tmux-socket.txt" ]; then
  dump_sock="$(cat "$dump/tmux-socket.txt")"
  if [ "$dump_sock" != "$LIVE_SOCKET" ]; then
    echo "ERROR: dump targets socket [$dump_sock] but this run targets [$LIVE_SOCKET]." >&2
    echo "  Re-dump or run with CLAUDE_RESCUE_LIVE_SOCKET=$dump_sock." >&2
    exit 2
  fi
fi

echo "Using: $plan"
echo "Targeting tmux socket: $LIVE_SOCKET (override with CLAUDE_RESCUE_LIVE_SOCKET)"
[ "$dry" = 1 ] && echo "(dry-run — no tmux options or event files will be written)"
echo

# --- staging dir for grouping ---------------------------------------------
tmpdir="$(mktemp -d -t claude-rescue-backfill.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

# --- Phase 1: extract Type-D panes ----------------------------------------
# restore-plan.tsv cols (1-indexed):
#   1=session, 2=window_idx, 3=window_name, 4=pane_idx,
#   5=pane_id, 6=cwd,
#   7=latest_session_id, 8=latest_transcript_mtime, 9=claude_pane_uuid
#
# Target = pane has cwd AND has no @claude-pane-id yet. We don't filter on
# col 7 (latest_session_id) because the assignment loop below uses the full
# .jsonl listing in the project dir, not just the "latest" one.
#
# Sentinel-encode internal empties (tab-collapse mitigation, same trick as
# state-dump.sh's synth). Reorder output so cwd is first — we sort by cwd
# next to group panes.
awk -F'\t' 'NR>1 && $5!="" && $6!="" && $9=="" {
  for (i=1;i<=NF;i++) if ($i=="") $i="-"
  print $6"\t"$5"\t"$1"\t"$2"\t"$3"\t"$4
}' "$plan" \
  | LC_ALL=C sort -t$'\t' -k1,1 > "$tmpdir/type-d.tsv"

n_type_d="$(wc -l < "$tmpdir/type-d.tsv" | tr -d ' ')"
echo "Found $n_type_d candidate Type-D claude pane(s) in dump."
if [ "$n_type_d" -eq 0 ]; then
  echo "Nothing to backfill. Done."
  exit 0
fi

# --- Phase 2: walk grouped by cwd, assign distinct .jsonls per pane ------
projects_root="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
data_windows="${CLAUDE_RESCUE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-rescue}/windows"
mkdir -p "$data_windows"

# Counts go via a file because the loop body runs in a subshell (via | pipe).
echo "0 0 0" > "$tmpdir/counts"  # minted skipped errored

prev_cwd=""
group_idx=0
group_size=0
jsonls_file="$tmpdir/group-jsonls.txt"

while IFS=$'\t' read -r cwd pane_id sess win_idx win_name pane_idx; do
  # Decode sentinel-encoded empties.
  [ "$win_name" = "-" ] && win_name=""

  # New cwd: enumerate .jsonl files in this cwd's project dir, sorted by
  # mtime desc, then assign Nth file to Nth pane in this group.
  if [ "$cwd" != "$prev_cwd" ]; then
    encoded="$(printf '%s' "$cwd" | tr '/.' '--')"
    proj="$projects_root/$encoded"
    : > "$jsonls_file"
    if [ -d "$proj" ]; then
      for f in "$proj"/*.jsonl; do
        [ -f "$f" ] || continue
        m="$(stat -f '%m' "$f" 2>/dev/null || echo 0)"
        printf '%s\t%s\n' "$m" "$f" >> "$jsonls_file"
      done
      # Newest first.
      LC_ALL=C sort -rn -k1,1 "$jsonls_file" -o "$jsonls_file"
    fi
    # How many Type-D panes share this cwd? Drives the (unique)/(heuristic)
    # annotation on MINT lines — single-pane cwds get a deterministic
    # newest-transcript→pane mapping; multi-pane cwds get an arbitrary
    # Nth-to-Nth mapping that the operator may need to disambiguate later.
    group_size="$(awk -F'\t' -v c="$cwd" '$1==c' "$tmpdir/type-d.tsv" | wc -l | tr -d ' ')"
    prev_cwd="$cwd"
    group_idx=0
  fi

  # Live re-check: dump is minutes/hours old.
  live_cmd="$(tmux -L "$LIVE_SOCKET" display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || echo '')"
  if [ "$live_cmd" != "claude" ]; then
    printf 'SKIP %s (%s:w%s.p%s) cwd=%s — live cmd is %s, not claude\n' \
      "$pane_id" "$sess" "$win_idx" "$pane_idx" "$cwd" "${live_cmd:-<gone>}"
    awk '{print $1" "($2+1)" "$3}' "$tmpdir/counts" > "$tmpdir/counts.new" && mv "$tmpdir/counts.new" "$tmpdir/counts"
    group_idx=$((group_idx + 1))
    continue
  fi

  # Belt-and-suspenders: pane may have had @claude-pane-id minted between
  # dump and now (e.g. someone /clear'd in it).
  existing_puuid="$(tmux -L "$LIVE_SOCKET" show-options -pv -t "$pane_id" @claude-pane-id 2>/dev/null || true)"
  if [ -n "$existing_puuid" ]; then
    printf 'SKIP %s (%s:w%s.p%s) — already has @claude-pane-id=%s\n' \
      "$pane_id" "$sess" "$win_idx" "$pane_idx" "$existing_puuid"
    awk '{print $1" "($2+1)" "$3}' "$tmpdir/counts" > "$tmpdir/counts.new" && mv "$tmpdir/counts.new" "$tmpdir/counts"
    group_idx=$((group_idx + 1))
    continue
  fi

  # Pick the Nth-most-recent .jsonl for this pane (N = group_idx).
  jsonl_line="$(sed -n "$((group_idx + 1))p" "$jsonls_file" 2>/dev/null || true)"
  if [ -z "$jsonl_line" ]; then
    printf 'SKIP %s (%s:w%s.p%s) cwd=%s — no spare transcript (group_idx=%d, %d available)\n' \
      "$pane_id" "$sess" "$win_idx" "$pane_idx" "$cwd" "$group_idx" "$(wc -l < "$jsonls_file" | tr -d ' ')"
    awk '{print $1" "($2+1)" "$3}' "$tmpdir/counts" > "$tmpdir/counts.new" && mv "$tmpdir/counts.new" "$tmpdir/counts"
    group_idx=$((group_idx + 1))
    continue
  fi
  jsonl_path="$(printf '%s' "$jsonl_line" | awk -F'\t' '{print $2}')"
  sid="$(basename "$jsonl_path" .jsonl)"

  # Mint pane UUID. Reuse existing window UUID if set; mint one if not.
  pane_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  win_uuid="$(tmux -L "$LIVE_SOCKET" show-options -wv -t "$pane_id" @claude-window-id 2>/dev/null || true)"
  win_uuid_was_minted=0
  if [ -z "$win_uuid" ]; then
    win_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    win_uuid_was_minted=1
  fi

  if [ "$group_size" -eq 1 ]; then
    confidence="(unique)"
  else
    confidence="(heuristic $((group_idx + 1))/$group_size)"
  fi
  printf 'MINT %s (%s:w%s.p%s) cwd=%s pane_uuid=%s window_uuid=%s%s sid=%s %s\n' \
    "$pane_id" "$sess" "$win_idx" "$pane_idx" "$cwd" "$pane_uuid" "$win_uuid" \
    "$([ $win_uuid_was_minted -eq 1 ] && echo ' (new)' || echo ' (existing)')" "$sid" "$confidence"

  if [ "$dry" -eq 1 ]; then
    awk '{print ($1+1)" "$2" "$3}' "$tmpdir/counts" > "$tmpdir/counts.new" && mv "$tmpdir/counts.new" "$tmpdir/counts"
    group_idx=$((group_idx + 1))
    continue
  fi

  # --- Apply: tmux options ------------------------------------------------
  if ! tmux -L "$LIVE_SOCKET" set-option -pt "$pane_id" @claude-pane-id "$pane_uuid" 2>/dev/null; then
    printf 'ERR  %s — tmux set-option @claude-pane-id failed\n' "$pane_id"
    awk '{print $1" "$2" "($3+1)}' "$tmpdir/counts" > "$tmpdir/counts.new" && mv "$tmpdir/counts.new" "$tmpdir/counts"
    group_idx=$((group_idx + 1))
    continue
  fi
  if [ "$win_uuid_was_minted" -eq 1 ]; then
    tmux -L "$LIVE_SOCKET" set-option -wt "$pane_id" @claude-window-id "$win_uuid" 2>/dev/null || true
  fi

  # --- Apply: write event into the window's jsonl -------------------------
  # Mirrors the schema that session_start (live) writes, with kind suffixed
  # _backfill so meta rollup recognizes it via startswith() and the source
  # field documents the provenance.
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc \
    --arg ts "$ts" \
    --arg sid "$sid" \
    --arg puuid "$pane_uuid" \
    --arg wuuid "$win_uuid" \
    --arg sname "$sess" \
    --arg wname "$win_name" \
    --arg cwd "$cwd" \
    --arg tp "$jsonl_path" \
    '{ts:$ts, kind:"session_start_backfill", session_id:$sid,
      pane_uuid:$puuid, session_name:$sname, window_name:$wname,
      cwd:$cwd, source:"prod-rollout-backfill", transcript_path:$tp}' \
    >> "$data_windows/$win_uuid.jsonl"

  # --- Apply: rebuild meta.json so find-sessions sees the new session ----
  rebuild_meta "$win_uuid"

  awk '{print ($1+1)" "$2" "$3}' "$tmpdir/counts" > "$tmpdir/counts.new" && mv "$tmpdir/counts.new" "$tmpdir/counts"
  group_idx=$((group_idx + 1))
done < "$tmpdir/type-d.tsv"

echo
read -r minted skipped errored < "$tmpdir/counts"
echo "Summary: minted=$minted  skipped=$skipped  errored=$errored  (total candidates=$n_type_d)"
echo

if [ "$dry" -eq 1 ]; then
  echo "(dry-run — nothing written)"
  exit 0
fi

# --- Smoke test: per-pane round-trip via find-sessions --------------------
echo "Verifying backfilled UUIDs round-trip through find-sessions..."
fail=0
# Re-walk the input one more time, checking each (now-minted) pane.
while IFS=$'\t' read -r cwd pane_id sess win_idx win_name pane_idx; do
  puuid="$(tmux -L "$LIVE_SOCKET" show-options -pv -t "$pane_id" @claude-pane-id 2>/dev/null || true)"
  [ -z "$puuid" ] && continue  # was skipped
  resolved="$("$REPO/bin/claude-rescue" find-sessions --pane-uuid "$puuid" 2>/dev/null \
              | head -1 \
              | awk -v FS=$'\x1f' '{print $1}')"
  if [ -z "$resolved" ]; then
    printf '  FAIL %s pane_uuid=%s — find-sessions returned nothing\n' "$pane_id" "$puuid"
    fail=$((fail + 1))
  else
    printf '  OK   %s pane_uuid=%s → session_id=%s\n' "$pane_id" "$puuid" "$resolved"
  fi
done < "$tmpdir/type-d.tsv"

if [ "$fail" -gt 0 ]; then
  echo
  echo "WARNING: $fail backfilled pane(s) failed the round-trip check." >&2
  echo "Inspect ~/.local/share/claude-rescue/windows/*.meta.json or re-run find-sessions manually." >&2
  exit 1
fi

echo
echo "All backfilled panes resolve via find-sessions."
echo "Next: ensure live tmux has the new post-save-layout hook loaded"
echo "      (\`tmux -L $LIVE_SOCKET source-file ~/.tmux.conf\`), then run the"
echo "      step-5a force save."
