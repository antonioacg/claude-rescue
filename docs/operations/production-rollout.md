# Production rollout runbook

End-to-end procedure for cutting over a live machine to the
hibernation-capable claude-rescue. Written so the operator (human or
agent) on a second machine can replay what was done on the first machine.

**Final validation step is `tmux kill-server`** — we deliberately exercise
the resurrect+continuum auto-restore path while the new wiring is live, so
any regression in restore behavior shows up immediately. The state-dump
captured in step 1 is the manual fallback for that step. Step 4f
(rebuild event log from snapshots) runs immediately before, giving the
post-restore observability check a clean baseline to read against.

> Assumes the machine starts in the same shape as the first Mac at rollout
> time: chezmoi `feat/claude-rescue-prod-deploy` checked out (or merged to
> main), claude-rescue `feat/hook-driven-identity` checked out (or merged
> to main), live tmux server has the *pre-rollout* config loaded, symlinks
> in `~/.local/bin/` already point at the repo.
>
> **What `feat/hook-driven-identity` ships** (for a second Mac that's still
> on `main`, all of this lands together when the branch merges):
> - **Hibernation + capture/print** — soft (Ctrl+Z) and hard (`/exit`) pane
>   suspension, focus-driven arm-sweep, scrollback capture at hibernate time.
> - **Hook-driven identity** — `$DATA/active/<pane_uuid>` holds the current
>   `session_id`, written by every SessionStart, removed by SessionEnd /
>   pane_died / arm-sweep voluntary-exit. Wrapper's priority-1 resume target.
> - **arm.pid lifecycle reaper** — `cmd_session_end` reaps `arm.pid` + active
>   file up front; `cmd_arm_sweep` detects voluntary-exit (pane with
>   `@claude-pane-id` but no claude / no busy / no hibernation marker) and
>   cleans the state automatically on next attach. Fixes the "27 orphan
>   arm.pids after dialog-dismiss" failure mode.
> - **Snapshot-diff unification** — live title sampling and the backfill now
>   share one code path (snapshot-diff over `tmux_resurrect_*.txt`). No more
>   per-pane filesystem dedupe state, no cross-server cache collision. Step
>   4f rebuilds the event log from scratch off this single source of truth.

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

Writes to `${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/dump-<ts>/`. Files you'll care about if
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
`${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/`.

After it runs, give claudes ~30s to respond. The recaps land as new
messages in their `.jsonl` files.

## 2. Validate the code on this machine

Quick gate (~30s, isolated, safe anytime):

```bash
cd ~/dev/claude-rescue
bash scripts/validate.sh                 # 31 assertions / 12 scenarios
```

If that passes and you want belt-and-suspenders:

```bash
bash scripts/validate-hibernation.sh     # ~3 min, rebuilds staging, 57 assertions / 9 scenarios
bash scripts/validate-crash-restore.sh   # ~4 min, rebuilds staging, 31 assertions / 4 scenarios
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
- `~/.tmux.conf` — `bind R run-shell "claude-rescue"` added so `prefix + R`
  opens the session picker (matching the bind staging.sh wires for the
  staging server).
- Other deltas your dotfiles happen to have. Inspect; nothing unexpected
  should be in the diff scoped to this rollout.

> **If the second Mac's chezmoi is currently on `main`** (it was at the
> time of the 2026-05-11 rollout on the first Mac), all five claude-rescue
> chezmoi commits — `d82388b` (swap claude-restore → claude-rescue-resume
> + hook order), `b12e2e2` (busy hooks wiring), `0493fc5` (drop tilde from
> @resurrect-processes), `28911fd` (source-file path: `$HOME` not `~`),
> `5918531` (picker keybind) — all ship together when this Mac merges
> `feat/claude-rescue-prod-deploy`. Don't cherry-pick subsets.

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
LATEST="$(/bin/ls -td ${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/dump-* | head -1)"
awk -F'\t' 'NR>1 && $7==""' "$LATEST/restore-plan.tsv"
```

Output should be empty (or only show panes you knowingly chose not to
recap). If anything you care about is still empty, return to step 1b
before continuing.

## 4c. Backfill @claude-pane-id for panes lacking one

**Why this step exists.** `claude-rescue-resume`, the wrapper that runs
in each restored pane after kill-server, resolves the resume target via
this priority:

