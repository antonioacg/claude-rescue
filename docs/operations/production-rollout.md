# Production rollout runbook

End-to-end procedure for cutting a live machine over to a new claude-rescue
release. Written so an operator (human or agent) on a second machine can
replay what was done before.

**The load-bearing step is `tmux -L default kill-server`** in §5. We
deliberately exercise the resurrect + continuum auto-restore path while the
new wiring is live, so any regression surfaces immediately. §5b documents
the recovery path if it doesn't.

> Assumes both repos are pulled to latest `main`, the live tmux server is
> still running the *pre-rollout* config (`chezmoi apply` hasn't run for the
> new commits), and the `~/.local/bin/` symlinks already point at the
> claude-rescue repo. If the symlinks aren't there, run
> `bash ~/dev/claude-rescue/scripts/install.sh --apply` first.

## How the restore path works (one-paragraph mental model)

A claude pane stays resumable across `kill-server` via three durable stores:
**(1)** a `@claude-pane-id` UUID set by `SessionStart` hooks, persisted in
the resurrect sidecar (`tmux_resurrect_*.claude-userops.tsv`), reapplied by
`cmd_resurrect_restore` before tmux-resurrect sends pane processes; **(2)**
an `active/<pane_uuid>` file under `$DATA` that names the currently-loaded
session_id, rewritten by every `SessionStart` (including in-claude `/resume`);
**(3)** claude's own on-disk transcript at
`~/.claude/projects/<encoded-cwd>/<sid>.jsonl`. The `claude-rescue-resume`
wrapper, invoked by tmux-resurrect's `@resurrect-processes` substitution,
reads (1) to find pane_uuid, looks up (2) for the truthful sid, and exec's
`claude -r <sid>`. **It does NOT trust the `-r` flag in the saved
tmux-resurrect cmdline** — that argv is frozen at claude launch and goes
stale on every in-claude `/resume`.

Two sub-systems prevent the chain from breaking:

- `pre-restore-all` + `post-restore-all` hooks create / remove a
  `$resurrect_dir/.restoring` lock file. `scripts/save-guarded.sh` (wired
  via `@resurrect-save-script-path`) bails on any save during restore, so
  tmux-continuum can't capture partial state and rotate `last` to a
  sidecar-less snapshot.
- `cmd_resurrect_restore` does NOT clear `active/<pane_uuid>` files at
  restore time. They survive kill-server keyed by the durable pane_uuid the
  sidecar reapplies. Orphan entries for vanished panes are harmless (wrapper
  only reads by live pane_uuid).

The 2026-05-12 postmortem
([rollout-2026-05-12-postmortem.md](./rollout-2026-05-12-postmortem.md))
covers the bugs each of these mechanisms was added to fix.

---

## On socket assumptions

This runbook **assumes the live tmux server is on the `default` socket**.
Every `tmux ...` call uses an explicit `-L default` so the assumption is
visible at the call site. If your live server uses a different socket name,
find-and-replace `-L default` → `-L <your-socket-name>`, and export
`CLAUDE_RESCUE_LIVE_SOCKET=<your-socket-name>` so the scripts pick it up.

The §5 `tmux -L default kill-server` is the reason for the explicit socket:
if you're driving this runbook from an operator pane inside a *separate*
tmux server (to survive the cutover), bare `tmux kill-server` would kill
the wrong server.

---

## 0. Pre-flight

```bash
cd ~/.local/share/chezmoi  && git pull --ff-only origin main
cd ~/dev/claude-rescue     && git pull --ff-only origin main

echo "chezmoi:       $(cd ~/.local/share/chezmoi && git rev-parse --short HEAD) == $(cd ~/.local/share/chezmoi && git rev-parse --short origin/main)"
echo "claude-rescue: $(cd ~/dev/claude-rescue && git rev-parse --short HEAD)    == $(cd ~/dev/claude-rescue && git rev-parse --short origin/main)"
```

