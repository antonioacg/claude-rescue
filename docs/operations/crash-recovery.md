# Crash recovery

What survives an abrupt tmux server death (kill -9, OS panic, machine
shutdown) and what reborn panes look like after `tmux-resurrect` restores.

## What's durable across a crash

| State | Where | Survives crash? |
|---|---|---|
| Window UUID (`@claude-window-id`) | tmux pane option | ✗ tmux state — propagated via resurrect sidecar `<state>.claude-userops.tsv` |
| Pane UUID (`@claude-pane-id`) | tmux pane option | ✗ tmux state — propagated via resurrect sidecar |
| Event log | `$DATA/windows/<window_uuid>.jsonl` | ✓ filesystem |
| Meta rollup | `$DATA/windows/<window_uuid>.meta.json` | ✓ filesystem |
| Captures | `$DATA/captures/<pane_uuid>.{txt,json}` | ✓ filesystem |
| Busy marker | `$CACHE/busy/<pane_uuid>` | ✓ filesystem (and ages out via `BUSY_FRESHNESS`) |
| Hibernated marker | `$CACHE/hibernated/<pane_uuid>.json` | ✓ filesystem |
| Arm pid file | `$CACHE/hibernated/_<sanitized_pane_id>.arm.pid` | ✓ filesystem, but the pid is dead → cleaned up on restore |
| Resurrect snapshot | `~/.local/share/tmux/resurrect/<socket>/tmux_resurrect_<ts>.txt` | ✓ filesystem |

## Hooks at restore

The resurrect-restore pipeline calls `claude-rescue-log resurrect-restore` at
`@resurrect-hook-pre-restore-pane-processes` (timing matters: the sidecar
options must be re-applied **before** resurrect's `send-keys` re-launches
pane processes, otherwise `claude-rescue-resume` would not see
`@claude-pane-id` and would fall back to a fresh session). This handler does:

1. **Re-apply** `@claude-window-id` / `@claude-pane-id` from the sidecar TSV.
2. **Auto-promote** any `mode=soft` markers to `mode=hard` with
   `hard_source: "crash-promote"`. Rationale: a soft-hibernated claude died
   with the crash; treating it as still-soft would trigger a spurious
   `fg<Enter>` send-keys to a fresh shell on the user's next focus-in.
3. **Clean** stale `*.arm.pid` files (pids belonged to the dead server).
4. **Spawn** a backgrounded subshell that, after 5s (lets resurrect finish
   launching pane processes), iterates panes with `mode=hard` markers and:
   - if `hard_source == "crash-promote"` — skip (the resurrect wrapper is
     restoring claude via `shell → claude-rescue-resume → claude`;
     `pane_current_command` is a moving target through that pipeline, so we
     gate on **intent** stored in the marker, not on current state). Marker
     cleanup is then handled by `cmd_session_start` when the wrapper-launched
     claude fires its SessionStart hook;
   - otherwise (timer-driven hard) — `tmux send-keys "claude-rescue print" Enter`
     then `tmux send-keys "clr <session_id>"` (no Enter — pre-filled at the prompt).
     The marker is **NOT** deleted here: `clr <sid>` on the prompt is live
     readline input that tmux-resurrect doesn't capture, so a second crash
     before the user presses Enter would lose the recipe. Marker survives
     until `cmd_session_start` (user pressed Enter or typed `cl` for a new
     session) or `cmd_pane_died` (pane closed without resuming).

## Resurrect's command-resolution behavior

tmux-resurrect saves each pane's process via `pane_current_command` (field 10)
**and** the full command line (field 11). On restore, it consults the
`@resurrect-processes` mapping. The pattern `claude->claude-rescue-resume *`
is keyed on the **first word of the full command line** (after stripping the
leading `:`). The leading `~` (substring-regex form) is deliberately **omitted**
— with it, anything whose full command contained `claude` anywhere (e.g.
`nvim /tmp/file-claude.md`) would match and get wrapped, which is wrong. So:

