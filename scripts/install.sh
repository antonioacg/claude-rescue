#!/usr/bin/env bash
# install.sh — symlink claude-rescue binaries into ~/.local/bin/.
#
# Idempotent: an existing symlink to the right target is left alone; an
# existing file or symlink to a different target is reported and skipped.
#
# Modes:
#   install.sh --dry-run   Print what would happen.
#   install.sh             Print + ask before each symlink.
#   install.sh --apply     Print + create silently.
#
# This script does NOT modify ~/.tmux.conf or ~/.claude/settings.json — those
# are managed by chezmoi (see the README for the wiring).

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BIN="$HOME/.local/bin"
MODE="${1:-}"

case "$MODE" in
  --dry-run|--apply|"") ;;
  *) echo "usage: $0 [--dry-run | --apply]" >&2; exit 2 ;;
esac

DRY=0;        [ "$MODE" = "--dry-run" ] && DRY=1
INTERACTIVE=1; [ "$MODE" = "--apply" ] && INTERACTIVE=0

confirm() {
  [ "$INTERACTIVE" -eq 0 ] && return 0
  printf '%s [y/N] ' "$1" >&2
  local ans; read -r ans
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

mkdir -p "$LOCAL_BIN"

for src in "$REPO/bin/"*; do
  [ -f "$src" ] || continue
  name="$(basename "$src")"
  dst="$LOCAL_BIN/$name"

  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    echo "  $name → already linked"
    continue
  fi

  if [ -e "$dst" ]; then
    echo "  ! $dst exists and is not our symlink — skipping"
    continue
  fi

  if [ "$DRY" -eq 1 ]; then
    echo "  [dry-run] ln -s $src $dst"
  elif confirm "  create $dst → $src?"; then
    ln -s "$src" "$dst"
    echo "    linked."
  else
    echo "    skipped."
  fi
done

if [ "$DRY" -eq 1 ]; then
  echo "Dry run complete. Re-run with --apply to install."
fi