If `git pull --ff-only` refuses (non-fast-forward), STOP and rebase or
investigate — this runbook assumes clean fast-forward state on both repos.

## 1. Capture state

### 1a. State dump (snapshot of layout + processes)

```bash
bash ~/dev/claude-rescue/scripts/state-dump.sh
```

Writes to `${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/dump-<ts>/`.
You'll want this if §5 goes sideways and you need to manually rebuild panes
— `restore-plan.tsv` is the human-readable map.

### 1b. Capture the truthful (pane → session_id) map

**This is the only source of truth for what's actually loaded in each
pane.** The dump's `latest_session_id` column is mtime-based and lies about
`/resume`'d sessions, `--fork-session` panes, and manually-moved jsonls.
Capture the live truth before anything else:

```bash
bash ~/dev/claude-rescue/scripts/capture-truthful-sids.sh \
  -o ~/.local/state/claude-rescue/truthful-sids.tsv

# Inspect:
cat ~/.local/state/claude-rescue/truthful-sids.tsv | column -t -s $'\t' | head
```

Per pane the script reads claude's bottom-status `session_id` line (live)
or falls back to `$DATA/captures/<pane_uuid>.txt` (hibernated). Output
columns:
`session, window_idx, pane_idx, pane_id, pane_uuid, cwd, visible_sid, jsonl_path, jsonl_exists, source`.

**Three things to check:**

```bash
LATEST=~/.local/state/claude-rescue/truthful-sids.tsv
# (a) Every claude pane has a visible sid:
awk -F'\t' 'NR>1 && $7==""' "$LATEST"
# (b) Forked-but-not-flushed sessions (in-memory only, would lose context on kill-server):
awk -F'\t' 'NR>1 && $7!="" && $9=="no"' "$LATEST"
# (c) Counts:
echo "total: $(($(wc -l < "$LATEST") - 1))"
echo "on disk: $(awk -F'\t' 'NR>1 && $9=="yes"' "$LATEST" | wc -l | tr -d ' ')"
```

If (a) shows panes without a sid, they're either at a trust prompt or
something else atypical — note them and decide per-pane in §4c.

**If (b) is non-empty: the affected panes have in-memory state that
kill-server would lose.** Send each a recap-style prompt to force a
transcript flush:

```bash
PROMPT='Please recap what we built in this session and what is left to do, so I can pick it up later.'
for pane in $(awk -F'\t' 'NR>1 && $7!="" && $9=="no"{print $4}' "$LATEST"); do
  tmux -L default send-keys -t "$pane" C-u
  sleep 0.3
  tmux -L default send-keys -l -t "$pane" "$PROMPT"
  sleep 1
  tmux -L default send-keys -t "$pane" Enter
done
# Wait ~60s for claude to respond, then re-run the script to confirm jsonl_exists=yes everywhere.
```

(Note: claude code's input requires the text and `Enter` to be sent in
separate `send-keys` calls with a short delay between them, or `Enter` is
interpreted as a newline within the input box.)

## 2. Validate the code

```bash
cd ~/dev/claude-rescue
bash scripts/validate.sh                 # ~30s, isolated, safe anytime
```

