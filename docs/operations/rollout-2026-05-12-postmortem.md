# Postmortem — production rollout 2026-05-12

Re-running the production rollout on the same Mac the 2026-05-11 cutover
landed on. Goal was to validate that the recovery paths in the runbook
actually work end-to-end; we'd never reproduced the original 2026-05-11
failure (32 of 33 panes back as zsh) but the recovery was assumed to be
sound. **The recovery was not sound.** This rollout found three bugs that
together made the auto-restore path unreliable — but recovery via a
truthful (pane → sid) map captured from each claude pane's bottom status
worked every time. Five patches landed against `bin/`, `tmux/`, and
`scripts/` to make the restore path durable.

## What we tested

Three consecutive `kill-server` cycles on the live tmux server:

| Cycle | Auto-resumed | Stuck as zsh | Resumed *correctly* | Manual recovery needed |
|---|---|---|---|---|
| 1 (pre-patches) | 14 / 21 | 6 / 21 + %32 trust prompt | 12 of 14 (2 wrong-sid forks) | 7 panes (clr by truthful map) |
| 2 (mid-patches) | 10 / 21 | 10 / 21 + %32 | 10 of 10 | 10 panes (clr by truthful map) |
| 3 (post-patches) | 20 / 21 | %32 only | **20 of 20 via P1-active** | 0 panes |

The third cycle is what we shipped. `wrapper.log`: 21/21 invoked, 21/21
resolved. `rescue-log.err`: pre-restore-all lock created, sidecar 40 rows
reapplied, post-restore-all lock removed. Process-tree verification: every
pane's running claude has `-r <truthful_sid>` matching the captured map.

## Root causes

### 1. The "truthful sid" was never captured

State-dump's `restore-plan.tsv` and `backfill-pane-uuids.sh` both use the
**mtime of the most-recent jsonl per cwd** as a proxy for "what session is
loaded in this pane." That assumption breaks on:

- `/resume` inside claude: claude forks to a new sid, writes a new jsonl,
  the saved tmux-resurrect cmdline still has the *original* `-r <old_sid>`
  in argv. mtime-latest is the NEW sid but saved -r is the OLD sid.
- `--fork-session`: same flavor — argv has the parent sid, but the
  running session is a fresh fork. The fork's jsonl may not exist on disk
  yet (no user message → no write).
- Manual transcript moves: operator copied `d61750c1.jsonl` between cwds
  before the rollout. mtime is now misleading in *both* cwds.
- Multi-pane cwds: the Nth-most-recent → Nth-pane heuristic is arbitrary
  for any reasonable definition of "Nth pane."

For 13 of 21 panes on this rollout, the mtime heuristic disagreed with the
session UUID claude was actually rendering in its footer. Nothing in the
runbook caught this — the dry-run validation just confirmed the script
ran, not that the assignment was right.

