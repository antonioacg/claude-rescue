#!/usr/bin/env bash
# staging.sh — spin up a real tmux server (separate from your main one)
# wired up exactly like chezmoi-apply would wire your live system, so you
# can attach and try claude-rescue end-to-end before committing.
#
# What it touches in your live system:
#   - Symlinks bin/claude-rescue{,-log,-backfill} into ~/.local/bin/
#     (idempotent; teardown can unlink)
#   - Creates a staging dir (default: ~/claude-rescue-staging) holding its
#     own tmux config, .claude/settings.json (project-level — your global
#     ~/.claude/settings.json is NOT touched), and rescue data dir.
#   - Starts a tmux server on socket "claude-rescue-staging" (separate
#     from your default server).
#
# Usage:
#   scripts/staging.sh setup [--fast]  install + start staging server (default)
#   scripts/staging.sh attach          tmux -L claude-rescue-staging attach
#   scripts/staging.sh status          show what's running and where logs are
#   scripts/staging.sh teardown        kill server, optionally remove staging dir + symlinks
#
# --fast: also sets the hibernation tunables on the staging server's global env
# for fast interactive testing (SOFT_DELAY=15s, HARD_DELAY=60s, DEFER_TIMES=0).
# That gives ~15s focus-out → soft hibernate, ~45s after that → hard escalation
# (claude /exit + clr <sid> pre-fill). Without --fast, staging uses production
# defaults (60min / 24h) — useful when you want to mirror live behavior.
# Interim until #46 (config-file with hot-reload) lands.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAGING_DIR="${CLAUDE_RESCUE_STAGING_DIR:-$HOME/claude-rescue-staging}"
SOCK="claude-rescue-staging"
DATA_DIR="$STAGING_DIR/data"

# Parse flags out of $@, leaving positional args for the case dispatch below.
FAST=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    *)      ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]}"

# ---------------------------------------------------------------------------

