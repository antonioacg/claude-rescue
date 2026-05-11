# Production rollout runbook

End-to-end procedure for cutting over a live machine to the
hibernation-capable claude-rescue. Written so the operator (human or
agent) on a second machine can replay what was done on the first machine.

**Final validation step is `tmux kill-server`** — we deliberately exercise
the resurrect+continuum auto-restore path while the new wiring is live, so
any regression in restore behavior shows up immediately. The state-dump
captured in step 1 is the manual fallback for that step.

> Assumes the machine starts in the same shape as the first Mac at rollout
> time: chezmoi `feat/claude-rescue-prod-deploy` checked out (or merged to
> main), claude-rescue `feat/hibernation-capture-and-tooling` checked out
> (or merged to main), live tmux server has the *pre-rollout* config
> loaded, symlinks in `~/.local/bin/` already point at the repo.

---

## 1. Capture a state dump (don't skip)

```bash
bash ~/dev/claude-rescue/scripts/state-dump.sh
```

Writes to `~/claude-rescue-dumps/dump-<ts>/`. Files you'll care about if
something goes wrong:

| File | Purpose |
|---|---|
| `summary.md` | counts + file index |
| `restore-plan.tsv` | **manual restore plan** — one line per claude pane: session, window/pane indexes, cwd, latest claude session_id |
| `tmux-panes.tsv` | full raw pane inventory |
| `tmux-sessions.tsv` / `tmux-windows.tsv` | session and window layout |
| `repos.md` | git SHAs of both repos at dump time |
| `rescue-runtime.md` | in-flight hibernation/busy markers (should be all empty pre-rollout) |
| `resurrect.md` | resurrect snapshot pointer + size |

If automation fails in step 5, re-create panes by hand, `cd` to the cwd
column, and run `clr <latest_session_id>` to resume each claude.

## 1b. Backfill recaps for panes with no on-disk transcript

