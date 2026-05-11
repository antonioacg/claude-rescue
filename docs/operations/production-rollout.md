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

## On socket assumptions and operator isolation

This runbook **assumes the live tmux server is on the `default` socket**.
Every `tmux ...` invocation that targets the live server uses an explicit
`-L default` to make that assumption visible at the call site (rather than
relying on whatever `$TMUX` happens to point at when the command runs).

The reason: the final step is `tmux -L default kill-server`. If you're
following this runbook from inside an attached terminal on the live
server, killing the server kills your terminal session — fine, you
re-attach. But if you're following it from an **operator pane**, i.e. a
claude or shell living inside a *separate* tmux server (which is what
you'd do to keep your operator process alive across the cutover), bare
`tmux` commands target the operator's own socket. `tmux kill-server`
without `-L` would kill the wrong server. The explicit `-L default`
prevents that confusion.

**If your live server uses a different socket name**, do a find-and-replace
across this runbook: `-L default` → `-L <your-socket-name>`. The scripts
honor `CLAUDE_RESCUE_LIVE_SOCKET`:

```bash
export CLAUDE_RESCUE_LIVE_SOCKET=<your-socket-name>
```

Set it once in the operator's shell; both `state-dump.sh` and
`recap-missing.sh` will pick it up, and the dump's
`tmux-socket.txt` records which socket the dump was taken against (so
`recap-missing.sh` refuses to send to a different one).

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

## 4b. Re-dump (mandatory before backfill / kill-server)

The dump from step 1 is now stale: recap-missing wrote new transcripts,
and chezmoi apply may have rewritten config. Re-run the dump so the
backfill and manual-restore fallback for later steps reflect the
*current* state:

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

## 4c. Backfill @claude-pane-id for panes lacking one

**Why this step exists.** `claude-rescue-resume`, the wrapper that runs
in each restored pane after kill-server, resolves the resume target via
this priority:

1. `@claude-pane-id` on the pane → `find-sessions` lookup → `-r <session_id>`
2. Else: existing `-r <UUID>` parsed from the saved command line
3. Else: no `-r` → claude starts a fresh session

If your live server has a mix of older claude panes that never had
`@claude-pane-id` minted (pre-rollout SessionStart events didn't write
one), AND those panes were originally launched fresh (no `-r` in their
saved tmux-resurrect command), they fall through to (3) and lose
in-memory context on restore.

The backfill script walks current claude panes from step 4b's dump,
mints pane + window UUIDs for those lacking them, writes a
`session_start_backfill` event tying each new pane UUID to one of the
cwd's claude transcripts, and rebuilds the affected windows' meta files.
For cwds with multiple panes, each pane gets a *distinct* session_id
(Nth-most-recent transcript to Nth pane) so they don't race for the
same session at restore. Panes whose cwd has fewer transcripts than
panes are skipped — recovery for those is `clr <sid>` by hand.

**Honest framing of the multi-pane mapping.** Minting a UUID is just a
stable key. Linking that UUID to a session_id is a *claim* — we're
asserting "this pane was running session Y" based on a heuristic
(Nth-most-recent transcript → Nth pane in tmux order), not observation.
For single-pane cwds the claim is reliable (one transcript, one pane).
For multi-pane cwds the within-group mapping is essentially arbitrary:
every pane in the group resumes *some* live conversation from that cwd,
but which-pane-gets-which-session is not load-bearing. The dry-run output
flags this with `(unique)` vs `(heuristic N/M)` annotations.

If after restart a pane shows the "wrong" content for what you expected
in that slot, three backing stores let you recover without losing
anything:

1. **`restore-plan.tsv`** in the step-4e dump — explicit (pane → session_id)
   map. Find the cwd's row group and pick the session_id you actually
   wanted, then `clr <session_id>` in that pane.
2. **`pane_contents.tar.gz`** in the resurrect dir
   (`~/.local/share/tmux/resurrect/default/`) — every pane's scrollback
   at force-save time, because `@resurrect-capture-pane-contents 'on'`
   is set. After restore the panes visually show what they had, which
   makes content-to-session matching straightforward.
3. **`~/.claude/projects/<encoded-cwd>/*.jsonl`** — full append-only
   transcripts on disk. Grep them by content to find the session_id you
   need, then resume.

These three stores together mean "wrong pane got the wrong session" is
recoverable in seconds, not lost work. See step 5's recovery recipes.

```bash
bash ~/dev/claude-rescue/scripts/backfill-pane-uuids.sh --dry-run
# Inspect the MINT/SKIP output. Confirm the (pane → session_id) mapping
# looks sane. Then:
bash ~/dev/claude-rescue/scripts/backfill-pane-uuids.sh
```

The script's tail emits a per-pane round-trip check
(`find-sessions --pane-uuid <minted>` should return the session_id we
wrote). It exits non-zero if any pane fails.

**If the smoke test FAILs on a subset of panes**, the first thing to
check is the `find-sessions` cwd encoding (`bin/claude-rescue`). Claude
encodes cwd → `~/.claude/projects/<dir>` by mapping **both** `/` and
`.` to `-`, so paths containing dotfile segments (e.g.
`~/.local/share/chezmoi` → `-Users-…--local-share-chezmoi` with a
double-dash) require both substitutions. A previous version of
`find-sessions` only mapped `/`, which silently filtered out every
dotfile-cwd session. Symptom: panes whose cwd contains `.` all FAIL
the smoke test, panes whose cwd is dot-free all OK. Scenario 9 in
`scripts/validate.sh` is the regression test; run `bash
scripts/validate.sh` and verify scenarios 9a/9b PASS.

## 4d. Load the new tmux hooks into the live server

`chezmoi apply` updated `~/.tmux.conf` and `~/dev/claude-rescue/tmux/rescue.tmux.conf`,
but the running tmux server has the previous in-memory copy. The new
`@resurrect-hook-post-save-layout` hook needs to be loaded *before*
step 5a's force save, otherwise the sidecar isn't written and the
backfilled `@claude-pane-id`s don't survive kill-server.

```bash
tmux -L default source-file ~/.tmux.conf
```

Verify the hook is now set:

```bash
tmux -L default show-options -gv @resurrect-hook-post-save-layout
# expect: claude-rescue-log resurrect-save "$1"

tmux -L default show-options -gv @resurrect-hook-pre-restore-pane-processes
# expect: claude-rescue-log resurrect-restore
```

If either returns `invalid option`, the source-file didn't load
rescue.tmux.conf. Check that `~/.tmux.conf` has the corresponding
`source-file -q "$HOME/dev/claude-rescue/tmux/rescue.tmux.conf"` line
(it should after chezmoi apply).

**Gotcha to check first:** `tmux source-file` does NOT expand `~`.
A directive like `source-file -q '~/dev/.../rescue.tmux.conf'` (single
quotes, leading tilde) silently fails — the `-q` swallows the error
and every hook stays unset. Use `$HOME` or an absolute path. The
`[tmux-conf]` check in `scripts/validate.sh` scans `~/.tmux.conf` for
this exact pattern.

## 4e. Final re-dump (verify backfill landed in the sidecar)

```bash
bash ~/dev/claude-rescue/scripts/state-dump.sh
LATEST="$(/bin/ls -td ~/claude-rescue-dumps/dump-* | head -1)"
echo "Panes still missing @claude-pane-id:"
awk -F'\t' '$7=="claude" && $9==""' "$LATEST/tmux-panes.tsv" | wc -l
```

Expect `0` (or whatever count of skipped panes you accepted in 4c).
This dump is the manual-restore fallback for step 5.

## 5. Final validation — restart the tmux server

This is the load-bearing step. We deliberately kill the live server so
continuum's auto-restore brings everything back with the new wiring. If
anything is broken (resurrect snapshot stale, wrapper path wrong, hook
ordering off), it surfaces here, not silently later. The dump from
step 4e is your manual-restore fallback.

```bash
# 5a. Force a fresh resurrect snapshot so we restore from current state.
tmux -L default run-shell '~/.config/tmux/plugins/tmux-continuum/scripts/continuum_save.sh'

# Sanity: the snapshot should be seconds old.
ls -lt ~/.local/share/tmux/resurrect/default/ | head -3

# 5b. Detach all attached clients cleanly. (Optional but tidier than
# letting them get evicted by the server kill.)
tmux -L default detach-client -a 2>/dev/null || true

# 5c. Kill the server. The boot wrapper + @continuum-restore in
# ~/.tmux.conf spawn a new server and replay the snapshot.
tmux -L default kill-server

# 5d. Wait a couple seconds. Operator: do NOT attach from inside your
# operator tmux — that nests sockets in confusing ways. Open a new
# terminal on the host (Terminal.app / Ghostty / iTerm) and run:
tmux -L default attach
```

Verify (run from the operator pane against `-L default`, or from the
fresh attached terminal — same result):

- **Pane count matches the dump.** `tmux -L default list-panes -a | wc -l`
  should equal the `tmux-panes.tsv` line count from the step 4e dump.
- **Each pane is in the right cwd.** Cross-check a few rows against
  `restore-plan.tsv`.
- **claude panes restored as `claude-rescue-resume` then handed off to
  claude.** `tmux -L default list-panes -aF '#{pane_current_command}'`
  should show `claude` for the panes that were claude pre-rollout. (A
  transient `claude-rescue-r` or `bash` is normal during the wrapper
  handoff — re-check after ~10s.)
- **`@claude-pane-id` is being minted on new activity.** Type a prompt
  in any claude pane (from the attached terminal). Then:
  ```bash
  ls ~/.cache/claude-rescue/busy/        # should see a fresh marker
  tmux -L default list-panes -aF '#{@claude-pane-id}' | sort -u | head
  ```
- **Hibernation hooks are installed.**
  ```bash
  tmux -L default show-hooks -g | grep -E 'pane-focus-|client-attached|client-session-changed'
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
tmux -L default new-session -d -s <session>  # if session is missing
tmux -L default new-window   -t <session>:<window_idx>
tmux -L default send-keys    -t <session>:<window_idx>.<pane_idx> \
  "cd <cwd> && clr <latest_session_id>" Enter
```

If a pane restored as `claude` but is showing the **wrong session**
(possible for multi-pane cwds where backfill mapped arbitrarily — see
4c), swap it in place. The three backing stores from 4c are your inputs:

```bash
# 1. Confirm what's currently on screen (matches one of the cwd group's
#    transcripts — the resurrect pane_contents.tar.gz preserved the
#    scrollback so visual matching is easy).
tmux -L default capture-pane -t <session>:<window_idx>.<pane_idx> -p | head -40

# 2. Pull the cwd's row group from the step-4e dump's restore-plan.tsv
#    to see which session_ids exist for this cwd.
LATEST="$(/bin/ls -td ~/claude-rescue-dumps/dump-* | head -1)"
awk -F'\t' -v c="<cwd>" '$6==c' "$LATEST/restore-plan.tsv"

# 3. If you need to grep transcript content to identify the right
#    session_id, transcripts are at:
#    ~/.claude/projects/<encoded-cwd>/<session_id>.jsonl
#    (cwd encoding: replace '/' and '.' with '-')

# 4. Resume the correct session in the pane.
tmux -L default send-keys -t <session>:<window_idx>.<pane_idx> \
  "clr <correct_session_id>" Enter
```

No conversations are lost in this scenario — `clr` switches the pane to
the session you actually wanted; the session it was running is still
resumable elsewhere if you need it.

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
tmux -L default source-file ~/.tmux.conf   # re-load live tmux without restart
```

If hibernation is firing destructively in production and you need an
immediate kill switch without a config revert:

```bash
tmux -L default set-hook -gu pane-focus-out
tmux -L default set-hook -gu pane-focus-in
tmux -L default set-hook -gu client-attached
tmux -L default set-hook -gu client-session-changed
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
