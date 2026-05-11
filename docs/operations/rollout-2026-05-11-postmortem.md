# Postmortem — production rollout 2026-05-11

Rollout of the hibernation/sidecar/wrapper changes to the live tmux server on
the first Mac. The cutover succeeded — every claude conversation was recovered —
but **the first `kill-server` left 32 of 33 claude panes as bare shells, and we
never produced evidence of the precise root cause.** Recovery worked by luck of
having multiple independent backing stores. Documenting so the next failure (on
this Mac or the second) lands on better ground.

## Timeline (UTC)

- ~12:54 — Operator-agent ran `tmux -L default kill-server` (step 5 of the
  runbook). Continuum's auto-restore + the user's custom
  `~/.config/tmux/scripts/restore-wrapper.sh` brought back the layout (9
  sessions, 37 windows, 46 panes, all in their right cwds) but **only 1 of 33
  claude panes had claude relaunched**. The other 32 came back as bare zsh
  shells.
- ~12:55–14:40 — Cascade: continuum kept saving the broken state every minute.
  The `last` symlink advanced through several minutes of saves that captured
  the panes as `pane_full_command=":"` (empty). Each subsequent automatic
  re-restore (likely triggered by manual `prefix+Ctrl-r` attempts during the
  user's recovery flailing) found nothing to send-keys for those panes.
- ~14:00 — User's Mac stopped accepting login-screen input. Reboot. Default
  tmux server died; rollout-operator server (the isolated agent's home)
  survived because tmux servers are independent.
- ~17:40 — Post-reboot, with new observability committed (`6e08602`,
  `b03e79a`), user attached to default. The boot wrapper triggered restore from
  a now-degraded snapshot (`tmux_resurrect_20260511T135430.txt`, which had only
  3 saved-as-claude panes). Wrapper invoked for 2 of those 3. The wrapper for
  pane `%0` crashed on `set -- "${rebuilt[@]}"` with `unbound variable` because
  its saved cmd was just `claude -r <UUID>` (post-prior-restore shape) — fixed
  as `b03e79a`.
- ~18:00 — Outer session ran manual `clr <sid>` recovery in window 2 of the
  operator server. 30 of 33 panes recovered; 2 deliberately killed (`%13`,
  `%16` were backfilled to the same session_id as the live outer-session
  conversation due to a thin transcript pool in `/Users/.../dev/`).
- ~18:05 — Operator-agent ran the second `kill-server`. Restore worked
  end-to-end. `wrapper.log` recorded **31 invoked / 31 resolved**. Hook trace
  clean (`applied window=30 pane=31 skipped=0`). The original failure did NOT
  reproduce.

## What we never figured out

The first kill-server's wrapper invocation count is unknown — observability
was added afterward. The two falsifiable hypotheses that survived to the redo
were:

1. **`tmux-resurrect` `send-keys` race** — `process_restore_helpers.sh:38`
   fires `send-keys` immediately after `new_pane` with no shell-readiness
   wait. Plausible if 33 panes restored in burst.
2. **Hook interference** — `rescue.tmux.conf` was loaded LIVE for the first
   time on this server during this rollout (the source-file `~`-not-expanded
   bug had silently kept it inert before). That introduced three things during
   restore: 65+ `tmux set-option` calls in the pre-restore-pane-processes
   hook, ~30 `arm-sweep` subshells on `client-attached`, and `pane-focus-out`
   / `-in` firing on every `select-pane` in the restore iteration. Any of
   those could compete with the tmux server's event loop and disrupt
   send-keys delivery.

The redo (same code, same hooks, same restore path) produced **31/31 wrapper
invocations** with no special handling. So whichever hypothesis was true at
~12:54, it didn't reproduce at ~18:05. Possible explanations we can't
distinguish:

- Transient system pressure at the original moment (the user's Mac
  subsequently failed to accept login input — memory pressure was real)
- A one-time interaction we can't reconstruct without instrumentation
- A combination

## What got us out

The recovery worked because of independent backing stores, none of which
required us to know the root cause:

1. **`@claude-pane-id` survived the kill-server cycle** via the resurrect
   sidecar (`tmux_resurrect_*.claude-userops.tsv`). The pre-restore hook
   reapplied them to the new panes. This was the load-bearing data store —
   without it, the wrapper's `find-sessions` lookup would have had nothing to
   key on.
2. **Claude's own transcripts** in `~/.claude/projects/<encoded-cwd>/*.jsonl`
   were untouched by the failure. Sessions were always resumable as long as we
   could identify the right one per pane.
3. **`scripts/state-dump.sh` + `restore-plan.tsv`** had captured the
   pre-rollout `(pane → session_id)` mapping at step 1 / step 4e. Even if the
   sidecar had been lost, the dump would have told us which session each pane
   should resume.
4. **`tmux-resurrect`'s `pane_contents.tar.gz`** preserved each pane's saved
   scrollback. Visual recovery would have been possible (read pre-kill
   content, identify what conversation was there, `clr` the matching session)
   even if the structured stores had failed.

The recovery path that actually worked: walk panes with
`@claude-pane-id != "" AND pane_current_command != claude`, run `clr <sid>`
per pane via send-keys with inter-pane delay. Implemented as
`scripts/restore-zsh-to-claude.sh` (manual tool, not wired into hooks).

## Real bugs caught and fixed during the rollout

| # | Commit | Bug | Impact |
|---|---|---|---|
| 1 | `7137b48` (chezmoi) | `source-file -q '~/dev/.../rescue.tmux.conf'` — tmux doesn't expand `~`, `-q` swallows the error | Every `claude-rescue` tmux hook was silently inert on this Mac since the source line was added. Hibernation, sidecar, arm-sweep, pre/post-restore hooks all dead. Discovered during step 4d when `show-options -gv @resurrect-hook-post-save-layout` returned `invalid option` after `source-file`. |
| 2 | `7a3db81` (claude-rescue) | `find-sessions` cwd-encoding mapped only `/` to `-`, not `.` | Picker resume + wrapper find-sessions lookup silently returned 0 rows for any cwd containing `.` (e.g., `.local/share/chezmoi`). Pre-existing — would have broken picker resume for dotfile-cwd sessions independent of the rollout. |
| 3 | `b03e79a` (claude-rescue) | `claude-rescue-resume:120` — `set -- "${rebuilt[@]}"` on empty array with `set -u` errors with `unbound variable` | When saved cmd is bare `claude -r <UUID>` (which is what panes look like after one successful restore by the wrapper), the rebuild loop strips both args, `rebuilt` is empty, wrapper crashes before exec. Pane drops back to shell with no clear indication. |

## Real bugs caught but NOT fixed

- **Backfill session-collision with live processes** — `backfill-pane-uuids.sh`
  assigns the most-recent transcript per pane in a cwd group. If a session is
  currently running elsewhere (e.g., the rollout operator-claude itself), the
  backfill happily assigns its sid to other panes too. We hit this with `%13`
  and `%16` both mapped to the outer session's `cd9c7a95-...`. Killed both
  panes. Follow-up: backfill should `pgrep -f 'claude .*-r <sid>'` and skip
  in-use sids, falling back to the next-most-recent transcript.
- **Sidecar parser column-misalignment for one row** — observed in the first
  successful redo's hook log: `applied window=30 pane=31` (not 31/31). One
  bufferbloat-wr741 row in the sidecar was parsed with the wrong column
  offset, target became `bufferbloat-wr741` (no index). Pane-level apply
  worked for all 31 panes, but one window's `@claude-window-id` didn't
  reapply. Follow-up: walk
  `cmd_resurrect_restore`'s legacy-4-col vs current-5-col branch and find the
  case that produces this row.
- **Continuum's 1-minute save interval can rapidly poison recoverable state
  after a failed restore** — Once 32 panes came back as zsh, the next save
  captured `pane_full_command=":"` for them. Within minutes the `last`
  snapshot had lost all the saved-as-claude lines. Subsequent restores had
  nothing to relaunch. Follow-up consideration: continuum-save could be
  paused after a server-spawn until a human confirms the restore succeeded,
  similar to `restore-wrapper.sh`'s `.restoring` lockfile but inverted.

## Observability we now have

- **`~/.local/share/claude-rescue/wrapper.log`** — per-invocation log for
  `claude-rescue-resume`. Two lines per call: "invoked" on entry with pid,
  ppid, pane, argc, argv; "resolved" before exec with pane_uuid, find-sessions
  sid, saved -r uuid, target. Lets us answer the next time the restore is
  weird: did the wrapper run? How many times? What did each call decide?
- **`~/.cache/claude-rescue/rescue-log.err`** — `cmd_resurrect_restore` now
  logs hook fired, snapshot name, sidecar row count, per-write outcome, and
  final tallies. Tells us whether the pre-restore hook actually ran and what
  it did.
- **No retry/recovery patch on the restore path** — deliberately. Earlier
  drafts had a `post-restore-all` retry hook that would `clr` panes that came
  back as zsh. Backed out because it would mask future failures (the kind we
  can't explain about the original event). The manual
  `scripts/restore-zsh-to-claude.sh` exists as an emergency tool but isn't
  wired into any hook.

## Lessons for the second Mac's rollout

1. **The runbook needs an instrumentation precheck.** Step 4d should verify
   `wrapper.log` is writeable AND check `cmd_resurrect_restore` writes to
   `~/.cache/claude-rescue/rescue-log.err` via a manual `tmux run-shell`
   invocation. Confirms the observability we'll need IF things fail.
2. **The chezmoi tilde fix and the find-sessions encoding fix are pre-existing
   bugs that affect this rollout's success.** They're now committed on
   feat/main but the second Mac needs to ensure both are present before
   running step 4d's `source-file` and step 5's `kill-server`.
3. **Skip the backfill collision.** Add a `pgrep` check to backfill before the
   second Mac runs it, so `cd9c7a95`-style collisions don't recur.
4. **Don't trust the first kill-server is the whole picture.** Do a second
   kill-restore cycle as confirmation. The first rollout on this Mac had a
   single-attempt failure that didn't reproduce; that may have been
   load-dependent and the second Mac could hit something different.

## What this postmortem does NOT cover

- The actual root cause of the 12:54 failure. We don't have it.
- Long-term hardening (retry hooks, snapshot rollback, etc.). Those are
  intentional tradeoffs we'd consider only with reproducible failure data,
  which we don't have.