**Fix**: new `scripts/capture-truthful-sids.sh` scrapes the displayed sid
from each pane's bottom status (1–3 lines above the "bypass permissions"
footer). For hibernated panes (claude SIGTSTP'd), it falls back to
`$DATA/captures/<pane_uuid>.txt` saved by the hibernate-arm path. The
runbook now captures this map *before* the rollout starts and uses it as
the source of truth for backfill verification + post-restore-validation.

### 2. The wrapper's documented priority chain was a lie

`bin/claude-rescue-resume` says in its docstring:

> Resolve the resume target with this priority:
>   1. $DATA/active/<pane_uuid>
>   2. find-sessions lookup
>   3. saved -r/--resume args
>   4. None — fresh session

But the code gated find-sessions behind `[ -z "$existing_uuid" ]`, so any
pane whose tmux-resurrect cmdline still had `-r <saved_sid>` (which is
almost all of them) **never consulted find-sessions**. For `/resume`'d
panes (where saved -r is stale and find-sessions has the truthful sid),
the wrapper silently resumed the wrong (pre-`/resume`) session.

Two panes hit this: `%27` (saved `-r f2818d53`, truthful `1b6d0087`) and
`%37` (saved `-r ed93af82`, truthful `15901931`). The wrong sessions
resumed without any visible error; only process-tree inspection revealed
the divergence.

**Fix**: removed the `existing_uuid`-guard from the find-sessions block.
Also removed saved -r as a fallback entirely — see (3).

### 3. Saved `-r` is permanently stale; trusting it corrupts state

The wrapper's P3 fallback to saved `-r` (from the tmux-resurrect cmdline)
exists to handle "legacy data that pre-dates pane_uuid attribution." In
practice it ALSO catches the case where active/ is cleared by SessionEnd
or never written — exactly the cases where saved -r is most likely to be
stale. If two panes' sessions diverged on `/resume`, both wrappers would
resume the SAME saved sid, racing each other for the same on-disk
transcript and corrupting both.

**Fix**: dropped the P3 branch entirely. The wrapper now goes
`active → find-sessions → fresh`. Pre-`/resume` argv is parsed only to
*strip* `-r` from final_args (so it can't sneak through) and surface in
debug output.

### 4. The active/ dir was bulk-cleared at restore — destroying the only
truthful source

`cmd_resurrect_restore` called `rm -f $DATA/active/*` at hook fire,
under the theory that entries from a dying server might point at sessions
"whose pane_uuid mapping may have shifted." But in this codebase, pane
UUIDs are durable across kill-server (the sidecar reapplies them). The
active files are written by SessionStart hooks keyed by that same durable
UUID, so they're never stale for a still-existing pane — only orphaned
for vanished ones. Clearing all of them just before the wrapper tries to
resolve P1 means P1 always misses on first restore.

**Fix**: removed the bulk-clear. Files persist across kill-server. The
wrapper reads them. Orphans for vanished pane_uuids are harmless (the
wrapper only queries by live pane_uuid). A one-time orphan sweep can run
on demand if accumulation becomes a problem.

### 5. The snapshot race

The biggest find of the rollout. With (1)–(4) patched, the third
kill-server cycle should have been clean. It wasn't — only 14 of 21
panes auto-restored, sidecar reapply bailed because the sidecar file the
hook expected didn't exist. Trace:

1. `tmux -L default new-session -d -s _probe` starts a new server.
2. tmux-continuum's auto-restore detects "no sessions" and triggers
   tmux-resurrect's `restore.sh`. tmux-resurrect reads `last` symlink to
   resolve which snapshot to replay.
3. tmux-resurrect creates sessions/windows/panes structurally, then runs
   `pre-restore-pane-processes` hook.
4. Meanwhile, tmux-continuum's status-bar-interval save mechanism fires
   (interval = 1 minute, status updates every second). Continuum's save
   delegates to `@resurrect-save-script-path`. The save captures the
   *currently in-progress* restored state — panes with empty
   `pane_full_command` (claude argv not yet sent) — and rotates `last`
   to point at this partial snapshot.
5. Our `cmd_resurrect_restore` hook fires, reads `last`, finds the new
   partial snapshot. Looks for a matching `.claude-userops.tsv` sidecar.
   The post-save-layout hook DID write a sidecar for the partial
   snapshot, but at save time @claude-pane-id options weren't yet set on
   the just-restored panes, so the sidecar contains 0 pane rows. With no
   pane rows to reapply, every pane's `@claude-pane-id` stays unset.
6. tmux-resurrect's `send-keys` phase runs. Wrappers fire with empty
   `pane_uuid` (no @claude-pane-id) → P1 active misses (no key) → P2
   find-sessions misses (no key) → falls back to fresh OR (pre-fix)
   saved -r. The dropped send-keys to ~6–10 panes leaves them as zsh.

**Fix**: three coordinated changes prevent continuum's save from running
during tmux-resurrect's restore window.

1. `bin/claude-rescue-log` gained `cmd_resurrect_pre_restore_all` (wired
   via the earliest restore hook `@resurrect-hook-pre-restore-all`) that
   creates a `$resurrect_dir/.restoring` lock file. A mirror
   `cmd_resurrect_post_restore_all` (wired via
   `@resurrect-hook-post-restore-all`) removes it after send-keys is
   done.

2. `scripts/save-guarded.sh` is a thin wrapper around tmux-resurrect's
   real `save.sh` that bails if `.restoring` exists.
   `tmux/rescue.tmux.conf` sets `@resurrect-save-script-path` to this
   wrapper. tmux-continuum's `continuum_save.sh` reads the option and
   uses whatever's there, so our gate now intercepts every
   continuum-driven save.

3. `~/.tmux.conf`'s existing `session-window-changed`-driven save was
   already gated on `.restoring` via an inline `[ ! -f ]` check — but
   the lock was never created by anything until our hooks. That gate is
   now functional too, bonus.

The send-keys race the 2026-05-11 postmortem flagged as a possible root
cause? Disappeared once continuum stopped fighting the restore. Cycle 3
had 21/21 send-keys delivered with no special handling. **The original
2026-05-11 failure may have been the same snapshot race + send-keys
amplification, not a load-dependent quirk of that machine.** We can't
prove that retroactively but the symptom shape matches.

## Patches landed

| File | Change |
|---|---|
| `bin/claude-rescue-resume` | Removed P3 fallback to saved `-r`; find-sessions runs whenever pane_uuid is set (regardless of existing `-r` in argv) |
| `bin/claude-rescue-log` | Added `cmd_resurrect_pre_restore_all` + `cmd_resurrect_post_restore_all` (create/remove `.restoring` lock); removed `rm -f $DATA/active/*` from `cmd_resurrect_restore` |
| `tmux/rescue.tmux.conf` | Wired `@resurrect-hook-pre-restore-all` + `@resurrect-hook-post-restore-all`; pointed `@resurrect-save-script-path` at `save-guarded.sh` |
| `scripts/save-guarded.sh` | **NEW** — lock-aware wrapper around tmux-resurrect's `save.sh` |
| `scripts/capture-truthful-sids.sh` | **NEW** — scrapes the displayed sid from each claude pane (live + hibernation captures) as the source of truth for pane → sid mapping |
| `scripts/validate.sh` | Updated scenario 11d (active/ now preserved at restore, not cleared) |

## Lessons (for the third Mac and beyond)

1. **Mtime is a heuristic, not a source of truth.** Anything that wants
   to know "what session is loaded" should read it from the running
   process or its captured display. The runbook now does this up front
   via `capture-truthful-sids.sh` and uses it to validate the dump.

2. **Document the priority chain in the code and stick to it.** The
   wrapper's docstring was correct; the code was wrong. The drift was
   undetectable from the docs side and only surfaced when an outsider
   read the actual code in production. We added a `scripts/validate.sh`
   scenario asserting find-sessions runs even with `-r` in argv, so the
   docstring is now load-bearing.

3. **Stop trusting saved -r.** It's argv-frozen at claude launch and
   never updates on in-process `/resume`. Either the active file says
   what session is loaded (truthful) or we don't know — and "don't know"
   should mean "fresh session", not "guess from argv."

4. **Restore is a critical section.** While tmux-resurrect is laying
   down panes, NOTHING ELSE should be writing snapshot state. The
   `.restoring` lockfile pattern was already half-there in `~/.tmux.conf`
   for a different save path; it just needed extending to the
   continuum-driven path and an actual writer.

5. **Hibernated panes shouldn't be invisible.** `capture-truthful-sids.sh`
   falls back to the hibernation capture file when claude is suspended.
   Without this, 16 of our 20 truthful entries would have come back blank
   on the third replay (claude had Ctrl+Z'd most panes between cycles).

## What this postmortem does NOT cover

- The 2026-05-11 failure root cause is still unproven. The symptom shape
  matches what we saw in cycles 1+2 of this rollout — but we have no
  pre-instrumented trace from 2026-05-11 to confirm. Treat the snapshot
  race as the working hypothesis.
- Long-term hardening beyond the patches above. The orphan-active-file
  accumulation pattern is harmless but inelegant; a periodic sweep
  could fix it. Not a blocker.
