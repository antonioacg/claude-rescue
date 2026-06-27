# RCA — 2026-06-05 restore keystroke race (garbled `clr` resume)

**Severity:** high (data-loss-adjacent — every hard-hibernated claude
session failed to auto-resume; recovery required manual per-pane
intervention).
**Incident restore:** 2026-06-05T18:32:53–18:33:22Z (a real macOS crash
→ tmux server death → continuum auto-restore on next attach).
**Detected:** 2026-06-16, when the operator returned to the stack and
found ~all hibernated claude panes stuck at a resume picker or
"trust this folder?" prompt, none in the right working directory.
**Recovered:** 2026-06-16, 23 sessions restored by hand (kill the
garbled claude by exact PID → clear the prompt line → re-run
`cd <correct-cwd> && clr <sid>`). Zero session transcripts lost.

This is **not** the snapshot race from the
[2026-05-12 postmortem](rollout-2026-05-12-postmortem.md). That one was
fixed and held. This is a *different* bug in the same
`cmd_resurrect_post_restore_all` function — its post-restore UX path
(print snapshot + pre-fill `clr <sid>`) is **not idempotent**, and the
restore that fired it ran **twice concurrently**.

---

## Symptom

On 2026-06-16 the operator surveyed 60 panes. ~23 claude panes were in
one of three broken states, all in the wrong cwd (`~` instead of their
project dir):

1. **claude `--resume` picker** with a garbled search string, e.g.
   `9016e495-b9ec-4cdf-9f7f-d3ad77a7a4dfclaude-rescue` → "No sessions
   match."
2. **"trust this folder?" prompt** for `/Users/antoniocasagrande`
   (claude relaunched fresh in home).
3. Process args showed the tell: `claude … -r <sid>claude-rescue print`
   — the session UUID had the literal text `claude-rescue` mashed onto
   it with no separator, plus a stray `print` argument.

The session UUID was always recoverable (visible in the prompt /
process args), and every session's transcript was intact on disk. The
failure was purely in the *resume invocation*, not the data.

---

## Root cause

### Primary — non-idempotent post-restore keystrokes, fired twice

`cmd_resurrect_post_restore_all` (`bin/claude-rescue-log`, the block
under "Post-restore UX") backgrounds a subshell that, after a 5 s
sleep, walks every pane and for each hard-hibernated one sends **two
keystroke bursts**:

```
send_keys_logged "post-restore-print" "$pane_id" "claude-rescue print" Enter
sleep 0.5
send_keys_logged "post-restore-clr"   "$pane_id" "clr $sid"        # no Enter
```

The intent: run `claude-rescue print` to repaint the captured
snapshot, then **pre-fill** `clr <sid>` at the shell prompt so the
operator resumes with one keystroke. The `clr <sid>` deliberately has
no trailing Enter — it is live readline input the user reviews.

That design is only safe if the path runs **exactly once** per pane.
It ran twice. The authoritative `send-keys.log` for the 2026-06-05
restore shows **52 `post-restore-print` + 52 `post-restore-clr`
entries across 26 panes — exactly 2× each**, interleaved in two
drifting passes. Two concurrent subshells were blasting the same panes.

Traced for one pane (old server id `%17`, session
`b225177c-affd-48af-87c4-ec8f3a6d657d`):

```
18:33:05 post-restore-print %17 cur_cmd=zsh    keys=claude-rescue print Enter   # pass A: executes `claude-rescue print` at the shell
18:33:05 post-restore-clr   %17 cur_cmd=zsh    keys=clr b225177c                # pass A: pre-fills `clr b225177c` (NO Enter). readline buffer = "clr b225177c"
18:33:06 post-restore-print %17 cur_cmd=zsh    keys=claude-rescue print Enter   # pass B: APPENDS to the un-executed buffer → "clr b225177cclaude-rescue print" + Enter → EXECUTES
18:33:07 post-restore-clr   %17 cur_cmd=claude keys=clr b225177c                # pass B: sends `clr b225177c` into the now-running (garbled) claude's input box
```