If you want belt-and-suspenders (both destroy staging on exit, ~3+4 min,
don't run during a busy day):

```bash
bash scripts/validate-hibernation.sh
bash scripts/validate-crash-restore.sh
```

## 3. Sanity-check `chezmoi diff`

```bash
chezmoi diff
```

Expected deltas for this rollout family: hook additions in
`~/.claude/settings.json`, `@resurrect-processes` pattern + bind R in
`~/.tmux.conf`, plus whatever your dotfiles happen to ship. Stop and
investigate if anything else surprising appears.

## 4. Apply chezmoi and prep the live server

### 4a. Apply

```bash
chezmoi apply
chezmoi diff   # should be empty for the rollout-relevant files
```

Helper chezmoiscripts under `.chezmoiscripts/` (TPM install, SSH perms,
title patch, post-apply notes) will show in `chezmoi diff` because they're
scripts not target files — that's expected. The dirs they depend on
(`$XDG_CACHE_HOME/claude-rescue/`, `$XDG_DATA_HOME/claude-rescue/`) are
pre-created by `run_before_05-claude-rescue-dirs.sh`.

### 4b. Re-dump state

`recap-missing` or backfill in §4c need a fresh dump after `chezmoi apply`:

```bash
bash ~/dev/claude-rescue/scripts/state-dump.sh
```

### 4c. Backfill `@claude-pane-id`

Backfill mints a `@claude-pane-id` + `@claude-window-id` per claude pane
and writes a `session_start_backfill` event tying each pane_uuid to a
session_id, so the wrapper's find-sessions lookup has something to key on.

**Cross-check against the truthful map.** The default
`backfill-pane-uuids.sh` script picks the Nth-most-recent transcript per
cwd, which is wrong for forked / manually-moved / multi-pane-cwd
scenarios. Compare to the truthful map from §1b:

```bash
bash ~/dev/claude-rescue/scripts/backfill-pane-uuids.sh --dry-run \
  | awk '/^MINT/{
    pane=$2;
    for(i=1;i<=NF;i++) if($i ~ /^sid=/){gsub(/^sid=/,"",$i); print pane"\t"$i; break}
  }' > /tmp/mint-sids.tsv

LATEST=~/.local/state/claude-rescue/truthful-sids.tsv
join -t$'\t' -1 1 -2 1 \
  <(sort -t$'\t' -k1,1 /tmp/mint-sids.tsv) \
  <(awk -F'\t' 'NR>1{print $4"\t"$7}' "$LATEST" | sort -t$'\t' -k1,1) \
  | awk -F'\t' '$2 != $3 {printf "MISMATCH %s: MINT=%s truthful=%s\n", $1, $2, $3}'
```

If the diff is non-empty, the mtime heuristic disagrees with what's
actually loaded. Don't run the real backfill — instead, use the
truthful map as the source of truth. A minimal custom backfill that
writes events from the truthful map directly is sketched in the
2026-05-12 postmortem; for one-off rollouts it's safer than patching
`backfill-pane-uuids.sh`.

If the diff is empty, the heuristic agrees with reality:

```bash
bash ~/dev/claude-rescue/scripts/backfill-pane-uuids.sh
```

The script emits per-pane round-trip checks via `find-sessions`; non-zero
exit means at least one pane failed verification. Investigate before
proceeding.

### 4d. Load the new tmux hooks into the live server

`chezmoi apply` updated `~/.tmux.conf`, but the running server has the
previous in-memory copy.

```bash
tmux -L default source-file ~/.tmux.conf
```

Verify the four hooks + the save-script path are set:

```bash
for h in @resurrect-hook-pre-restore-all @resurrect-hook-pre-restore-pane-processes @resurrect-hook-post-restore-all @resurrect-hook-post-save-layout; do
  printf '%-50s = %s\n' "$h" "$(tmux -L default show-options -gv "$h")"
done
printf '%-50s = %s\n' "@resurrect-save-script-path" "$(tmux -L default show-options -gv @resurrect-save-script-path)"
```

Expected:

```
@resurrect-hook-pre-restore-all                    = claude-rescue-log resurrect-pre-restore-all
@resurrect-hook-pre-restore-pane-processes         = claude-rescue-log resurrect-restore
@resurrect-hook-post-restore-all                   = claude-rescue-log resurrect-post-restore-all
@resurrect-hook-post-save-layout                   = claude-rescue-log resurrect-save "$1"
@resurrect-save-script-path                        = /Users/.../claude-rescue/scripts/save-guarded.sh
```

If any hook returns `invalid option`, the `source-file` didn't load
`rescue.tmux.conf`. The most common cause is a tilde-path `source-file`
directive in `~/.tmux.conf` — tmux does NOT expand `~`. Use `$HOME` or an
absolute path. `scripts/validate.sh`'s `[tmux-conf]` check scans for this.

### 4e. Final re-dump (verify backfill landed in the sidecar)

```bash
bash ~/dev/claude-rescue/scripts/state-dump.sh
LATEST="$(/bin/ls -td ${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/dump-* | head -1)"
echo "Claude panes still missing @claude-pane-id:"
awk -F'\t' '$7=="claude" && $9==""' "$LATEST/tmux-panes.tsv" | wc -l
```

Expect `0` (or the count of skipped panes you accepted in §4c). This dump
is the manual-restore fallback for §5.

### 4f. Rebuild the event log from resurrect snapshots (optional)

If you suspect the event log (`$DATA/windows/*.jsonl`) has accumulated
duplicate title events from older code paths, rebuild it from snapshot
history:

```bash
rm -rf ~/.local/share/claude-rescue/windows/
rm -f  ~/.local/share/claude-rescue/.backfill-done
rm -rf ~/.cache/claude-rescue/tmp/last-pane-state/   # pre-fix dedupe layout

~/.local/bin/claude-rescue-backfill
find ~/.local/share/claude-rescue/windows -name '*.jsonl' | wc -l
du -sh ~/.local/share/claude-rescue/windows
```

What you LOSE: the per-pane `session_start_backfill` events you wrote in
§4c (they're keyed by uuidgen'd pane_uuids the rebuilder doesn't know
about). Re-run §4c's real backfill if you ran 4f after it.

What you DON'T lose: tmux state. `@claude-pane-id` options stay set on
panes, `active/<pane_uuid>` files stay on disk.

## 5. Final validation — restart the tmux server

This is the load-bearing step. If anything is broken (sidecar missing,
wrapper bug, hook ordering off), it surfaces here. §4e's dump is your
manual-restore fallback.

```bash
# 5a. Force a fresh resurrect snapshot.
tmux -L default run-shell '~/.config/tmux/plugins/tmux-continuum/scripts/continuum_save.sh'
sleep 2

# Verify sidecar exists and has rows for every claude pane:
SNAP=$(readlink ~/.local/share/tmux/resurrect/default/last)
SIDE=~/.local/share/tmux/resurrect/default/${SNAP%.txt}.claude-userops.tsv
echo "snap: $SNAP"
echo "sidecar rows: $([ -f "$SIDE" ] && wc -l < "$SIDE" || echo MISSING)"

# 5a'. Clear logs so post-restart traces are isolated.
: > ~/.local/share/claude-rescue/wrapper.log
: > ~/.cache/claude-rescue/rescue-log.err

# 5b. Detach attached clients (tidier than letting them get evicted).
tmux -L default detach-client -a 2>/dev/null || true

# 5c. Kill the server.
tmux -L default kill-server

# 5d. Bootstrap a new server so continuum-restore fires. Operator: do NOT
# attach from inside your operator tmux — open a new terminal on the host
# (Terminal.app / Ghostty / iTerm) and run `tmux -L default attach`. For
# verification you can use this detached probe from anywhere:
tmux -L default new-session -d -s _probe
sleep 8
```

### Verify

```bash
# Pane count matches the §4e dump:
tmux -L default list-panes -a | wc -l

# Claude pane count matches the truthful map:
EXPECTED=$(($(wc -l < ~/.local/state/claude-rescue/truthful-sids.tsv) - 1))
ACTUAL=$(tmux -L default list-panes -aF '#{pane_current_command}' | grep -c '^claude$')
echo "$ACTUAL / $EXPECTED claude panes"

# Wrapper observability (should both equal claude-pane count):
echo "invoked:  $(grep -c 'invoked pid='  ~/.local/share/claude-rescue/wrapper.log)"
echo "resolved: $(grep -c 'resolved pid=' ~/.local/share/claude-rescue/wrapper.log)"

# Restore hook trace:
grep 'resurrect-' ~/.cache/claude-rescue/rescue-log.err
# Expect:
#   resurrect-pre-restore-all: created lock at .../.restoring
#   resurrect-restore: hook fired
#   resurrect-restore: snapshot=<...>.txt sidecar_rows=<2N>
#   resurrect-restore: applied window=N pane=N skipped=0
#   resurrect-post-restore-all: removed lock at .../.restoring

# Resolution-priority histogram. Healthy: most/all P1-active.
grep 'resolved' ~/.local/share/claude-rescue/wrapper.log \
  | awk '{
    for (i=1;i<=NF;i++) {
      if ($i ~ /^active_sid=/) a=$i
      if ($i ~ /^find_sessions_sid=/) f=$i
    }
    if (a !~ /^active_sid=$/) print "P1-active"
    else if (f !~ /^find_sessions_sid=$/) print "P2-find-sessions"
    else print "P4-fresh"
  }' | sort | uniq -c

# Verify each pane resumed the right truthful sid (process-tree check):
fail=0
while IFS=$'\t' read -r _ _ _ pane_id _ _ sid _ _ _; do
  shell_pid=$(tmux -L default display -t "$pane_id" -p '#{pane_pid}' 2>/dev/null) || continue
  claude_pid=$(pgrep -P "$shell_pid" 2>/dev/null | head -1)
  argv=$(ps -o args= -p "$claude_pid" 2>/dev/null)
  echo "$argv" | grep -q -- "-r $sid" || { echo "FAIL $pane_id expected $sid"; fail=$((fail+1)); }
done < <(awk 'NR>1' ~/.local/state/claude-rescue/truthful-sids.tsv)
echo "fail count: $fail"
```

### 5b. If panes came back as zsh instead of claude

This is the historical 2026-05-11 failure mode (send-keys race). On
2026-05-12 we identified the root cause as continuum-save racing the
restore — fixed via the `.restoring` lock pattern. If you still see this
in 2026-05-12+ code, something deeper has regressed; investigate before
recovering.

**Recovery using the truthful map:**

```bash
LATEST=~/.local/state/claude-rescue/truthful-sids.tsv

# Send `clr <truthful_sid>` to each pane whose live cmd is zsh/bash but
# truthful map says should be claude.
awk -F'\t' 'NR>1{print $1"\t"$2"\t"$3"\t"$7}' "$LATEST" \
  | while IFS=$'\t' read -r sess win pane sid; do
      target="$sess:$win.$pane"
      cmd=$(tmux -L default display -t "$target" -p '#{pane_current_command}' 2>/dev/null) || continue
      if [[ "$cmd" == "zsh" || "$cmd" == "bash" ]]; then
        echo "  SEND $target → clr $sid"
        tmux -L default send-keys -t "$target" "clr $sid" Enter
        sleep 0.25   # inter-pane delay; avoids the same race as the original restore
      fi
    done
```

`scripts/restore-zsh-to-claude.sh` does roughly this but reads
`@claude-pane-id` → `find-sessions` for the sid. If the failure was a
sidecar miss, `@claude-pane-id` is unset on the affected panes and that
script won't recover them — the truthful-map version above is the
robust path.

## 6. Watch the system for ~10 minutes

Several hooks fire in the first minutes; check none of them are loud.

```bash
# arm-sweep fires on the next attach / session-switch — every claude pane
# gets an arm.pid file (idempotent, skips already-armed):
ls ~/.cache/claude-rescue/hibernated/*.arm.pid | wc -l

# active/ tracks SessionStart writes from the first prompt in each pane:
ls ~/.local/share/claude-rescue/active | wc -l

# Event log grows sanely, not explosively:
wc -l ~/.local/share/claude-rescue/windows/*.jsonl | tail -1

# Pre-fix dedupe layout must NOT exist:
ls ~/.cache/claude-rescue/tmp/last-pane-state/ 2>&1 | head -1
# Expect: "No such file or directory"

# rescue-log.err and hibernate.err should be quiet (only the recent restore
# trace from §5):
tail -n 30 ~/.cache/claude-rescue/rescue-log.err
tail -n 30 ~/.cache/claude-rescue/hibernate.err
```

**Regression signal**: many byte-identical title events in one
`windows/*.jsonl` within a short window. The new snapshot-diff produces
zero duplicates when working correctly. Re-appearance of
`~/.cache/claude-rescue/tmp/last-pane-state/` is also a regression — that
directory was the pre-fix dedupe layout and the new code doesn't create it.

## 7. Rollback (only if §5 / §6 reveals a real problem)

Code rollback is fast (symlinks point at the repo):

```bash
cd ~/dev/claude-rescue
git checkout <prior-good-sha>
```

Config rollback:

```bash
cd ~/.local/share/chezmoi
git revert <merge-or-feat-commit>
chezmoi apply
tmux -L default source-file ~/.tmux.conf   # re-load without restart
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
  is empty (pre-rename leftover): `rmdir ~/.claude-rescue/stopped 2>/dev/null || true`.
- Keep state dumps for a few days, then delete:
  `rm -rf ${XDG_STATE_HOME:-~/.local/state}/claude-rescue/dumps/dump-<ts>`.
- **Resurrect snapshot dir cleanup** — tmux-resurrect's built-in rotation
  (`@resurrect-delete-backup-after`) breaks past ~6000 `.txt` files
  ("argument list too long"). With `@continuum-save-interval=1` the dir
  hits this scale in under a week.

  Auto-runs from `__rescue_archive_save` on the same 1-hour throttle as
  the archive prune. Defaults: keep newest 2000 (tune via
  `CLAUDE_RESCUE_HOT_KEEP`). The archive tier's hardlinks preserve any
  inode dropped here, so eviction is information-preserving — only the
  resurrect-loadable surface shrinks.

  Manual invocation (dry-run / one-shot override / different `--dir`):

  ```bash
  bash ~/dev/claude-rescue/scripts/cleanup-resurrect-snapshots.sh --dry-run
  bash ~/dev/claude-rescue/scripts/cleanup-resurrect-snapshots.sh --keep 2000
  ```

  The script uses `find` (no glob), preserves the `last` symlink target,
  and removes paired `.claude-userops.tsv` sidecars alongside their
  `.txt` snapshots.

- **Orphan `active/` files** — if a previous failed restore minted fresh
  `@claude-pane-id` UUIDs (sidecar miss), the old UUIDs' `active/` files
  become orphans. Harmless but cluttery. One-time sweep:

  ```bash
  comm -13 \
    <(tmux -L default list-panes -aF '#{@claude-pane-id}' | awk 'NF' | sort -u) \
    <(/bin/ls ~/.local/share/claude-rescue/active | sort -u) \
  | while read p; do rm "$HOME/.local/share/claude-rescue/active/$p"; done
  ```

---

## Related reading

- [`rollout-2026-05-11-postmortem.md`](./rollout-2026-05-11-postmortem.md)
  — First production rollout. `send-keys` race, find-sessions encoding,
  tilde-path source-file bug, wrapper empty-array crash.
- [`rollout-2026-05-12-postmortem.md`](./rollout-2026-05-12-postmortem.md)
  — Second rollout on the same machine. Snapshot race (continuum-save
  during restore), wrapper P3 fallback bug, active/ bulk-clear bug, five
  patches that make the restore path durable. **Recommended reading
  before doing this rollout on another machine.**
- [`hibernation.md`](./hibernation.md) — soft/hard pane suspension model,
  env vars, manual test recipes.
- [`crash-recovery.md`](./crash-recovery.md) — what survives a tmux crash
  and what's reborn.

## What this runbook does NOT cover

- Initial install on a fresh machine — chezmoi's bootstrap path handles it.
- Building or shipping new feature work — see the repo README + ops dev loop.
- Day-2 operations (watching logs, picker UX) — see the other docs in this
  directory.
