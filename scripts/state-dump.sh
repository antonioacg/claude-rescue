#!/usr/bin/env bash
# Capture a reproducibility-grade snapshot of the live system so the working
# set can be rebuilt by hand if tmux-resurrect / continuum fail to bring it
# back after a config reload or server restart. The dump is independent of
# resurrect — it records the resurrect pointer for reference, but the
# restore plan it produces (one line per claude pane: session_name,
# window/pane indexes, cwd, latest claude session_id) is enough to recreate
# the working set with `tmux new-session`, `cd`, `clr <sid>` by hand.
#
# Read-only against the live system; safe to run anytime.
#
# Usage:
#   scripts/state-dump.sh                 # default output dir
#   scripts/state-dump.sh /path/to/dir    # explicit dir
#
# Defaults: $CLAUDE_RESCUE_DUMP_DIR, else ~/claude-rescue-dumps/dump-<ts>.

set -eu
# Deliberately no pipefail: many pipelines below use `cmd | head -N`, and
# under pipefail a closed-pipe SIGPIPE on the producer aborts the whole
# script. State-dump is best-effort — partial data is fine, abort is not.

ts="$(date +%Y%m%dT%H%M%S)"
out="${1:-${CLAUDE_RESCUE_DUMP_DIR:-$HOME/claude-rescue-dumps/dump-$ts}}"
mkdir -p "$out"

DATA="${CLAUDE_RESCUE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-rescue}"
CACHE="${CLAUDE_RESCUE_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-rescue}"
HOME_DIR="${CLAUDE_RESCUE_HOME:-$HOME/.claude-rescue}"

echo "Dumping to: $out"

# --- repo SHAs / deploy provenance ----------------------------------------
{
  echo "# Repo state at dump time"
  echo
  for repo in "$HOME/dev/claude-rescue" "$HOME/.local/share/chezmoi"; do
    if [ -d "$repo/.git" ]; then
      echo "## $repo"
      (
        cd "$repo"
        echo "branch:  $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        echo "head:    $(git rev-parse HEAD 2>/dev/null || echo '?')"
        echo "dirty:   $([ -z "$(git status --porcelain 2>/dev/null)" ] && echo no || echo YES)"
        echo "subject: $(git log -1 --pretty=%s 2>/dev/null || echo '?')"
      )
      echo
    fi
  done
  echo "## ~/.local/bin/claude-rescue* symlink targets"
  for f in "$HOME"/.local/bin/claude-rescue*; do
    [ -e "$f" ] || continue
    printf '%s -> %s\n' "$(basename "$f")" "$(readlink "$f" 2>/dev/null || echo '(not a symlink)')"
  done
} > "$out/repos.md"

# --- tmux server overview --------------------------------------------------
if tmux info >/dev/null 2>&1; then
  tmux -V > "$out/tmux-version.txt"
  tmux list-sessions -F \
    '#{session_id}|#{session_name}|#{session_created}|#{session_attached}|#{session_windows}' \
    > "$out/tmux-sessions.tsv" 2>/dev/null || true

  # Pane inventory — the load-bearing artifact. Columns chosen so you can
  # eyeball "where was claude session X running" from the file alone.
  tmux list-panes -aF \
    '#{pane_id}	#{session_name}	#{window_index}	#{window_name}	#{pane_index}	#{pane_active}	#{pane_current_command}	#{pane_pid}	#{@claude-pane-id}	#{@claude-window-id}	#{pane_current_path}	#{pane_full_command}' \
    > "$out/tmux-panes.tsv" 2>/dev/null || true

  # Windows separately for @claude-window-id (window-scoped option).
  tmux list-windows -aF \
    '#{session_name}|#{window_index}|#{window_id}|#{window_name}|#{@claude-window-id}|#{window_panes}' \
    > "$out/tmux-windows.tsv" 2>/dev/null || true

  tmux show-hooks -g > "$out/tmux-hooks-global.txt" 2>/dev/null || true
  tmux show-options -g > "$out/tmux-options-global.txt" 2>/dev/null || true
else
  echo "tmux server not running" > "$out/tmux-server-missing.txt"
fi

