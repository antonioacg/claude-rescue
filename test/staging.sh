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
#   test/staging.sh setup     install + start staging server (default)
#   test/staging.sh attach    tmux -L claude-rescue-staging attach
#   test/staging.sh status    show what's running and where logs are
#   test/staging.sh teardown  kill server, optionally remove staging dir + symlinks

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAGING_DIR="${CLAUDE_RESCUE_STAGING_DIR:-$HOME/claude-rescue-staging}"
SOCK="claude-rescue-staging"
DATA_DIR="$STAGING_DIR/data"

# ---------------------------------------------------------------------------

cmd_setup() {
  echo "==> 1. Installing binaries into ~/.local/bin/"
  bash "$REPO/install.sh" --apply
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

# Load your real config — theme, status bar position, TPM, plugins, keybindings.
source-file -q "\$HOME/.tmux.conf"

# Now override for staging isolation. These run AFTER ~/.tmux.conf so they win.
set -g @resurrect-dir "$STAGING_DIR/resurrect"
set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'off'
set -g @continuum-save-interval '1'

# Distinguishable status hint so you can tell staging from your main at a glance.
set -ag status-right ' [staging]'

# Picker keybinding
bind R run-shell "claude-rescue"

# claude-rescue hooks (sourced last so nothing in main config can clobber them).
source-file -q "$REPO/tmux/rescue.tmux.conf"
TMUX

  echo "    staging dir ready"
  echo ""

  echo "==> 3. Starting staging tmux server (socket: $SOCK)"
  if tmux -L "$SOCK" has-session 2>/dev/null; then
    echo "    server already running"
  else
    CLAUDE_RESCUE_HOME="$DATA_DIR" PATH="$HOME/.local/bin:$PATH" \
      tmux -L "$SOCK" -f "$STAGING_DIR/.config/tmux/staging.conf" \
        new-session -d -s main -c "$STAGING_DIR" -x 200 -y 50
    tmux -L "$SOCK" set-environment -g CLAUDE_RESCUE_HOME "$DATA_DIR"
    tmux -L "$SOCK" set-environment -g PATH "$HOME/.local/bin:$PATH"
    echo "    started"
  fi

  echo ""
  echo "=========================================================="
  echo " Staging is ready. Attach with:"
  echo "     tmux -L $SOCK attach"
  echo ""
  echo " Inside staging tmux you can try (cwd is auto-set to staging dir):"
  echo "     claude                # real SessionStart hook fires"
  echo "     /clear                # session_end (reason:clear) + new session_start"
  echo "     exit / Ctrl-D         # SessionEnd hook fires"
  echo "     <prefix> + R          # popup picker (claude-rescue)"
  echo ""
  echo " Watch hooks fire from a normal terminal:"
  echo "     tail -F $DATA_DIR/rescue-log.err"
  echo "     ls -l $DATA_DIR/windows/"
  echo "     jq -c . $DATA_DIR/windows/*.jsonl"
  echo ""
  echo " When done:"
  echo "     $REPO/test/staging.sh teardown"
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