The `cur_cmd` transition `zsh → zsh → claude` and `claudes_in_subtree`
`0 → 0 → 1` confirm the third line is where a claude process spawned —
from executing the concatenation `clr b225177cclaude-rescue print`.
Expanding the `clr` alias (`cl -r` → `claude … -r`):

```
clr b225177cclaude-rescue print
  → claude --add-dir /** --permission-mode bypassPermissions … -r b225177cclaude-rescue print
       │                                                            └─ invalid session id ──┘ └ stray arg
       └─ launches, can't find session "b225177cclaude-rescue" → falls back to interactive picker
```

The same `zsh→…→claude` double-pass signature appears for every
affected pane in the cluster (`%8 %9 %14 %17 %18 %19 %20 %21 %27 %28
%29 %31 %38 %43 %45 %49 %50 %52 %53`, …).

**Why it fired twice — two restore triggers.** `dot_tmux.conf` arms
restore on boot two independent ways:

- line 182: `set -g @continuum-restore 'on'` — tmux-continuum's own
  auto-restore runs when TPM loads the plugin (`run tpm`) and it sees
  no sessions.
- lines 227–228: a boot guard that *also* runs
  `~/.config/tmux/scripts/restore-wrapper.sh`, which calls
  tmux-resurrect's `restore.sh` directly.