cmd_setup() {
  echo "==> 1. Installing binaries into ~/.local/bin/"
  bash "$REPO/scripts/install.sh" --apply
  echo ""

  echo "==> 2. Creating staging env at $STAGING_DIR"
  mkdir -p "$STAGING_DIR/.claude" "$STAGING_DIR/.config/tmux" "$DATA_DIR"

  # Project-level claude settings — only loaded when claude runs in this dir.
  # Your global ~/.claude/settings.json is untouched.
  cat > "$STAGING_DIR/.claude/settings.json" <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "claude-rescue-log session_start >/dev/null 2>>${DATA_DIR}/rescue-log.err",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "claude-rescue-log session_end >/dev/null 2>>${DATA_DIR}/rescue-log.err",
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "claude-rescue-log user_prompt_submit >/dev/null 2>>${DATA_DIR}/rescue-log.err",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "claude-rescue-log pre_tool_use >/dev/null 2>>${DATA_DIR}/rescue-log.err",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "claude-rescue-log post_tool_use >/dev/null 2>>${DATA_DIR}/rescue-log.err",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "claude-rescue-log stop >/dev/null 2>>${DATA_DIR}/rescue-log.err",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
JSON

  # tmux config — load the user's real ~/.tmux.conf for theme + keybindings,
  # then override only what's needed for isolation.
  cat > "$STAGING_DIR/.config/tmux/staging.conf" <<TMUX
# Staging tmux config — loads your real ~/.tmux.conf (theme, plugins,
# keybindings) and then overrides resurrect/continuum for isolation.

# Pre-set @continuum-boot-started so your main config's if-shell sees
# "boot already happened" and skips the auto-restore trigger. Without this,
# main config's restore-wrapper would fire during source-file below and
# pull in your real session state.
set -g @continuum-boot-started 1

# Register claude-rescue hooks BEFORE sourcing ~/.tmux.conf. TPM/continuum
# bootstrap inside the user's config can fire a save (and historically
# auto-restore) the moment plugins initialise; if our @resurrect-hook-*
# options aren't set yet, that pass runs without invoking us — leaving the
# sidecar unwritten and @claude-window-id un-reapplied across restarts.
source-file -q "$REPO/tmux/rescue.tmux.conf"

# Load your real config — theme, status bar position, TPM, plugins, keybindings.
source-file -q "\$HOME/.tmux.conf"

# Now override for staging isolation. These run AFTER ~/.tmux.conf so they win.
# Note: do NOT override @resurrect-dir. The user's main config computes a
# socket-aware XDG path (e.g. ~/.local/share/tmux/resurrect/<socket-name>),
# which is already isolated from the main socket and XDG-clean. Overriding
# here was order-fragile w.r.t. TPM init, sometimes losing to the main path
# anyway and creating two-source ambiguity across server restarts.
set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'off'
set -g @continuum-save-interval '1'

# Wire claude-rescue's deterministic resume wrapper into resurrect's
# @resurrect-processes mapping. On restore, each pane that was running
# claude is restarted via claude-rescue-resume — which queries the pane's
# (sidecar-restored) @claude-pane-id, looks up the latest open session via
# find-sessions, and (when not in dry-run) execs `claude … -r <session_id>`.
# This replaces the legacy scrollback-grep claude-restore.sh path.
#
# In dry-run mode (current default in claude-rescue-resume) the wrapper
# prints what it would exec and drops into a shell, so kill+restore tests
# can validate the lookup chain without actually starting claude.
set -g @resurrect-processes "\"~claude->claude-rescue-resume *\""

# Distinguishable status hint so you can tell staging from your main at a glance.
set -ag status-right ' [staging]'

# Picker keybinding (set after main config so user's prefix is in effect).
bind R run-shell "claude-rescue"
TMUX

  echo "    staging dir ready"
  echo ""

  echo "==> 3. Starting staging tmux server (socket: $SOCK)"
  if tmux -L "$SOCK" has-session 2>/dev/null; then
    echo "    server already running"
  else
    # Strip any TMUX/TMUX_PANE leaking in from the calling shell — otherwise
    # the staging server's global env carries the OUTER tmux's pane id, and
    # run-shell-fired hooks misroute send-keys back to a pane that doesn't
    # exist in staging.
    env -u TMUX -u TMUX_PANE \
      CLAUDE_RESCUE_DATA_HOME="$DATA_DIR" CLAUDE_RESCUE_CACHE_HOME="$DATA_DIR/cache" PATH="$HOME/.local/bin:$PATH" \
      tmux -L "$SOCK" -f "$STAGING_DIR/.config/tmux/staging.conf" \
        new-session -d -s main -c "$STAGING_DIR" -x 200 -y 50
    tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_DATA_HOME "$DATA_DIR"
    tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_CACHE_HOME "$DATA_DIR/cache"
    tmux -L "$SOCK" set-environment -g PATH "$HOME/.local/bin:$PATH"
    tmux -L "$SOCK" set-environment -gu TMUX
    tmux -L "$SOCK" set-environment -gu TMUX_PANE
    echo "    started"
  fi

  # --fast: apply fast hibernation delays AFTER the server is up. set-env -g
  # mutates the server's global env; every `tmux run-shell -b` (which is how
  # the focus hooks invoke hibernate-arm/resume) inherits these values.
  if [ "$FAST" -eq 1 ]; then
    tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_SOFT_DELAY 15
    tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_HARD_DELAY 60
    tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES 0
    echo "    --fast: SOFT_DELAY=15s HARD_DELAY=60s HIBERNATE_DEFER_TIMES=0"
    echo "            (soft fires ~15s after focus-out; hard escalates ~45s later)"
  fi

  echo ""
  echo "=========================================================="
  echo " Staging server is up (bare: one zsh pane in main:1)."
  echo ""
  echo " Populate the 4-pane hibernation/crash-restore fixture:"
  echo "     $REPO/scripts/staging-fixture.sh"
  echo ""
  echo " Then attach:"
  echo "     $REPO/scripts/staging.sh attach"
  echo ""
  echo " Or skip the fixture and drive the bare pane yourself:"
  echo "     claude                # real SessionStart hook fires"
  echo "     /clear                # session_end (reason:clear) + new session_start"
  echo "     exit / Ctrl-D         # SessionEnd hook fires"
  echo "     <prefix> + R          # popup picker (claude-rescue)"
  echo ""
  echo " Watch logs from a normal terminal:"
  echo "     tail -F $DATA_DIR/cache/rescue-log.err   # script-level errors"
  echo "     tail -F $DATA_DIR/cache/hibernate.err    # hibernation timer errors"
  echo "     tail -F $DATA_DIR/cache/restore-keys.err # post-restore-keys errors"
  echo "     ls -l   $DATA_DIR/windows/               # per-window event logs"
  echo "     jq -c . $DATA_DIR/windows/*.jsonl        # stream all events"
  echo ""
  echo " When done:"
  echo "     $REPO/scripts/staging.sh teardown"
  echo "=========================================================="
}