1. `$DATA/active/<pane_uuid>` — written by every SessionStart, holds the
   current `session_id`. Cleared at `cmd_resurrect_restore` time so
   freshly-restored panes don't carry stale entries — repopulated as
   each restored claude fires its first SessionStart.
2. `@claude-pane-id` on the pane → `find-sessions` lookup over the event
   log → `-r <session_id>` (the durable fallback when active was cleared
   by SessionEnd / restore / never written).
3. Else: existing `-r <UUID>` parsed from the saved command line.
4. Else: no `-r` → claude starts a fresh session.

Right after kill-server, priority (1) is empty by design (the dir was
bulk-cleared at restore). Resolution flows through (2), which is exactly
what the backfill below sets up: a `@claude-pane-id` that `find-sessions`
can match against an event-log entry that maps to a transcript on disk.

If your live server has a mix of older claude panes that never had
`@claude-pane-id` minted (pre-rollout SessionStart events didn't write
one), AND those panes were originally launched fresh (no `-r` in their
saved tmux-resurrect command), they fall through to (4) and lose
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

**Pre-run sanity check — backfill collision with active claudes.**
Inspect the dry-run MINT output for any sid that's currently in use by
another running claude process (e.g., the operator-claude itself, or a
claude running outside the live tmux server):

```bash
# List sids of currently-running claude processes (from launch argv):
ps -A -o command 2>/dev/null | grep -oE '\-r [0-9a-f-]{36}' \
  | sort -u | awk '{print $2}'
```

If any of those sids appear in MINT lines, the affected panes would
end up trying to resume a session that's actively running in another
process. Two claude processes writing the same on-disk transcript
corrupts both. Either:

- Skip those panes (kill them post-restart with `tmux kill-pane`), or
- Edit the dump's `restore-plan.tsv` to remove those rows before
  running the real backfill.

