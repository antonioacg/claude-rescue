#!/usr/bin/env bash
# staging-fixture.sh — populate the staging server with a multi-window
# fixture suitable for hibernation + crash-restore validation.
#
# Layout produced:
#   main:1
#     1.1 — claude in ~/claude-rescue-staging
#     1.2 — claude in ~/claude-rescue-staging/projectA  (vertical split below 1.1)
#   main:2.1 — claude in ~/claude-rescue-staging/projectB
#   main:3.1 — nvim on /tmp/claude-rescue-staging-scratch.md
#
# Every claude pane is fed "hi" so a transcript file is written to
# ~/.claude/projects/<encoded-cwd>/. find-sessions filters out transcript-less
# sessions, so without this the resurrect wrapper would resume an older
# session (or none).
#
# Prereqs: scripts/staging.sh setup has run (server up, settings.json in
# place, binaries symlinked). The fixture script does NOT call setup itself
# — keep concerns separated.
#
# Usage:
#   scripts/staging.sh setup
#   scripts/staging-fixture.sh
#
# Exit: 0 on success; non-zero with a clear message if any pane fails to
# come up in the timeout windows.

set -uo pipefail

SOCK="claude-rescue-staging"
STAGING_DIR="${CLAUDE_RESCUE_STAGING_DIR:-$HOME/claude-rescue-staging}"
SCRATCH="/tmp/claude-rescue-staging-scratch.md"

CLAUDE_READY_TIMEOUT="${CLAUDE_READY_TIMEOUT:-30}"   # seconds to wait for cmd=claude
TRANSCRIPT_TIMEOUT="${TRANSCRIPT_TIMEOUT:-30}"       # seconds for transcript to appear

# ---------------------------------------------------------------------------

die() { echo "staging-fixture: $*" >&2; exit 1; }

require_server() {
  tmux -L "$SOCK" has-session 2>/dev/null \
    || die "staging server not running. Run: scripts/staging.sh setup"
}

# Wait for the foreground process in a pane to become $1 ("claude" usually),
# up to CLAUDE_READY_TIMEOUT seconds.
wait_for_cmd() {
  local pane_id="$1" target_cmd="$2" i cmd
  for i in $(seq 1 "$CLAUDE_READY_TIMEOUT"); do
    cmd="$(tmux -L "$SOCK" display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null)"
    [ "$cmd" = "$target_cmd" ] && return 0
    sleep 1
  done
  return 1
}

# True (0) if a fresh transcript exists under ~/.claude/projects/<encoded>/.
# Encoded cwd = $cwd with BOTH `/` and `.` mapped to `-` (so `.local` and
# `/local` both become `-local`, hence the `--` you see on dotfile paths).
transcript_present() {
  local cwd="$1" enc proj_dir
  enc="${cwd//\//-}"
  enc="${enc//./-}"
  proj_dir="$HOME/.claude/projects/$enc"
  [ -d "$proj_dir" ] \
    && find "$proj_dir" -name '*.jsonl' -mmin -5 -print -quit 2>/dev/null | grep -q .
}

# Poll transcript_present up to $2 seconds (default TRANSCRIPT_TIMEOUT).
wait_for_transcript() {
  local cwd="$1" timeout="${2:-$TRANSCRIPT_TIMEOUT}" i
  for i in $(seq 1 "$timeout"); do
    transcript_present "$cwd" && return 0
    sleep 1
  done
  return 1
}

# Start claude in a pane and wait until claude is foreground AND a transcript
# has been written. Sending "hi" produces the transcript via the first user
# message.
boot_claude_in_pane() {
  local pane_id="$1" cwd="$2" elapsed
  echo "  → cl in $pane_id (cwd=$cwd)"
  tmux -L "$SOCK" send-keys -t "$pane_id" "cl" Enter
  wait_for_cmd "$pane_id" claude \
    || die "claude failed to start in $pane_id within ${CLAUDE_READY_TIMEOUT}s"

  # pane_current_command flips to `claude` the instant the process execs, but
  # its TUI only starts accepting keystrokes a couple seconds later — "hi" sent
  # too early is silently dropped, so no user message and no transcript (the
  # bug that made this fixture flaky, worse with Fable's slower splash render).
  # Give it a settle beat, then send "hi" and RESEND on a short cadence until
  # the transcript proves the message landed. C-u first clears any partial line
  # a dropped-tail attempt may have left. Total wait bounded by TRANSCRIPT_TIMEOUT.
  sleep "${CLAUDE_INPUT_SETTLE:-3}"
  for (( elapsed = 0; elapsed < TRANSCRIPT_TIMEOUT; elapsed += 5 )); do
    tmux -L "$SOCK" send-keys -t "$pane_id" C-u "hi" Enter
    wait_for_transcript "$cwd" 5 && return 0
  done
  die "no transcript appeared for cwd=$cwd within ${TRANSCRIPT_TIMEOUT}s"
}

# ---------------------------------------------------------------------------

require_server

# Refuse to run against a non-empty layout — fixtures must start from a
# fresh `staging.sh setup` so windows/panes have predictable indices.
existing_windows="$(tmux -L "$SOCK" list-windows -t main -F '#{window_index}' | wc -l | tr -d ' ')"
existing_panes="$(tmux -L "$SOCK" list-panes -t main:1 -F '#{pane_id}' | wc -l | tr -d ' ')"
if [ "$existing_windows" != "1" ] || [ "$existing_panes" != "1" ]; then
  die "staging server is not in a fresh state ($existing_windows windows, $existing_panes panes in main:1). Tear down + setup again before running this."
fi

mkdir -p "$STAGING_DIR/projectA" "$STAGING_DIR/projectB"
echo "# Staging scratch" > "$SCRATCH"

# --- main:1 — two-pane window ---------------------------------------------
echo "main:1.1 — claude in $STAGING_DIR"
boot_claude_in_pane main:1.1 "$STAGING_DIR"

echo "main:1.2 — split-window -v in $STAGING_DIR/projectA"
tmux -L "$SOCK" split-window -t main:1.1 -v -c "$STAGING_DIR/projectA"
PANE_1_2="$(tmux -L "$SOCK" list-panes -t main:1 -F '#{pane_id}' | tail -1)"
boot_claude_in_pane "$PANE_1_2" "$STAGING_DIR/projectA"

# --- main:2 — single-pane window ------------------------------------------
echo "main:2.1 — new-window in $STAGING_DIR/projectB"
tmux -L "$SOCK" new-window -t main -c "$STAGING_DIR/projectB"
boot_claude_in_pane main:2.1 "$STAGING_DIR/projectB"

# --- main:3 — nvim --------------------------------------------------------
echo "main:3.1 — new-window with nvim on $SCRATCH"
tmux -L "$SOCK" new-window -t main -c /tmp
tmux -L "$SOCK" send-keys -t main:3.1 "nvim $SCRATCH" Enter
wait_for_cmd main:3.1 nvim \
  || die "nvim failed to start in main:3.1 within ${CLAUDE_READY_TIMEOUT}s"

# --- Done -----------------------------------------------------------------
echo ""
echo "Fixture ready:"
tmux -L "$SOCK" list-panes -aF \
  '  #{pane_id} #{session_name}:#{window_index}.#{pane_index} cmd=#{pane_current_command} cwd=#{pane_current_path} pane_uuid=#{@claude-pane-id}'
echo ""
echo "Attach with: tmux -L $SOCK attach"