| Save-time state | Field 10 | Field 11 begins with | Restore behavior |
|---|---|---|---|
| Claude actively running (foreground) | `claude` | `claude --add-dir ...` | wrapper applied → `claude-rescue-resume --add-dir ...` → `claude -r <found_sid>` |
| Soft-hibernated (claude in T, shell foreground) | `zsh` | `claude --add-dir ...` | **wrapper still applied** (matches on first word of full cmd) → claude resumes the session |
| Hard-hibernated (claude exited, fresh shell) | `zsh` | `:` (empty) | resurrect launches default shell, no wrapper, no claude |
| Pane with no claude history | `zsh` | `:` | default shell, no wrapper |

So **soft-hibernated panes auto-resume claude on restore via the wrapper**.
The post-restore-keys subshell skips them. Hard-hibernated panes reach the
post-restore subshell and get `claude-rescue print` + `clr <sid>` pre-fill.

## Find-sessions transcript filter

`claude-rescue find-sessions` filters out sessions without an on-disk
transcript (`~/.claude/projects/<encoded_cwd>/<sid>.jsonl`). A claude session
that was started but never received a user message has no transcript and is
not resumable — `find-sessions` returns the next-most-recent session that
does. This is intentional: resuming a transcript-less session silently
spawns a fresh one, masking the resume failure.

## Manual crash-test recipe

```bash
# 1. Bring up staging, start claude in a pane, send any prompt (creates transcript)
scripts/staging.sh setup
scripts/staging.sh attach   # in another terminal
# inside staging: cl  → "hi"  → wait for response

# 2. Set fast delays so we don't have to wait an hour
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_SOFT_DELAY 8
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_HARD_DELAY 999  # so hard doesn't fire

# 3. Trigger soft hibernation: focus away from the claude pane, wait 10s.
#    Verify $CACHE/hibernated/<pane_uuid>.json has mode=soft.

# 4. Force a resurrect-save while in the soft-hibernated state
tmux -L claude-rescue-staging run-shell \
  '~/.config/tmux/plugins/tmux-resurrect/scripts/save.sh'

# 5. Crash the server (find pid, kill -9):
SERVER_PID=$(pgrep -f "tmux.*-L claude-rescue-staging" | head -1)
kill -9 "$SERVER_PID"

# 6. Restart server + trigger restore:
scripts/staging.sh setup
tmux -L claude-rescue-staging run-shell \
  '~/.config/tmux/plugins/tmux-resurrect/scripts/restore.sh'

# 7. Wait 8s for restore + post-restore-keys subshell, then verify:
sleep 8
tmux -L claude-rescue-staging list-panes -aF \
  '#{pane_id} cmd=#{pane_current_command} pane_uuid=#{@claude-pane-id}'
# Soft-hibernated pane should be back as cmd=claude (wrapper auto-resumed).

# 8. For the hard-hibernated path, run timer-driven hard hibernation FIRST
#    (let HARD_DELAY elapse), force-save (now pane is shell), then crash+restore.
#    Verify the visible pane content shows `claude-rescue print` output and
#    `clr <sid>` pre-filled at the prompt.
```

## What's NOT yet handled

- **Stale captures from long-dead claudes**: a pane that ran claude six months
  ago still has its capture on disk. If the user resurrects it as shell, no
  marker exists, so the post-restore-keys subshell does nothing. Capture
  is just orphaned data on disk; can be `rm`'d safely.
- **Multiple sessions per pane lifecycle**: if a pane went through several
  claudes (some that produced transcripts, some that didn't), `find-sessions`
  picks the most-recent-with-transcript. Usually correct, but edge cases
  (e.g., the user restarted claude with `-r OLD_SID` after a crash and the
  old transcript exists but was abandoned) can resume a session the user no
  longer wants. Manual override: pick from the picker (`prefix + R`).