cmd_attach() {
  # Strip $TMUX so we don't nest-attach (which creates a separate session
  # in the staging server). Always target the 'main' session we created.
  if ! tmux -L "$SOCK" has-session -t main 2>/dev/null; then
    echo "main session is gone — run 'setup' to recreate" >&2
    exit 1
  fi
  exec env -u TMUX tmux -L "$SOCK" attach -t main
}

cmd_status() {
  echo "Staging socket: $SOCK"
  if tmux -L "$SOCK" has-session 2>/dev/null; then
    echo "  RUNNING"
    tmux -L "$SOCK" list-sessions 2>/dev/null
    echo ""
    echo "  Windows:"
    tmux -L "$SOCK" list-windows -aF '    #{session_name}:#{window_index} name=#{window_name} uuid=#{@claude-window-id}'
    echo ""
    echo "  CLAUDE_RESCUE_* env on the server (empty → production defaults):"
    tmux -L "$SOCK" show-environment -g 2>/dev/null | grep '^CLAUDE_RESCUE_' | sed 's/^/    /' \
      || echo "    (none set)"
  else
    echo "  not running (use 'setup')"
  fi
  echo ""
  echo "Staging dir: $STAGING_DIR"
  if [ -d "$DATA_DIR" ]; then
    echo "  windows logged: $(find "$DATA_DIR/windows" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
    echo "  total events:   $(find "$DATA_DIR/windows" -name '*.jsonl' -exec cat {} \; 2>/dev/null | wc -l | tr -d ' ')"
  fi
  echo ""
  echo "Symlinks in ~/.local/bin/:"
  for n in claude-rescue claude-rescue-log claude-rescue-backfill; do
    if [ -L "$HOME/.local/bin/$n" ]; then
      echo "  $n -> $(readlink "$HOME/.local/bin/$n")"
    fi
  done
}

cmd_teardown() {
  if tmux -L "$SOCK" has-session 2>/dev/null; then
    tmux -L "$SOCK" kill-server
    echo "==> killed staging server"
  fi

  if [ -d "$STAGING_DIR" ]; then
    printf '==> remove %s? [y/N] ' "$STAGING_DIR"
    read -r ans
    case "$ans" in [yY]|[yY][eE][sS]) rm -rf "$STAGING_DIR"; echo "    removed";; *) echo "    kept";; esac
  fi

  printf '==> unlink ~/.local/bin/claude-rescue{,-log,-backfill}? [y/N] '
  read -r ans
  case "$ans" in [yY]|[yY][eE][sS])
    for n in claude-rescue claude-rescue-log claude-rescue-backfill; do
      if [ -L "$HOME/.local/bin/$n" ]; then
        unlink "$HOME/.local/bin/$n" && echo "    unlinked $n"
      fi
    done
    ;;
  *)
    echo "    kept"
    ;;
  esac
}

case "${1:-setup}" in
  setup)    cmd_setup ;;
  attach)   cmd_attach ;;
  status)   cmd_status ;;
  teardown) cmd_teardown ;;
  *) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