This is most likely to bite when (a) the rollout operator-claude lives
in the same cwd as a backfill target, AND (b) the cwd has a thin
transcript pool — the Nth-most-recent heuristic falls back to the
operator's own most-recent jsonl as the "best available" for
neighboring panes. Caught on the 2026-05-11 rollout (2 panes mapped to
the rollout operator's own session).

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

**Don't expect `arm.pid` files to appear immediately after source-file.**
`arm-sweep` is bound to `client-attached` and `client-session-changed`,
neither of which fires on `source-file` alone. A dump taken right after
the source-file will typically show `_*.arm.pid` count of 1 (the
currently-focused-out pane), not N. Coverage of all running claude
panes kicks in on the next attach — which the step-5 kill-server +
reattach cycle provides naturally. See
[hibernation.md → arm-sweep firing model](./hibernation.md) for the model.

## 4e. Final re-dump (verify backfill landed in the sidecar)

```bash
bash ~/dev/claude-rescue/scripts/state-dump.sh
LATEST="$(/bin/ls -td ${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/dump-* | head -1)"
echo "Panes still missing @claude-pane-id:"
awk -F'\t' '$7=="claude" && $9==""' "$LATEST/tmux-panes.tsv" | wc -l
```

Expect `0` (or whatever count of skipped panes you accepted in 4c).
This dump is the manual-restore fallback for step 5.

## 4f. Rebuild the event log from resurrect snapshots

Why this step exists: as of the snapshot-diff unification, live title
sampling and `claude-rescue-backfill` share the same code path
(snapshot-diff over `tmux_resurrect_*.txt`). The prior implementation
kept a `.last` dedupe file per pane under
`$CACHE/tmp/last-pane-state/_<N>.last`, keyed only by sanitized `%N`. Any
second tmux server on the same machine (staging, a per-task operator
server, an old detached `tmux -L something-else`) raced with the main
server for the same file, and both emitted title events every save tick
even on completely stable panes. The polluted event log can be 50–200×
the volume it should be, with multi-event-per-minute spam in long-lived
windows. Operator on the first rollout observed it as ~480 identical-title
events per session in the picker preview.

Rebuilding from snapshots gives a clean baseline. The snapshot files are
the source of truth (they're what would be replayed on restore), and
`claude-rescue-backfill` walks them with the same dedupe algorithm the
live code uses going forward. Doing this before kill-server means
step 5's verify pass reads a clean event log.

```bash
# 1. Wipe the polluted event logs.
rm -rf ~/.local/share/claude-rescue/windows/

# 2. Reset the backfill marker so it processes every snapshot.
rm -f ~/.local/share/claude-rescue/.backfill-done

# 3. Drop the now-unused last-pane-state cache (the pre-fix dedupe layout).
rm -rf ~/.cache/claude-rescue/tmp/last-pane-state/

# 4. Rebuild from the default server's snapshot history.
~/.local/bin/claude-rescue-backfill

# 5. Sanity: window count + total size are both modest, marker is fresh.
find ~/.local/share/claude-rescue/windows -name '*.jsonl' | wc -l
du -sh ~/.local/share/claude-rescue/windows
cat ~/.local/share/claude-rescue/.backfill-done

# 6. Picker spot-check (no popup needed):
~/.local/bin/claude-rescue list-windows | head -5
```

Expect: window count in the dozens (one window per `(session_name, cwd)`
that ever appeared in a saved snapshot), total size in the low hundreds
of KB, marker set to the timestamp of the newest snapshot processed (so
"now-ish" only if the live server has saved a snapshot recently). Each
row from `list-windows` should have a plausible `cwd` and a `last_title`
that reads like a real claude task.

**If you also want history from non-`default` resurrect dirs** (e.g. a
long-running staging server with meaningful sessions), re-run pointing
at each one. **Reset the marker before each subsequent run** —
snapshot timestamps are absolute wall-clock, so after the first run's
marker is set to `default`'s newest, all of `staging`'s older snapshots
would be silently filtered out:

```bash
rm -f ~/.local/share/claude-rescue/.backfill-done
CLAUDE_RESCUE_RESURRECT_DIR=~/.local/share/tmux/resurrect/staging \
  ~/.local/bin/claude-rescue-backfill
```

What this step doesn't do: nothing here touches live tmux state. The
@claude-pane-id options from step 4c stay put, and any active claude
session that emits a `session_start` event after this point gets a
fresh real-uuid window log alongside the `bf-<hash>` ones from backfill.

What you lose vs. the old log: discrete `session_start` / `session_end`
events from Claude Code hooks (replaced by `session_start_backfill`
events derived from `-r <sid>` flags in saved cmdlines), and exact
source attribution (`startup` / `resume` / `clear` / `compact`). The
picker treats both kinds equivalently, so this is invisible in normal
use. The wins are 50–200× fewer events to scroll, a single dedupe
algorithm to reason about, and correct counts in window previews.

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

# 5a'. Clear the observability logs so the redo's traces are
# isolated from any pre-rollout content. NOT optional — if you skip
# this and need to diagnose a failure, you'll be reading mixed history.
: > ~/.local/share/claude-rescue/wrapper.log
: > ~/.cache/claude-rescue/rescue-log.err

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

### Observability surfaces (read these post-restore)

Two log files capture what actually happened during the restore. Both
are critical for diagnosing failures and should be read together:

- **`~/.local/share/claude-rescue/wrapper.log`** — every
  `claude-rescue-resume` invocation appends 2 lines: one "invoked" on
  entry (pid, ppid, pane, argc, full argv), one "resolved" before exec
  (pane_uuid, find_sessions_sid, saved_uuid, target). For a healthy
  restore of N claude panes, expect N "invoked" + N "resolved" lines.

  ```bash
  echo "invoked: $(grep -c 'invoked pid=' ~/.local/share/claude-rescue/wrapper.log)"
  echo "resolved: $(grep -c 'resolved pid=' ~/.local/share/claude-rescue/wrapper.log)"
  ```

  If invoked < N: tmux-resurrect's send-keys didn't reach every saved
  claude pane. **Go to section 5b for the recovery procedure.**
  If invoked == N but resolved < N: some wrappers crashed before
  exec. Inspect the trailing lines of each "invoked" without a
  matching "resolved" — likely a wrapper bug.

- **`~/.cache/claude-rescue/rescue-log.err`** — `claude-rescue-log`'s
  `cmd_resurrect_restore` logs hook fire, snapshot name, sidecar row
  count, per-set-option outcome, and final tallies (applied/skipped
  per window+pane). Expect one block per restore.

  ```bash
  cat ~/.cache/claude-rescue/rescue-log.err
  ```

  Expected pattern:
  ```
  resurrect-restore: hook fired (TMUX=...)
  resurrect-restore: snapshot=tmux_resurrect_<ts>.txt sidecar_rows=<2N-1>
  resurrect-restore: applied window=<N> pane=<N> skipped=0
  ```

  If the hook didn't fire at all, the pre-restore-pane-processes
  setup is broken. Check `tmux -L default show-options -gv
  @resurrect-hook-pre-restore-pane-processes` returns the handler
  name (back to step 4d if `invalid option`).

- **`~/.local/share/claude-rescue/active/`** — one file per claude
  pane, named after `@claude-pane-id`, contents = current claude
  `session_id`. Bulk-cleared at `cmd_resurrect_restore` (entries
  belonged to the dying server) and repopulated as each restored
  claude fires SessionStart. A healthy restore of N claude panes
  ends with `find ~/.local/share/claude-rescue/active -type f |
  wc -l` ≈ N (give it ~10s after attach for late SessionStarts).
  If significantly less, some panes never reached SessionStart —
  same diagnostic path as wrapper.log < N "invoked" lines.

### Verify (run from any attached terminal)

Run from the operator pane against `-L default`, or from the fresh
attached terminal — same result:

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
  tail -n 50 ~/.cache/claude-rescue/rescue-log.err 2>/dev/null
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
LATEST="$(/bin/ls -td ${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/dump-* | head -1)"
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

### 5b. If panes restored but came back as `zsh` instead of `claude`

This is the failure mode observed during the 2026-05-11 rollout: `tmux
list-panes` shows panes back in their right cwds, but most are running
`zsh` instead of `claude`. `wrapper.log` shows few or zero "invoked"
lines — the wrapper send-keys phase didn't reach those panes.

The conversations are still resumable: `@claude-pane-id` is preserved
on each pane (the sidecar reapply hook landed at restore time, even if
send-keys later didn't), and `find-sessions` returns the right session
for each. Use the recovery script:

```bash
# Dry-run first to see what it would do.
bash ~/dev/claude-rescue/scripts/restore-zsh-to-claude.sh --dry-run

# Sanity-check the (pane → sid) mapping. Critically: if any sid in
# the SEND list collides with a sid CURRENTLY ACTIVE in another claude
# (e.g., the rollout operator-claude's own session), do NOT recover
# that pane — two claude processes writing the same on-disk transcript
# corrupts both. Identify in-use sids:
ps -A -o command 2>/dev/null | grep -oE '\-r [0-9a-f-]{36}' | sort -u

# If the dry-run output is sane, run for real. The script enforces a
# 250ms inter-pane delay (CLAUDE_RESCUE_RESTORE_DELAY) so subsequent
# `clr` invocations don't suffer the same race that broke the original
# restore.
bash ~/dev/claude-rescue/scripts/restore-zsh-to-claude.sh
```

After running, each recovered pane lands on claude's "Resume from
summary?" dialog (claude detects the resumed transcript is old/large
and prompts before continuing). You'll need to press `1` or `2` per
pane to actually use them — or leave them dormant, your call.

**Important caveats**:

- **Recovery is a manual emergency tool, NOT a retry hook**. The
  script isn't wired into any tmux hook. If you find yourself reaching
  for it, the underlying failure deserves investigation (check
  `wrapper.log` for invocation count first — if it's 0 or very low,
  something in the restore path is dropping send-keys; if it matches
  pane count, the wrappers ran but exited fast, look at their
  resolution decisions).
- **Continuum keeps saving the broken state** at its
  `@continuum-save-interval` (default 1 minute). Every minute that
  passes after a failed restore narrows the recovery window:
  subsequent saves capture `pane_full_command=":"` for the zsh panes,
  and the `last` snapshot rotates forward. **Recover fast** or risk
  losing the saved-as-claude commands from the restore-input snapshot.
  Don't wait around debugging while continuum eats your safety net.
- **Backfill collision check** — if `restore-plan.tsv` assigned the
  same sid to multiple panes (thin transcript pool in a cwd, or the
  operator's own session is the latest), the script will SEND `clr
  <sid>` to all of them. Pick one to inherit; kill the rest with
  `tmux -L default kill-pane -t <pane_id>`. Backfilling distinct sids
  doesn't help if there aren't enough transcripts available.

## 6. Watch the system for ~10 minutes

The first soft hibernation can't fire for an hour (default 3600s), but
several other code paths run in the first minutes:

- `arm-sweep` fires on `client-attached` — every claude pane should get an
  arm.pid file: `ls ~/.cache/claude-rescue/hibernated/_*.arm.pid`. Expect
  one per backgrounded claude pane. The same sweep also exercises the
  voluntary-exit branch: any pane that has `@claude-pane-id` but isn't
  running claude (no busy / no hibernation marker) gets its arm.pid +
  active file + `@claude-pane-id` cleared. Pre-rollout orphan arm.pids
  (from claudes that exited via "Resume from summary?" dialog dismiss)
  drain here.
- `SessionStart` fires on the next claude prompt — `$DATA/active/<pane_uuid>`
  populates with the current session_id. After ~5 minutes of normal use,
  `find ~/.local/share/claude-rescue/active -type f | wc -l` should
  approach the count of currently-running claude panes.
- Claude hooks fire on the next prompt — busy markers appear under
  `~/.cache/claude-rescue/busy/` and refresh on each tool call.
- `client-session-changed` fires when you switch sessions — should be a
  no-op for already-armed panes.
- **Event log grows sanely**, not explosively. Right after step 4f the log
  is a clean baseline (counts captured then). Snapshot 10 min later:

  ```bash
  wc -l ~/.local/share/claude-rescue/windows/*.jsonl | tail -1
  ```

  Expected pattern: a `session_start` per fresh claude session (every
  `startup` / `resume` / `clear` / `compact`), one `title` event whenever
  a pane's saved `pane_title` byte-differs from the previous snapshot's
  (claude's status glyph plus task description). Idle panes whose
  scrollback is unchanged produce zero events — tmux-resurrect's
  `cmp -s` against `last` deletes the byte-identical new snapshot, so
  the next snapshot diffs against an older surviving one with the same
  title and emits nothing. Actively-spinning panes whose status glyph
  cycles (`✳ → ⠐ → ⠂`) will emit one title event per save tick they're
  spinning; this is correct, not noise.

  **The regression signal is**: many *byte-identical* events emitted for
  the same `(pane_uuid, title)` pair within a short window (look for
  consecutive same-content rows in any one `windows/*.jsonl`). That's
  the pre-fix shape — snapshot-diff doesn't produce duplicates when
  working correctly. Also confirm
  `~/.cache/claude-rescue/tmp/last-pane-state/` does **not** exist —
  that directory was the pre-fix dedupe layout and the new code doesn't
  create it. Re-appearance is a regression signal.

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
  `rm -rf ${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/dump-<ts>`.
- **Resurrect snapshot dir**: tmux-resurrect's built-in rotation
  (`@resurrect-delete-backup-after`) breaks once the dir exceeds ~6000
  `.txt` files — the upstream cleanup uses a shell glob that hits
  "argument list too long". Symptom: rotation silently stops, the dir
  grows unboundedly. With `@continuum-save-interval=1` the dir hits
  this scale in under a week. Run periodically (e.g. weekly):

  ```bash
  bash ~/dev/claude-rescue/scripts/cleanup-resurrect-snapshots.sh --dry-run   # preview
  bash ~/dev/claude-rescue/scripts/cleanup-resurrect-snapshots.sh             # keep newest 200
  ```

  The script uses `find` (no glob), keeps the newest N (default 200,
  ~3h worth at 1-min interval), preserves the `last` symlink target
  unconditionally, and removes paired `.claude-userops.tsv` sidecars
  alongside their `.txt` snapshots. Tune `--keep` to taste.

---

## Related reading

- [`rollout-2026-05-11-postmortem.md`](./rollout-2026-05-11-postmortem.md)
  — the first machine's rollout. Captures what actually went wrong, what
  was unproven, and which bugs got caught during the rollout itself
  (find-sessions encoding, source-file tilde expansion, wrapper empty
  `rebuilt[@]` array). Recommended reading before doing the rollout on
  any subsequent machine: the failure modes are real, the recovery
  paths in this runbook were forged through them.

## What this runbook does *not* cover

- Initial install on a fresh machine — that's chezmoi's bootstrap path.
- Building or shipping new feature work — see
  [README.md](./README.md) for the dev loop.
- Day-2 operations (watching logs, picker UX) — see the other docs in
  this directory.
