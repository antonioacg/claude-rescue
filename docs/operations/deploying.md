# Deploying to the live system

claude-rescue is wired into the live system through three layers:

| Layer | Source of truth | How it propagates |
|---|---|---|
| Binaries (`bin/`) | this repo | symlinked into `~/.local/bin/` by `scripts/install.sh` (run once via chezmoi `run_once_after_15-install-claude-rescue.sh.tmpl`) |
| `~/.tmux.conf` | chezmoi `dot_tmux.conf` | sources `~/dev/claude-rescue/tmux/rescue.tmux.conf` directly — repo edits flow live on next tmux config reload |
| `~/.claude/settings.json` | chezmoi `dot_claude/modify_settings.json.tmpl` | merged on `chezmoi apply` — claude reads it on next claude restart |

## What gets propagated automatically

Edits to:

- `bin/claude-rescue*` — flow through immediately via the symlinks (next process invocation picks them up).
- `lib/common.sh` — same (sourced by the bins on each invocation).
- `tmux/rescue.tmux.conf` — flow on next tmux config reload (`prefix + r` or
  server restart). Changing hook bindings? You also need to refresh the
  running server (see below).

## What needs an explicit deploy step

- `dot_claude/modify_settings.json.tmpl` (claude hooks) — `chezmoi apply`,
  then claude needs to be restarted in each pane to pick up new hooks.
- `dot_tmux.conf` (the `source-file` lines, hook ordering) — `chezmoi apply`,
  then tmux config reload or server restart.
- `scripts/install.sh` itself — chezmoi runs it via the
  `run_once_after_15-install-claude-rescue.sh.tmpl` script. That script's
  hash determines re-run; if you change the installer path or contents, the
  next `chezmoi apply` re-runs it (idempotent).

## Live-server config refresh (no restart)

If you've only changed `tmux/rescue.tmux.conf`:

```bash
tmux source-file ~/.tmux.conf
```

This replays the whole config; `set-hook -g <event> ...` lines replace the
existing binding for that event. Plugin state (TPM, resurrect, continuum) is
unaffected.

If you've changed `dot_tmux.conf` ordering (e.g., where `rescue.tmux.conf` is
sourced relative to TPM init), you typically want a server restart (continuum
auto-restore brings everything back).

## Live-server cutover

For larger structural changes (new event kinds, sidecar format, hook
re-wiring), the cleanest path is a full server restart with continuum
auto-restore:

```bash
# 1. Apply pending chezmoi changes
chezmoi diff
chezmoi apply

# 2. Validate in staging first (see staging.md)
scripts/staging.sh setup
# ... drive scenarios, verify ...
scripts/staging.sh teardown

# 3. Force a fresh save right before the cut, so we restore from the latest state
tmux run-shell '~/.config/tmux/plugins/tmux-continuum/scripts/continuum_save.sh'

# 4. Kill the live server. Continuum's auto-restore (configured in dot_tmux.conf)
#    will spawn a new server with the new config and restore from the last save.
tmux kill-server
```

`@continuum-restore on` and the boot wrapper in your main config handle the
auto-restore; you don't need to invoke it manually. Sessions reattach
naturally — terminals that were attached are now disconnected; reattach with
`tmux attach` or via your normal launcher.

## Rollback

Binaries: `git checkout` the previous version of `bin/`. Symlinks already
point at the working tree, so the rollback is instant.

Chezmoi state: `git revert` in the chezmoi source dir, then `chezmoi apply`.
The merge in `modify_settings.json.tmpl` is non-destructive — your
`copy-claude-response` and other personal hooks survive any merge change.

If `~/.claude/settings.json` ends up in a weird state after a partial
`chezmoi apply`, you can hand-edit it; chezmoi `modify_` scripts re-merge
from current contents on each apply.

## Common pitfalls

- **Editing `bin/` while claude is running**: bin scripts are read on each
  invocation; edits take effect immediately for new invocations. A claude
  session that fired SessionStart before the edit isn't affected — the hooks
  in its memory still point to the binary's previous behavior, but each
  invocation will read the latest source.
- **Forgetting tmux config reload**: hook changes in `rescue.tmux.conf` only
  apply after `tmux source-file ~/.tmux.conf` or server restart.
- **Forgetting claude restart**: claude reads `~/.claude/settings.json` on
  startup. Adding a new hook (e.g., `Stop`) doesn't fire for already-running
  claude processes — they need `/exit` and `cl` again.
- **Stale saved commands in resurrect**: if you change the wrapper name in
  `@resurrect-processes`, existing saves still reference the old name. Force
  a save after the change so subsequent restores use the new wrapper.