# --- claude transcripts per project ---------------------------------------
# Each ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl is a live claude
# session. Listing them per-cwd lets a human cross-reference: "this pane had
# cwd X, the latest transcript under X is session-id Y → resume Y".
if [ -d "$HOME/.claude/projects" ]; then
  {
    echo "# Latest claude transcript per project (encoded cwd)"
    echo "# (filename = session_id; mtime = last write)"
    echo
    # `find` then group: shells in macOS bash 3.2 lack `mapfile`; use a loop.
    find "$HOME/.claude/projects" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
      | sort \
      | while IFS= read -r dir; do
          latest="$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)"
          [ -n "$latest" ] || continue
          sid="$(basename "$latest" .jsonl)"
          mtime="$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$latest" 2>/dev/null || echo '?')"
          printf '%s\t%s\t%s\n' "$mtime" "$sid" "$(basename "$dir")"
        done
  } > "$out/claude-transcripts.tsv"
fi

# --- claude-rescue runtime state ------------------------------------------
{
  echo "# Runtime state"
  echo
  echo "DATA  = $DATA"
  echo "CACHE = $CACHE"
  echo "HOME  = $HOME_DIR"
  echo
  echo "## In-flight hibernation markers ($CACHE/hibernated/)"
  if [ -d "$CACHE/hibernated" ]; then
    ls -la "$CACHE/hibernated/" 2>/dev/null | tail -n +2
  else
    echo "(dir absent)"
  fi
  echo
  echo "## Busy markers ($CACHE/busy/)"
  if [ -d "$CACHE/busy" ]; then
    ls -la "$CACHE/busy/" 2>/dev/null | tail -n +2
  else
    echo "(dir absent)"
  fi
  echo
  echo "## Captures ($DATA/captures/)"
  if [ -d "$DATA/captures" ]; then
    ls -la "$DATA/captures/" 2>/dev/null | tail -n +2 | head -50
    echo "(showing first 50; total: $(ls "$DATA/captures/" 2>/dev/null | wc -l | tr -d ' '))"
  else
    echo "(dir absent)"
  fi
  echo
  echo "## Window logs ($DATA/windows/, top 20 by mtime)"
  ls -t "$DATA/windows/" 2>/dev/null | head -20
  echo "(total: $(ls "$DATA/windows/" 2>/dev/null | wc -l | tr -d ' '))"
} > "$out/rescue-runtime.md"