The dump's `restore-plan.tsv` may have rows with an empty
`latest_session_id` — claude panes whose `.jsonl` transcript was pruned
(or never written, for sessions that haven't been prompted yet). For
those panes, the in-memory claude has context but nothing on disk to
resume from. **If we restart the server now, that context is gone.**

Send each one a recap prompt so claude's response writes a fresh
`.jsonl` we can resume from later:

```bash
bash ~/dev/claude-rescue/scripts/recap-missing.sh --dry-run   # preview
bash ~/dev/claude-rescue/scripts/recap-missing.sh             # send
```

The script re-checks each target pane's `pane_current_command` at send
time and skips anything that isn't currently `claude` — it never types
the prompt into a shell. Default input is the latest dump under
`~/claude-rescue-dumps/`.

After it runs, give claudes ~30s to respond. The recaps land as new
messages in their `.jsonl` files.

## 2. Validate the code on this machine

Quick gate (~30s, isolated, safe anytime):

```bash
cd ~/dev/claude-rescue
bash scripts/validate.sh
```

If that passes and you want belt-and-suspenders:

```bash
bash scripts/validate-hibernation.sh     # ~3 min, rebuilds staging
bash scripts/validate-crash-restore.sh   # ~4 min, rebuilds staging
```

These destroy the staging server on exit. Don't run during a busy day.

## 3. Sanity-check what `chezmoi apply` will do

```bash
chezmoi diff
```

Expected changes:

- `~/.claude/settings.json` — adds `claude-rescue-log` hooks for
  `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` (and any others
  the chezmoi template manages). The merge is non-destructive: existing
  `copy-claude-response`, `git-lock-cleanup`, `format-csharp` hooks survive.
- `~/.tmux.conf` — `@resurrect-processes` pattern updated (tilde dropped
  from the claude entry; nvim with "claude" in the path no longer matches).
- Other deltas your dotfiles happen to have. Inspect; nothing unexpected
  should be in the diff scoped to this rollout.

If you see anything surprising, stop and investigate.

## 4. Apply chezmoi

```bash
chezmoi apply
```

The `run_once_after_15-install-claude-rescue.sh.tmpl` script will not
re-run (it's `run_once_`, and was already executed on first install). The
symlinks in `~/.local/bin/` are unchanged — they already point at the
repo. To force the installer to re-run:

```bash
bash ~/dev/claude-rescue/scripts/install.sh --apply
```

## 4b. Re-dump (mandatory before kill-server)

The dump from step 1 is now stale: recap-missing wrote new transcripts,
and chezmoi apply may have rewritten config. Re-run the dump so the
manual-restore fallback for the next step reflects the *current* state:

```bash
bash ~/dev/claude-rescue/scripts/state-dump.sh
```

Verify the previously-empty `latest_session_id` rows are now populated:

```bash
LATEST="$(/bin/ls -td ~/claude-rescue-dumps/dump-* | head -1)"
awk -F'\t' 'NR>1 && $7==""' "$LATEST/restore-plan.tsv"
```

Output should be empty (or only show panes you knowingly chose not to
recap). If anything you care about is still empty, return to step 1b
before continuing.

## 5. Final validation — restart the tmux server

This is the load-bearing step. We deliberately kill the live server so
continuum's auto-restore brings everything back with the new wiring. If
anything is broken (resurrect snapshot stale, wrapper path wrong, hook
ordering off), it surfaces here, not silently later. The dump from
step 4b is your manual-restore fallback.

```bash
# 5a. Force a fresh resurrect snapshot so we restore from current state.
tmux run-shell '~/.config/tmux/plugins/tmux-continuum/scripts/continuum_save.sh'

# Sanity: the snapshot should be seconds old.
ls -lt ~/.local/share/tmux/resurrect/default/ | head -3

# 5b. Detach all attached clients cleanly. (Optional but tidier than
# letting them get evicted by the server kill.)
tmux detach-client -a 2>/dev/null || true

# 5c. Kill the server. The boot wrapper + @continuum-restore in
# ~/.tmux.conf spawn a new server and replay the snapshot.
tmux kill-server

# 5d. Wait a couple seconds, then attach.
tmux attach
```

Inside the restored server, verify:

- **Pane count matches the dump.** `tmux list-panes -a | wc -l` should
  equal the `tmux-panes.tsv` line count from the step 4b dump.
- **Each pane is in the right cwd.** Cross-check a few rows against
  `restore-plan.tsv`.
- **claude panes restored as `claude-rescue-resume` then handed off to
  claude.** `tmux list-panes -aF '#{pane_current_command}'` should show
  `claude` for the panes that were claude pre-rollout. (A transient
  `claude-rescue-r` or `bash` is normal during the wrapper handoff —
  re-check after ~10s.)
- **`@claude-pane-id` is being minted on new activity.** Type a prompt
  in any claude pane. Then:
  ```bash
  ls ~/.cache/claude-rescue/busy/        # should see a fresh marker
  tmux list-panes -aF '#{@claude-pane-id}' | sort -u | head
  ```
- **Hibernation hooks are installed.**
  ```bash
  tmux show-hooks -g | grep -E 'pane-focus-|client-attached|client-session-changed'
  ```
  Should list all four.
- **No errors in the rescue logs.**
  ```bash
  tail -n 50 ~/.claude-rescue/rescue-log.err 2>/dev/null
  tail -n 50 ~/.cache/claude-rescue/hibernate.err 2>/dev/null
  ```
  Both empty or only old timestamps.

If restore is incomplete (some panes missing, some in `bash` instead of
`claude`), use `restore-plan.tsv` to recreate them by hand:

```bash
# Per missing pane:
tmux new-session -d -s <session>  # if session is missing
tmux new-window -t <session>:<window_idx>
tmux send-keys -t <session>:<window_idx>.<pane_idx> "cd <cwd> && clr <latest_session_id>" Enter
```

## 6. Watch the system for ~10 minutes

The first soft hibernation can't fire for an hour (default 3600s), but
several other code paths run in the first minutes:

- `arm-sweep` fires on `client-attached` — every claude pane should get an
  arm.pid file: `ls ~/.cache/claude-rescue/hibernated/_*.arm.pid`. Expect
  one per claude pane.
- Claude hooks fire on the next prompt — busy markers appear under
  `~/.cache/claude-rescue/busy/` and refresh on each tool call.
- `client-session-changed` fires when you switch sessions — should be a
  no-op for already-armed panes.

If any of these misbehave: see [hibernation.md](./hibernation.md) for the
model and [staging.md](./staging.md) for reproduction recipes.

## 7. Rollback (only if step 5 or 6 reveals a real problem)

Code rollback is fast because symlinks point at the repo:

```bash
cd ~/dev/claude-rescue
git checkout <prior-good-sha>          # or the branch point of this rollout
```

Config rollback:

```bash
cd ~/.local/share/chezmoi
git revert <merge-or-feat-commit>      # or git checkout HEAD~ for working copy
chezmoi apply
tmux source-file ~/.tmux.conf          # re-load tmux without restart
```

If hibernation is firing destructively in production and you need an
immediate kill switch without a config revert:

```bash
tmux set-hook -gu pane-focus-out
tmux set-hook -gu pane-focus-in
tmux set-hook -gu client-attached
tmux set-hook -gu client-session-changed
```

These four `set-hook -gu` calls remove the hibernation wiring from the
running server. Code rollback can wait.

## 8. Cleanup

- Remove the legacy `~/.claude-rescue/stopped/` directory if it exists and
  is empty (pre-rename leftover): `rmdir ~/.claude-rescue/stopped`.
- Keep the state dump from step 1 for a few days, then delete:
  `rm -rf ~/claude-rescue-dumps/dump-<ts>`.

---

## What this runbook does *not* cover

- Initial install on a fresh machine — that's chezmoi's bootstrap path.
- Building or shipping new feature work — see
  [README.md](./README.md) for the dev loop.
- Day-2 operations (watching logs, picker UX) — see the other docs in
  this directory.
