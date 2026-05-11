# PRD: absorb tmux-resurrect + tmux-continuum into our own implementation

Status: draft
Owner: TBD
Created: 2026-05-10

## Summary

The architectural-split PRD currently declares "Replacing tmux-resurrect
or tmux-continuum" as a non-goal. This PRD argues that's the wrong
non-goal — once the daemon-centric architecture is in place, our
implementation will already own a richer, more coherent version of
everything resurrect+continuum do for our use case, and the boundary
between us-and-them becomes a maintenance liability rather than a
modular strength.

The proposal: **`tmux-pane-rescue` (plus the daemon) absorbs the
responsibilities of tmux-resurrect and tmux-continuum** — layout save,
pane content snapshots, process restoration, auto-save scheduling,
auto-restore on boot — and ships them as native, daemon-driven
capabilities. Users keep TPM for installing our plugin; they can
uninstall resurrect + continuum entirely.

This is a scope expansion. It supersedes the non-goal in
`prd-architectural-split.md` ("Replacing tmux-resurrect or
tmux-continuum"). It's a direction commit, not immediate work.

## Problem statement

Five reasons the current "use resurrect/continuum as a library"
approach is hitting its ceiling:

1. **We've already had to customize both extensively.** Our
   `~/.tmux.conf` currently includes:
   - `@resurrect-hook-post-save-layout` for `@claude-window-id`
     sidecar writes.
   - `@resurrect-hook-pre-restore-pane-processes` for re-applying
     the sidecar BEFORE `@resurrect-processes`'s send-keys fires.
   - `@resurrect-processes '~caffeinate "claude->claude-rescue-resume *"'`
     to wrap the saved claude command with our deterministic
     resume wrapper.
   - Custom `session-window-changed` / `client-session-changed`
     hooks driving extra continuum saves.
   - Per-server `@resurrect-dir` override (continuum/resurrect's
     default of "one global dir for all servers" overwrites state
     between servers).
   - Force-enabling continuum auto-save/restore even when multiple
     servers run (continuum disables this by default).

   That's not "using a plugin," that's "running a plugin in a
   custom configuration that's only meaningful to us." The
   integration surface has more of our code than theirs.

2. **The hook chain is fragile and timing-sensitive.** We had to
   move `source-file -q '~/dev/claude-rescue/tmux/rescue.tmux.conf'`
   to BEFORE `run '~/.config/tmux/plugins/tpm/tpm'` because TPM's
   plugin init triggers continuum's first save before our hook
   options are set — silently losing the sidecar write. This kind
   of inter-plugin ordering hazard is exactly what owning the
   stack fixes.

3. **The daemon will own a strictly richer state model.** Once the
   daemon exists, it has live, in-memory state for every pane:
   `@pane-uuid`, current command, foreground process tree, last
   capture, hibernation state, session attribution. Continuum's
   periodic "snapshot every pane every N minutes" is a strict
   subset of what the daemon already knows. Continuum is then
   writing snapshots that duplicate the daemon's view — two
   systems writing the same thing, no shared schema, drift waiting
   to happen.

4. **Event-driven capture is strictly more capable than periodic
   capture.** We already capture pane scrollback on focus-out
   (in the architectural-split PRD, default ON). That fires at the
   moment something *changes* — exactly when a snapshot is most
   useful. Continuum's 1-minute (or 15-minute) periodic snapshot
   is wasteful when nothing changes and stale when things do.

5. **Process restoration is *exactly* what claude-rescue-resume
   was built to be.** resurrect's `@resurrect-processes` mechanism
   exists to respawn the right command on restore. We've already
   replaced its naive scrollback-grep with `claude-rescue-resume`
   for claude specifically. The pattern is general: each
   `@pane-uuid` knows what command it was running, the daemon
   knows how to respawn it. There is no part of resurrect's
   process-restoration logic that we can't do better with our
   `@pane-uuid`-keyed state model.

## Goals

- `tmux-pane-rescue` natively handles **layout save**: serialize
  current tmux server's session/window/pane geometry to disk on
  daemon-determined events.
- `tmux-pane-rescue` natively handles **pane content snapshots**:
  the same capture-on-defocus mechanism doubles as the "saved
  scrollback" the restore path reads.
- The daemon natively handles **auto-save scheduling**: event-driven
  by default (focus changes, session_end, client-detached), with an
  opt-in periodic fallback for users who want it.
- `tmux-pane-rescue` natively handles **process restoration on
  restore**: each `@pane-uuid` carries the command it was running,
  the daemon respawns it deterministically (no scrollback grep, no
  matcher regexes), and consumers (claude-rescue) plug in
  command-rewriters to transform the saved invocation into a
  resume invocation.
- The daemon natively handles **auto-restore on tmux start**:
  detects an unrestored state file, replays into the new server.
- Users uninstall tmux-resurrect and tmux-continuum after migration.
  Their `.tmux.conf` shrinks meaningfully.
- The daemon's coherent state model means the restored state is
  consistent: hibernation status, session attribution, busy
  markers, and pane content are all part of one save and restore
  cycle, not three independent ones with their own schemas.

## Non-goals

- Replacing TPM. Plugin install convention stays.
- Replacing tmux itself or its hook surface.
- Replacing themes, prefix-highlight, or any of the user-visible
  tmux extensions that aren't about state save/restore.
- Forcing immediate migration. Users who want to keep running
  resurrect+continuum alongside `tmux-pane-rescue` should be able
  to during a transition period (with the understanding that
  duplicate save schedules will fight each other and one must be
  authoritative).
- Re-implementing every flag resurrect/continuum support. We
  inherit the *use cases* not the *API surface*. Some niche
  options (e.g. resurrect's per-pane strategy overrides for vim,
  emacs, etc.) we'd reimplement only if they earn it.

## What we absorb, what we keep, what we drop

| Capability                                    | Currently           | After absorption                              |
|-----------------------------------------------|---------------------|-----------------------------------------------|
| Layout save (session/window/pane geometry)    | resurrect           | `tmux-pane-rescue` + daemon                   |
| Pane content snapshots                        | continuum (1-15min) | Daemon: event-driven (focus, session_end)     |
| Process command save                          | resurrect           | `tmux-pane-rescue` per-pane state             |
| Process command rewriters (e.g. claude resume)| `@resurrect-processes` regex | Daemon plugin hook: consumers register a rewriter |
| Auto-save scheduling                          | continuum daemon    | Daemon scheduler (event-driven + opt-in periodic) |
| Auto-restore on tmux start                    | continuum           | Daemon (or fallback shell script)             |
| Per-server isolation of save state            | hacked via @resurrect-dir | First-class: keyed by `tmux socket basename`  |
| Sidecar for `@pane-uuid` / `@claude-window-id`| Custom hooks        | Native: options ARE the durable state         |
| Hibernation-aware restore (don't respawn hibernated panes) | Not possible — resurrect doesn't know about hibernation | Native: daemon's state model has it |
| User-visible state file format                | Resurrect's plaintext format | New format, plus an importer for legacy state |
| `prefix + Ctrl-s` / `prefix + Ctrl-r` keybinds | resurrect           | `tmux-pane-rescue` (same default keybinds for muscle memory) |

**What stays unchanged for users:**
- The "save with prefix+Ctrl-s, restore with prefix+Ctrl-r" muscle
  memory. We bind the same keys.
- The "tmux restarts and everything comes back" promise.
- Plugin installation via TPM.

**What changes for users:**
- One plugin in `.tmux.conf` instead of three (resurrect +
  continuum + claude-rescue's source-file).
- State files live in a new layout under `$XDG_DATA_HOME/
  claude-rescue/state/` (or `tmux-pane-rescue/state/`) instead of
  `$XDG_DATA_HOME/tmux/resurrect/`.
- Auto-save is event-driven by default; users who want a periodic
  heartbeat opt in via `@pane-rescue-save-interval`.
- Pane content is captured at focus-out, not on every save tick.
  Restored panes show the user's *last view* of that pane, not a
  random snapshot from N minutes ago.

## Architecture

The absorbed capabilities slot into the daemon-centric architecture
without inventing new top-level components. The split-PRD's daemon
already needs to know live pane state to schedule hibernation and
power the picker; that same state is what gets serialized for
crash recovery.

### Save flow

Daemon-owned save is **incremental and event-driven**:

1. Whenever the daemon's in-memory state mutates (pane added,
   focus changed, hibernation state changed, session_id learned),
   it diffs against the last persisted state.
2. Diffs are appended to a journal at
   `$XDG_DATA_HOME/<plugin>/state/<socket-basename>.journal`.
3. At configurable intervals (default: 5 minutes idle, immediately
   on `client-detached`), the journal is compacted into a snapshot
   `state/<socket-basename>.snapshot.json` and the journal is
   truncated.
4. Pane content snapshots are the existing capture files
   (`captures/<pane-uuid>.txt`). The state snapshot references them
   by uuid — no duplication.

This is strictly more efficient than continuum's periodic
"serialize everything every N minutes" because:
- Idle state writes nothing.
- Active state writes only diffs.
- Pane content reuses the capture files we already write on
  focus-out.

### Restore flow

On tmux server start:

1. The daemon detects a snapshot for the current socket-basename.
2. Replays it into the new server via `tmux new-window`, `tmux
   split-window`, `tmux send-keys`, etc. — same primitives
   resurrect uses, just driven by a coherent state model.
3. For each pane being restored:
   - Re-applies `@pane-uuid` and `@claude-window-id` directly
     (they're top-level in our schema, not bolted-on sidecars).
   - Consults the **command-rewriter registry**: for each
     `(comm, registered_rewriter)` pair, the rewriter transforms
     the saved command into a respawn command. claude-rescue
     registers `comm=claude → claude-rescue-resume <saved_args>`.
     The base plugin ships rewriters for nothing — it just
     respawns the saved command verbatim, which matches
     resurrect's default behavior.
   - Skips respawn if the pane was hibernated (mode=hard) at save
     time. The user comes back to a clean shell prompt with the
     captured scrollback visible via `pane-rescue print`.

### Command-rewriter registry

This is the generalization of `@resurrect-processes`. Instead of
a regex-on-saved-command match, consumers register named
rewriters with the daemon:

```bash
# In claude-rescue's install:
pane-rescue register-rewriter \
  --name claude \
  --match-comm claude \
  --rewriter /Users/.../bin/claude-rescue-resume
```

The daemon invokes the rewriter with the saved command-line and
pane context as args/env, and uses the rewriter's stdout as the
respawn command. Idempotent registration; multiple plugins can
register rewriters for different `comm` values.

This replaces:
- Resurrect's `@resurrect-processes` pattern matching (regex
  against saved command string).
- Resurrect's `~claude->claude-rescue-resume *` substitution
  syntax (its own DSL we've documented bugs in).
- Resurrect's per-shell-tool override mechanism.

### Schema

A single `snapshot.json` (and journal of diffs) per tmux socket.
Top-level:

```json
{
  "schema_version": 1,
  "socket_basename": "default",
  "saved_at": "2026-05-10T15:30:00Z",
  "sessions": [
    {
      "name": "main",
      "windows": [
        {
          "index": 1,
          "name": "claude",
          "@claude-window-id": "cf347ccd-…",
          "layout": "<tmux layout string>",
          "panes": [
            {
              "index": 1,
              "@pane-uuid": "eb76adee-…",
              "cwd": "/Users/…/dev",
              "command": "claude --resume abc-123",
              "comm": "claude",
              "hibernation": {"mode": "soft", "ts": "…"},
              "capture_ref": "captures/eb76adee-….txt"
            }
          ]
        }
      ]
    }
  ]
}
```

Note what's first-class here that resurrect bolts on:
`@pane-uuid`, `@claude-window-id`, hibernation state, capture
reference. These are the data we currently smuggle in through
sidecar TSVs.

### Backwards compatibility / import path

A one-shot importer reads existing `tmux-resurrect` save files
and converts them to our format:

```bash
pane-rescue import-resurrect [--from /path/to/resurrect-dir]
```

Run on first install; user gets all their saved state. The
importer drops `@resurrect-*` options that don't have a target
in our schema and logs them so the user can verify nothing
load-bearing was lost.

After migration, users can uninstall resurrect + continuum from
TPM.

## Migration plan

Sequenced as a Stage 7 to the architectural-split PRD (after the
basic split lands), or sooner if the integration-pain heuristic
trips before then.

### Stage A: parity-mode save

The daemon's save runs **alongside** continuum's, writing to its
own location. Tooling compares the two on every save:

```bash
pane-rescue diff-resurrect
```

Differences are logged. Anything we're missing relative to
resurrect, we add. Anything we're recording that resurrect isn't,
we document as an upgrade. Run for ~2 weeks under daily use.

### Stage B: parity-mode restore

The daemon's restore runs in dry-run mode on every tmux start,
producing a log of what it would have done. Compare to what
continuum/resurrect actually did. Reconcile.

### Stage C: switch primary

Flip the keybinds to `tmux-pane-rescue`'s save/restore. Continuum
auto-save disabled. Resurrect installed but inert. This is the
"trust but verify" stage — if anything goes wrong, the resurrect
state files are still on disk to recover from.

### Stage D: removal

Document the migration. Users uninstall resurrect + continuum.
`.tmux.conf` shrinks to one source-file line.

## Open questions

- **Do non-claude users want this?** A user who installs
  `tmux-pane-rescue` for capture-on-defocus alone (no claude)
  inherits a layout-save/restore stack they didn't ask for.
  Mitigation: make layout save/restore opt-in via a single tmux
  option (`@pane-rescue-manage-layout on`). Users who want only
  the pane lifecycle features keep using resurrect+continuum
  alongside.

- **vim/nvim session restoration.** Resurrect has special-case
  logic for vim/nvim/emacs (writes/reads a session file
  alongside). Worth replicating? Lean yes for nvim — it's
  high-value and well-defined. Other editors as the request
  surface emerges.

- **`@resurrect-strategy-*` analogs.** Per-program save strategies
  (e.g. "for vim, write `:mksession`"). Our command-rewriter
  registry covers the *restore* side; we'd need a parallel
  pre-save-hook registry. Defer until needed.

- **Save-on-detach default.** Resurrect requires explicit
  Ctrl-s; continuum saves on its interval. Our event-driven
  approach should save on `client-detached` for sure, and on
  significant state changes (session_end, hibernation transitions).
  Periodic save is opt-in. Sensible default? Lean: event-driven
  by default, no periodic.

- **Pane content storage budget.** Continuum's save with all
  panes captured can be 10s of MB. Our event-driven capture
  bounds this naturally (one file per pane, overwritten on each
  focus-out), but a user with 50 active panes is still looking at
  ~50 × N-line captures × 50KB each. Need a per-user cap with
  LRU eviction. Cf. the disk-budget metric in the split PRD.

- **What about other tmux state we currently inherit from
  resurrect?** Buffer history, window flags, copy-mode state.
  Audit what resurrect saves, decide piece by piece.

- **Compatibility with users who DO want continuum-style periodic
  saves alongside.** Some users might want both for paranoia.
  Should we even support this, or is it strictly "one
  authoritative save process per server"? Lean strict — duplicate
  save processes lead to state inversion bugs.

## Risks

- **Massive scope addition.** Layout save/restore is non-trivial
  code. resurrect is ~3000 lines of bash with years of bug-fix
  commits. Re-implementing it is at least months of work and
  carries a real "lose user data" risk if we get it wrong.
  Mitigation: parity-mode (Stages A–C) catches divergences before
  users feel them.

- **User trust.** "I trusted resurrect with my tmux sessions for
  years and you replaced it with your own thing?" Loss-of-state
  bugs erode that trust permanently. Mitigation: the importer
  makes migration reversible (resurrect state files stay on disk
  through Stages A–C); the parity tooling demonstrates we're not
  missing data; clear release notes when we ship the cutover.

- **Niche features we don't replicate cause unhappy edge cases.**
  Resurrect supports e.g. emacs daemon restoration, custom
  per-pane respawn shells, etc. We won't ship all of those on day
  one. Some users will be blocked.

- **Maintenance burden moves to us.** Resurrect bugs are someone
  else's problem today. After absorption, every bug is ours.

- **Coupling between layers tightens again.** Part of the
  motivation for the architectural split was failure-mode
  clarity. Owning the save/restore stack means
  `tmux-pane-rescue` carries general tmux-state responsibility,
  not just pane-lifecycle. The line we drew may shift.

## Success metrics

- `.tmux.conf` (the load-bearing config we own) shrinks from
  ~25 lines of resurrect+continuum+hook config to <5 lines.
- Zero data-loss reports in Stage A (parity mode) for ≥30 days.
- Save/restore round-trip latency improves: <2s for typical
  workloads (continuum's periodic saves currently take 5-10s on
  busy servers).
- Restored sessions have correct `@pane-uuid` + `@claude-window-id`
  attribution at the first claude restore (today we rely on the
  sidecar hook landing before resurrect's send-keys, which has
  been a recurring source of bugs).
- Hibernated panes do not get re-spawned on restore (today we
  have no mechanism for this — resurrect would happily restart a
  claude that was deliberately exited via hard hibernation).

## Decision

Not building this now. Capture as direction for after the
architectural-split + daemon work has settled. Re-evaluate when:

- The daemon's state model is stable.
- The integration pain (hook ordering bugs, sidecar fragility,
  per-server hacks) has accumulated to the point that "let's just
  own it" is the cheaper option.
- We have at least one piece of clear evidence that resurrect's
  scope is actively limiting us — e.g. needing a feature it
  doesn't support that we can't graft on via a hook.

This PRD supersedes the prior non-goal in
`prd-architectural-split.md` line "Replacing tmux-resurrect or
tmux-continuum." That non-goal should be removed when this
direction is committed.