# --- manual restore plan --------------------------------------------------
# Synthesize per-claude-pane: where it lived (session/window/pane), where it
# was running (cwd), and which claude session_id to resume (latest transcript
# under that cwd). This is the load-bearing artifact for a hand-rebuild —
# everything else in the dump is supporting evidence.
#
# Join key: pane_current_path → ~/.claude/projects/<encoded>/ directory name.
# Claude encodes the cwd by replacing `/` with `-`, with a leading `-`.
# Example: /Users/foo/dev/bar → -Users-foo-dev-bar
if [ -f "$out/tmux-panes.tsv" ] && [ -d "$HOME/.claude/projects" ]; then
  {
    printf 'session\twindow_idx\twindow_name\tpane_idx\tpane_id\tcwd\tlatest_session_id\tlatest_transcript_mtime\tclaude_pane_uuid\n'
    # Reorder fields so the only possibly-empty one (claude_pane_uuid) is
    # last. `read` with IFS=$'\t' still treats tab as whitespace and collapses
    # consecutive tabs into one, so an internal empty would shift later
    # fields left. Putting `cpid` last sidesteps it.
    awk -F'\t' '$7=="claude" {print $2"\t"$3"\t"$4"\t"$5"\t"$1"\t"$11"\t"$9}' "$out/tmux-panes.tsv" \
      | while IFS=$'\t' read -r sess win_idx win_name pane_idx pane_id cwd cpid; do
          # Claude encodes cwd by replacing both `/` and `.` with `-` (so
          # `.local` and `/local` both become `-local`, hence the `--` you
          # see on dotfile paths).
          encoded="$(printf '%s' "$cwd" | tr '/.' '--')"
          proj="$HOME/.claude/projects/$encoded"
          sid=""
          mtime=""
          # Glob + stat rather than `ls -t | head -1`: ls may be aliased /
          # wrapped (e.g. eza) to emit OSC8 hyperlinks, which break parsing.
          latest=""
          latest_m=0
          for f in "$proj"/*.jsonl; do
            [ -f "$f" ] || continue
            m="$(stat -f '%m' "$f" 2>/dev/null || echo 0)"
            if [ "$m" -gt "$latest_m" ]; then
              latest_m="$m"
              latest="$f"
            fi
          done
          if [ -n "$latest" ]; then
            sid="$(basename "$latest" .jsonl)"
            mtime="$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$latest" 2>/dev/null || echo '')"
          fi
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$sess" "$win_idx" "$win_name" "$pane_idx" "$pane_id" "$cwd" "$sid" "$mtime" "$cpid"
        done
  } > "$out/restore-plan.tsv"
fi

# --- resurrect snapshot pointer -------------------------------------------
{
  echo "# tmux-resurrect snapshot pointer"
  echo
  for d in "$HOME/.local/share/tmux/resurrect"/*; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    target="$(readlink "$d/last" 2>/dev/null || echo '(no last symlink)')"
    echo "[$name]"
    echo "  last → $target"
    if [ -f "$d/last" ]; then
      full="$d/$target"
      [ -f "$full" ] || full="$d/last"
      echo "  size: $(wc -c < "$full" 2>/dev/null | tr -d ' ') bytes"
      echo "  mtime: $(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$full" 2>/dev/null || echo '?')"
    fi
    echo
  done
} > "$out/resurrect.md"

# --- summary --------------------------------------------------------------
{
  echo "# State dump — $ts"
  echo
  echo "Generated by \`scripts/state-dump.sh\` on $(hostname)"
  echo
  echo "## Files"
  echo
  for f in "$out"/*; do
    name="$(basename "$f")"
    [ "$name" = "summary.md" ] && continue
    case "$name" in
      tmux-panes.tsv)
        n="$(wc -l < "$f" | tr -d ' ')"
        echo "- \`$name\` — $n panes (tab-separated: pane_id, session, win_idx, win_name, pane_idx, active, cmd, pid, @claude-pane-id, @claude-window-id, cwd, full_cmd)"
        ;;
      restore-plan.tsv)
        n="$(awk 'NR>1' "$f" | wc -l | tr -d ' ')"
        echo "- \`$name\` — **manual restore plan**: $n claude panes with cwd + resume session_id"
        ;;
      tmux-sessions.tsv)
        n="$(wc -l < "$f" | tr -d ' ')"
        echo "- \`$name\` — $n sessions (pipe-separated: id, name, created, attached, win_count)"
        ;;
      tmux-windows.tsv)
        n="$(wc -l < "$f" | tr -d ' ')"
        echo "- \`$name\` — $n windows (pipe-separated: session, idx, win_id, name, @claude-window-id, pane_count)"
        ;;
      claude-transcripts.tsv)
        n="$(wc -l < "$f" | tr -d ' ')"
        echo "- \`$name\` — $n projects with at least one transcript"
        ;;
      *)
        echo "- \`$name\`"
        ;;
    esac
  done
  echo
  echo "## Quick stats"
  echo
  if [ -f "$out/tmux-panes.tsv" ]; then
    claudes="$(awk -F'\t' '$7=="claude"' "$out/tmux-panes.tsv" | wc -l | tr -d ' ')"
    with_uuid="$(awk -F'\t' '$9!=""' "$out/tmux-panes.tsv" | wc -l | tr -d ' ')"
    echo "- claude panes: $claudes"
    echo "- panes with @claude-pane-id minted: $with_uuid"
  fi
  if [ -d "$CACHE/hibernated" ]; then
    h="$(find "$CACHE/hibernated" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
    a="$(find "$CACHE/hibernated" -maxdepth 1 -name '*.arm.pid' 2>/dev/null | wc -l | tr -d ' ')"
    echo "- hibernated markers: $h"
    echo "- live arm timers: $a"
  fi
  if [ -d "$CACHE/busy" ]; then
    b="$(find "$CACHE/busy" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    echo "- busy markers: $b"
  fi
} > "$out/summary.md"

echo
echo "Done."
echo "  $out/summary.md"
echo
cat "$out/summary.md"