Each restore fires `@resurrect-hook-post-restore-all` →
`cmd_resurrect_post_restore_all` → one backgrounded keystroke subshell.
Two restores within the 5 s sleep window → two subshells awake at once
→ the interleaved double-send above. (The guard at line 227 was meant
to *force* restore on multi-server setups; it was never reconciled with
continuum's built-in restore also being `on`, so both run.)

### Compounding — restored panes landed in `~`, not their project cwd

Even a *clean* `clr <sid>` would have failed here. The `clr`/`cl` alias
runs `claude` in `$PWD`; claude resolves `--resume <sid>` against the
project dir that encodes the **launch cwd**
(`~/.claude/projects/<encoded-cwd>/<sid>.jsonl`). The broken panes were
in `/Users/antoniocasagrande` (home), where no session matches.

The tmux-resurrect snapshot **did** save the correct cwd — the pane
line for the affected window carries field 7 =
`:/Users/antoniocasagrande/git/platform-mcpg-ucs` — so this was not a
save defect. The home landing is collateral from the same double
restore: two restores racing to build the same named sessions produce
duplicate/extra panes, some spawned as bare default shells in `$HOME`
rather than restored-in-place with their saved dir. Corroboration: the
log shows several panes with `cur_cmd=bash` at restore time, though the
operator's login shell is `zsh` — i.e. those panes were *not* the
normal "resurrect spawns the saved shell in the saved dir" path. The
post-restore keystrokes then fired `clr <sid>` in those home-cwd panes.

### Contributing — `claude-rescue print` cwd is the *last active* path

During recovery, `claude-rescue print <pane_uuid>` was used to recover
each session id and cwd. Its `cwd:` header is the **last active path at
capture time**, not the launch dir. For one session
(`d61750c1`, 3 transcript copies across worktrees, one in a now-deleted
dir) trusting it would have sent the resume to the wrong project. The
authoritative cwd is where the session's `.jsonl` actually lives under
`~/.claude/projects/`. This didn't cause the incident but it shaped the
recovery and is a sharp edge for any future tooling that reads print's
cwd as gospel.

---

## Why the 2026-05-12 fixes didn't catch this

The 2026-05-12 postmortem hardened the *auto-resume* path: truthful sid
capture, wrapper priority chain, `.restoring` lock against the snapshot
race. All of that still works — panes that resurrect brought back via
the `@resurrect-processes` wrapper resumed fine.

This bug lives in the **separate UX affordance** for *hard-hibernated*
panes (claude fully exited, so resurrect has nothing to relaunch; the
post-restore path is what's supposed to repaint + pre-fill the resume).
That path:

- was added in the same commit that introduced
  `cmd_resurrect_post_restore_all` (to remove the `.restoring` lock),
  so it inherited "runs once per restore" as an unstated assumption;
- has no per-pane or per-restore idempotency guard;
- sends `clr <sid>` as un-terminated readline input, which is precisely
  the state a second pass corrupts by appending to it;
- is exercised only by *hard* hibernation across a *real* server death
  — a combination the `kill-server` cycle drills in
  `server-cycle-validation.md` don't fully reproduce (they tend to
  leave panes soft-hibernated / wrapper-resumable, and they trigger a
  single restore).

---

## Recovery procedure that worked (2026-06-16)

Per broken pane, deterministic and surgical:

1. Resolve session id + correct cwd: read the UUID from the prompt;
   confirm against the on-disk `.jsonl` location under
   `~/.claude/projects/` (not print's cwd). For multi-copy sessions,
   pick the copy whose dir still exists and has the longest/newest
   transcript.
2. `kill <exact-claude-pid>` — the claude child of the pane's shell pid
   (`pgrep -P <shell_pid>` filtered to `claude`). **Never** a
   substring `pkill`.
3. `C-c` then `C-u` to clear any leftover pre-fill in the readline
   buffer.
4. Type `cd <correct-cwd> && clr <sid>` and press Enter.
5. Verify: `cmd=claude`, `pane_current_path` == correct cwd, the real
   sid in the status bar, clean `-r <sid>` in the process args.

23/23 sessions recovered, transcripts intact.

---

## Recommended fixes

Ordered by impact. Not yet implemented — this RCA documents the
incident; patches are a follow-up decision.

1. **Single restore trigger.** Pick one of continuum's built-in
   `@continuum-restore on` *or* the `restore-wrapper.sh` boot path —
   not both. If the wrapper is needed for the force-restore behavior,
   set `@continuum-restore off` and let the wrapper own restore
   exclusively. This removes the concurrency at the source.

2. **Idempotency guard on the post-restore UX subshell.** Claim a
   per-restore lock (e.g. `$resurrect_dir/.post-restore-ux.<boot-id>`)
   or a per-pane marker before sending keys, so a second concurrent
   invocation is a no-op. The path must be safe to fire N times.

3. **Make the pre-fill cwd-correct and Enter-safe.** Pre-fill
   `cd <saved-cwd> && clr <sid>` instead of bare `clr <sid>` — this is
   exactly what manual recovery had to do, and it removes the
   dependency on resurrect having restored the pane's cwd. Send a
   leading `C-u` before the pre-fill to guarantee a clean line.

4. **Don't send `claude-rescue print` with Enter into a line that may
   hold pre-fill text.** Either run print on a guaranteed-fresh line,
   or drop the auto-print entirely (the capture is on disk; the user
   can run `claude-rescue print` themselves). The print step is the
   half that turns a benign duplicate pre-fill into an *executed*
   garbled command.

5. **Extend cycle validation to this case.** Add a scenario that hard-
   hibernates a pane (claude fully exited, `clr <sid>` pre-filled),
   then triggers restore **twice** (or asserts only one restore can
   run), and verifies the pane ends with a single clean `clr <sid>`
   pre-fill — not an executed/garbled command.

---

## Lessons

1. **Keystroke injection must assume it can run more than once.** Any
   `send-keys` UX that leaves un-terminated input on a prompt is a
   loaded gun for the next pass. Idempotency isn't optional for
   restore-time automation — restore can be triggered by more than one
   mechanism, and they can overlap.

2. **Two restore triggers is one too many.** The boot guard and
   `@continuum-restore on` were each reasonable in isolation; together
   they double every post-restore hook. Config that arms the same
   critical operation twice needs an explicit "only one wins" gate.

3. **`send-keys.log` is the hero.** The two-pass race was invisible
   from the pane captures alone — only the timestamped injection log
   with `cur_cmd`/`claudes_in_subtree` columns made the mechanism
   unambiguous. Keep logging every internal injection.

4. **Print's cwd is last-active, not launch.** Resume tooling must
   resolve cwd from where the session `.jsonl` actually lives, not from
   the capture header. Multi-copy sessions (resumed across worktrees)
   need the existing-dir-with-newest-transcript rule.

5. **A real crash ≠ `kill-server`.** The drill restarts are too clean:
   single restore, panes left wrapper-resumable. This bug needed a true
   server death with hard-hibernated panes and a doubled restore.
   Validation should model the messy case.

---

## What this RCA does not cover

- The exact pane-deduplication behavior of two tmux-resurrect restores
  racing to rebuild the same named sessions (why *some* panes came back
  as `bash` in `$HOME`) was inferred from the log, not independently
  reproduced. The fix (single restore trigger) makes it moot.
- Patches landed in commit `9c58999` (2026-06-26) — recommended fixes 2–5;
  fix 1 (single restore trigger) is a deferred chezmoi change. The
  Resolution section below records what shipped and the gaps a post-fix
  code review surfaced.

---

## Resolution — 2026-06-26 (commit `9c58999`)

`fix(restore): idempotent, cwd-anchored post-restore pre-fill` hardened the
post-restore UX path. Status against the Recommended fixes above:

- **Fix 2 (idempotency guard) — DONE.** Per-pane, per-server-PID atomic
  `mkdir` claim at `$CACHE/post-restore-claims/<server-pid>__<pane_uuid>`,
  claimed before any keystroke; the loser of a concurrent race `continue`s.
- **Fix 3 (cwd-correct + Enter-safe) — DONE.** Pre-fill is now
  `cd <launch-cwd> && clr <sid>`, led by `C-u`. Launch cwd from
  `claude-rescue find-sessions --pane-uuid` col 6, `[ -d ]`-guarded, with a
  fallback to the capture cwd, then bare `clr`.
- **Fix 4 (no Enter-terminated keystroke) — DONE.** The auto
  `claude-rescue print` is dropped; nothing the subshell sends carries Enter.
- **Fix 5 (validation) — DONE (partial — see coverage gaps).**
  `validate-crash-restore.sh` scenarios 5 (concurrent double-fire) and 6
  (vanished-dir fallback); `server-cycle-validation.md` Phase 5 updated.
- **Fix 1 (single restore trigger) — DEFERRED.** chezmoi
  `@continuum-restore off` cleanup; the guard makes it non-load-bearing, but
  the double restore still fires on every real boot.

Structural note: dropping the Enter keystroke (fix 4) plus the leading `C-u`
(fix 3) already make a double-fire benign on their own — no Enter ⇒ nothing
executes; `C-u` ⇒ the last writer leaves a clean buffer (tmux processes each
`send-keys` atomically, so no character interleave). The `mkdir` claim adds
exactly-once cleanliness on top. Three independent layers — good depth.

### Review follow-ups (gaps remaining after `9c58999`)

Found by reading the full diff against the prior code review. **None re-open
the incident** — they are sharp edges and coverage holes on top of a sound
fix.

**Worth fixing before calling it closed:**

1. **Unquoted launch cwd (latent bug).** `bin/claude-rescue-log` builds
   `prefill="cd $launch_cwd && clr $sid"` — `$launch_cwd` is interpolated
   unquoted into text typed at the shell. A launch dir containing a space
   (or shell metachar) types a broken `cd`; the `[ -d "$launch_cwd" ]` test
   is quoted but the emitted line is not. The picker's `resume_command`
   already `%q`-quotes (`cd %q && claude --resume %q`) — match it. (The
   `claude-rescue-resume` wrapper is unaffected: it `exec`s claude with a
   quoted argv, never types into a shell.)
2. **cwd/sid provenance not pinned to one session.** `sid` comes from
   `captures/<pane_uuid>.json`, but `launch_cwd` comes from
   `find-sessions --pane-uuid <uuid> | head -1` col 6 — not filtered to
   `$sid`. A pane that hosted more than one session (the scenario-3 case:
   hard → fresh `cl` → hard again) can surface a row for a *different*
   session, yielding `cd <other-session-cwd> && clr <sid>`. Worst case is the
   same picker fallback as pre-fix (not a regression), but it silently
   defeats the cwd anchoring for exactly the multi-copy case the
   "Contributing" section warns about. Confirm `find-sessions --pane-uuid`'s
   row count/sort and match the row on col 1 == `$sid`.

**Coverage gaps (the headline mechanism is under-tested):**

3. **The primary find-sessions cwd path has no automated coverage.** Both
   new scenarios fall through to the *capture-json fallback* — scenario 6's
   own comment notes "find-sessions won't resolve a fixture sid in the real
   projects dir." So `cd <launch-cwd>` is only ever exercised via the
   fallback; the jsonl-validated primary source is validated only manually
   (server-cycle-validation Phase 5).
4. **cwd correctness is asserted only as format, not value.** Scenario 5
   matches `cd .* && clr <sid>` (any target) and never lands a pane in
   `$HOME` to prove the `cd` actually *rescues* a mis-restored pane — the
   real-world failure the fix targets. A wrong cwd would still pass.
5. **Idempotency is tested at the subcommand level, not the real
   double-trigger.** Scenario 5 calls `claude-rescue-log resurrect-restore`
   twice directly; it does not exercise continuum + `restore-wrapper` +
   `restore.sh`, nor the `$HOME`-landing collateral. Faithful unit test of
   the `mkdir` claim; the system-level repro still needs the chezmoi path
   (which staging deliberately suppresses).

**Lower priority:**

6. **claims_dir-unwritable ⇒ silent total skip.** If `$server_pid` is set
   but `mkdir "$claim"` fails for a non-race reason (dir unwritable / ENOSPC),
   every pane `continue`s and *zero* pre-fills happen, silently — asymmetric
   with the empty-`server_pid` path, which falls through and pre-fills all.
7. **Same-epoch deliberate re-restore is a no-op; claims linger.** The claim
   epoch is the whole server lifetime, so a manual `prefix+Ctrl-r` later
   skips already-claimed panes; claims are cleaned only when a new server
   PID sweeps them. Correct for the incident, bounded and harmless, but
   mildly surprising.
8. **Twin pre-fill site lacks `C-u`.** The hard-hibernation arm path
   (`hibernate-hard-clr`, ~`claude-rescue-log:1256`) still sends a bare
   `clr <sid>` without the leading `C-u`. Not a cwd risk (absent a restore
   the pane keeps its dir), but inconsistent with the hardened restore path.

**Still open, system-wide (pre-existing, out of this commit's scope):**

9. **`claude-rescue-resume` resumes in the wrong `$PWD` knowingly.** The
   soft-hibernation wrapper-resume path (distinct from this hard-hibernation
   pre-fill) computes `cwd_match=N` (`~claude-rescue-resume:251-254`), logs
   it, and `exec claude` in the inherited `$PWD` anyway — silently starting
   a fresh session when restore lands the pane in the wrong dir. The cwd
   class is hardened for hard-hibernation here but not closed for
   wrapper-resume.

---

## Follow-up resolution — 2026-06-27

All review follow-ups addressed across two commits (`bin/` fixes +
container-harness expansion) plus the deferred config cleanup. Validated in
a real-stack Docker harness (`test/docker/`) that reproduces the genuine
continuum + restore-wrapper dual-trigger — the system-level repro staging
can't do — and now also the single-trigger cleanup. Matrix: 4/4 green
(NPANES 1,2 × dual,single).

- **#1 unquoted launch cwd — FIXED.** Pre-fill built with
  `printf 'cd %q && clr %s'` (mirrors the picker's `resume_command`).
- **#2 cwd not pinned to sid — FIXED.** Launch cwd taken from the
  `find-sessions --pane-uuid` row whose col 1 == `$sid` (awk match), not
  `head -1`.
- **#3 find-sessions primary path uncovered — FIXED.** The container runs
  real claude → real transcripts, so find-sessions resolves for real; the
  harness asserts it returns the launch cwd for the sid (primary path, not
  the capture-json fallback).
- **#4 cwd asserted as format not value — FIXED.** The harness asserts the
  exact value (`cd /work/projN && clr <sid>`) and that the restored nvim
  process is editing the saved file.
- **#5 idempotency not tested at the real dual-trigger — RESOLVED.** The
  container fires the genuine continuum + restore-wrapper double-restore
  (hook fires ≥2×) and asserts exactly one pre-fill per pane. Single mode
  asserts the hook fires exactly once.
- **#6 mkdir-claim silent total skip — FIXED.** A failed claim distinguishes
  EEXIST (race → skip) from a real failure (→ fall through and pre-fill).
- **#7 same-epoch re-restore no-op — ACKNOWLEDGED (by design).** Epoch is
  the server lifetime; claims are swept on the next server PID. Bounded and
  harmless; left as-is.
- **#8 twin pre-fill lacked `C-u` — FIXED.** `hibernate-hard-clr` now leads
  with `C-u`.
- **#9 wrapper-resume wrong `$PWD` — FIXED.** `claude-rescue-resume` cd's to
  the session's launch dir before `exec claude` when the inherited `$PWD`
  can't resolve the target's transcript, guarded by a `<cwd>/<sid>.jsonl`
  existence check (only ever helps; never cd's somewhere the resume would
  fail).

**Config cleanup (the original fix 1) — DONE.** `dot_tmux.conf`:
`@continuum-restore off` + the boot guard rewired so `restore-wrapper.sh` is
the sole restore path (gated only on `@continuum-boot-started`, no longer on
`@continuum-restore = on` — which would otherwise silence both triggers).
Container-proven equivalent: `CLR_MODE=single` restores exactly once and
still brings back claude pre-fills **and** nvim.

**Incidental findings (harness/fidelity, not product bugs):**

- **mise/argv parity.** The container originally lacked `mise activate`, so
  `nvim` resolved via the mise shim and was saved with its full install path
  as argv[0] — which tmux-resurrect's anchored `^nvim ` proc-match can't
  match, so nvim never restored. macOS captures bare `nvim` (install bin
  ahead of the shim via `mise activate`). Adding `mise activate zsh` to the
  image restores argv parity, so the *same* production `@resurrect-processes`
  restores nvim in-container. **The host is unaffected** — its real
  snapshots already save bare `nvim`.
- **First-window restore.** A claude pane in a session's *first* window
  restores via resurrect's session-create path; the sidecar's index-keyed
  `@claude-pane-id` reapply could land on the wrong pane. Surfaced only in
  the container's mixed claude+nvim layout (both trigger modes equally — not
  cleanup-related). The harness now keeps test panes out of the first window.

**Residual test coverage (correct by inspection, not pinned by a regression
test).** Two of the follow-up fixes verify by reading the code but are never
*driven* by the container harness, which exercises the post-restore pre-fill
happy path — one session per pane, hard hibernation. A future refactor could
regress either of these and the suite would still pass green:

- **#2 (cwd/sid provenance).** The harness launches a single session per
  pane, so `find-sessions --pane-uuid` returns one row and the new
  `col1 == $sid` match behaves identically to the old `head -1`. The
  multi-session-per-pane case the fix targets (hard → fresh `cl` → hard
  again, i.e. ≥2 rows for one `pane_uuid`) is never reproduced, so the
  disambiguation itself is unverified. A scenario that runs two sessions in
  one pane and asserts the pre-fill anchors the *intended* session's cwd
  (not the other row's) would pin it.
- **#9 (wrapper-resume cwd-rescue).** The new `claude-rescue-resume`
  cd-to-launch-dir logic lives on the soft-hibernation / `@resurrect-processes`
  relaunch path. The harness asserts the *hard*-hibernation pre-fill, not a
  soft-hibernated claude that the wrapper relaunches in a wrong `$PWD`. A
  scenario that soft-hibernates a pane, forces restore to land it in `$HOME`,
  and asserts the wrapper resumes the *same* session (not a fresh one) would
  pin it.

Neither is a correctness concern today; the code is unambiguous on read. The
gap is purely regression protection for two paths the harness doesn't reach.
