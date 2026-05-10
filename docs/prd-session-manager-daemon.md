# PRD: claude-rescue session manager daemon

Status: draft
Owner: TBD
Created: 2026-05-10

## Summary

Replace the current scattered event-driven shell architecture with a single
long-running daemon that owns the live state of all claude sessions across
all tmux panes. The daemon takes over hibernation scheduling, transcript
mirroring, summarization-driven findability, and archival — capabilities the
current model cannot reach because no process has a coherent, in-memory view
of "all sessions right now."

This is a north-star design. It is not the next feature to ship. It exists
to set direction for the bash-sleeper hibernation work so that work doesn't
paint us into a corner.

## Problem statement

Today claude-rescue is a constellation of short-lived shell invocations:

- Claude hooks (`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`,
  `PostToolUse`, `Stop`) fire `claude-rescue-log` subprocesses.
- Tmux hooks (`pane-focus-out`, `pane-focus-in`, `client-detached`,
  resurrect save/restore) fire `claude-rescue-log` subprocesses.
- Each invocation reads/writes JSONL append logs and `meta.json` rollups.
- Hibernation timing is handled by detached `bash + sleep` subshells, one
  per defocused claude pane.

State is reconstructed on demand by reading files. This has worked because
the operations are simple — record an event, rebuild a meta, look up by
pane_uuid — but the model has clear ceilings:

1. **No live introspection.** "Which timers are armed right now?" is
   answered by `ls $CACHE/hibernated/*.arm.pid` and pid-liveness checks.
   "Which sessions are open?" is reconstructed from JSONL replay each call.
2. **No reboot survivability for in-flight schedules.** A `bash sleep 86400`
   cannot survive a tmux server kill or macOS reboot. Hibernation timers
   armed at hour 0 are gone by hour 23.
3. **Transcript loss.** Claude rotates/wipes `~/.claude/projects/<enc>/<sid>.jsonl`
   files. Sessions in our event log without transcripts on disk are
   filtered out by the picker as unresumable. We don't currently have a
   path to preserve them.
4. **No findability beyond scrollback.** The picker filters by tmux scope
   (window/pane/cwd). There's no way to find a session by *content* — by
   what was being worked on, what files were touched, what topic was
   discussed.
5. **No cross-pane policy.** Decisions like "hibernate the oldest 5 idle
   panes when memory pressure rises" are unreachable from per-event
   subprocesses with no shared state.

## Goals

- A single supervised process owns the live state model.
- Transcripts that Claude is about to wipe are mirrored to durable storage
  before they go.
- Sessions can be found by content, not just by tmux geometry.
- Old sessions are tiered (recent → on-disk full transcript, older →
  compressed transcript + summary, ancient → summary only).
- Hibernation scheduling moves into the daemon as one responsibility among
  many — survives reboots, supports cross-pane policy.
- Single CLI surface for introspection (`claude-rescue daemon status`).

## Non-goals

- Replacing tmux, tmux-resurrect, or tmux-continuum. The daemon coexists
  with them.
- Replacing the existing event-log JSONL store. The daemon reads/writes the
  same files for backwards compatibility with the picker, backfill, and the
  on-disk forensic surface.
- Becoming a generic process supervisor. claude-rescue's scope stays tight
  on Claude Code sessions in tmux.
- Cross-host or multi-user functionality. One daemon per user, local only.
- Replacing Claude Code's session UUIDs or transcript format. We mirror,
  not redefine.

## User-facing capabilities

### 1. Active transcript mirroring

The daemon watches `~/.claude/projects/` (fsevents on macOS, inotify on
Linux) and copies every `<sid>.jsonl` to `$DATA/transcripts/<sid>.jsonl`
the moment Claude appends to it. When Claude later rotates or deletes its
copy, our copy survives.

This eliminates the "session existed but transcript is gone" failure mode
that `find-sessions` filters out today.

### 2. Headless self-summarization

When a session ends (`SessionEnd` hook) or hits an idle threshold, the
daemon spawns Claude in headless mode against the mirrored transcript:

```
claude -p "Summarize this transcript in 2 sentences and emit 5 tags"
       --output-format json --resume <sid>
```

The result (summary + tags + token count) is persisted in the session's
meta entry. The picker exposes a content-search filter that matches against
summary text and tags.

This is the use case Claude's headless mode was built for. Cheap with
Haiku (~$0.001/session typical). Can be disabled or rate-limited.

### 3. Archival tiering

Sessions are graded by age into tiers:

- **Hot** (≤7d): full transcript on disk, full event log.
- **Warm** (7–90d): zstd-compressed transcript, full event log, summary
  inline.
- **Cold** (>90d): summary + tags only, transcript expunged. Event log
  truncated to session_start/session_end markers.

Default thresholds are configurable. The picker shows tier in the preview
so users know what's available before resuming.

### 4. Cross-pane hibernation policy

Hibernation scheduling lives in the daemon. Per-pane focus-out events RPC
into the daemon to arm timers. The daemon's scheduler can then apply
policy across panes:

- "Hibernate oldest N idle if RSS exceeds X MB"
- "Auto-archive sessions idle >7d at 3am local"
- "Skip soft hibernation while user is in a video call" (future, via
  upstream signal)

Reboot survivability is free: armed timers are persisted to
`$CACHE/scheduler.jsonl`, replayed on daemon start.

### 5. Live introspection CLI

`claude-rescue daemon status` shows:

- Live sessions: pane_uuid, session_id, cwd, claude PID, busy state
- Armed timers: pane_uuid, target time (wall clock), action (soft/hard)
- Transcript watch: dirs being watched, recent mirror events
- Summarization queue depth, archive backlog

Replaces the current "grep cache directories" workflow.

### 6. Suggested-resume hints

When a new claude pane opens, the daemon checks: is there a recent session
with the same cwd, similar tags, or whose summary mentions files in this
directory? If so, surface a non-blocking hint ("3 prior sessions touched
this directory; press prefix+R to browse").

This makes the picker discoverable without the user having to remember it
exists.

### 7. Session export

`claude-rescue export <sid>` produces a self-contained markdown bundle:
summary, tags, transcript, list of files touched, key user prompts. For
sharing context, archiving outside the rescue store, or feeding into
documentation.

### 8. Lifecycle hooks

First-class extension points users can wire shell scripts into without
touching daemon code. Hooks fire at well-defined moments in the session
lifecycle:

- `on_session_start` — runs after `SessionStart` event is recorded.
- `on_session_end` — runs after `SessionEnd` event is recorded, before
  archival eligibility check.
- `on_hibernate_arm` / `on_hibernate_resume` — fires when scheduler
  arms or cancels a hibernation timer.
- `on_summarize_complete` — runs after a session summary is written;
  receives the new tags as args. Use case: auto-tag related Linear or
  GitHub issues, post to a personal review queue.
- `on_archive_tier_change` — runs when a session moves between hot/
  warm/cold tiers.

Hooks receive context via env vars (`CLAUDE_RESCUE_SESSION_ID`,
`CLAUDE_RESCUE_PANE_UUID`, `CLAUDE_RESCUE_TIER`, etc.) and run in
isolated processes with bounded timeouts. Failures are logged but do
not block the daemon's primary work.

### 9. Dynamic config reload

The daemon watches its config file (`$CONFIG/config.sh` or successor)
and re-applies on change without restart. In-flight schedules and live
sessions are unaffected; new behavior takes effect for the next event.
Tunables that benefit: hibernation delays, summarization opt-out
globs, archival tier thresholds, hook command paths.

Refusing to apply structural schema changes mid-flight is acceptable
(those still require a restart); this capability is for tuning, not
rearchitecting at runtime.

## Architecture sketch

### Process model

One daemon per user, started by launchd (macOS) / systemd-user (Linux),
respawned on crash. Logs to `$CACHE/daemon.log` with rotation.

The daemon is a single binary (Elixir, Go, or Rust likely; bash is past
its ceiling for this — see language open question below). It hosts:

- A scheduler with a wall-clock-keyed priority queue
- A filesystem watcher (transcript mirroring)
- A small worker pool for headless Claude calls
- An archival pruner that runs daily
- A unix-socket RPC server
- A config-file watcher (dynamic reload)
- A lifecycle-hook dispatcher

**Single-authority discipline**: the daemon's scheduler is the only
component that mutates scheduling state. All worker outcomes are
reported back and converted to explicit state transitions. Stale shell
hooks (daemon-running case) RPC in or no-op; they never write
scheduling state directly. This pattern is borrowed from OpenAI's
Symphony spec and exists to prevent the "daemon and stale shell hooks
fighting over JSONL" concurrency hazard called out in the open
questions.

**State ownership**: we own our state and lifecycle. External systems
(Linear, GitHub, etc.) may serve as references the daemon reads, but
they are never sources of truth for hibernation timers, session
identity, or archival decisions. This is a deliberate divergence from
Symphony's tracker-driven recovery model — Symphony can rebuild from
Linear because Linear durably holds the work definition; we have no
analogous upstream and so persist our own state (see Persistence
below).

### IPC

Unix domain socket at `$CACHE/daemon.sock`. Existing `claude-rescue-log`
shell entrypoints become thin RPC clients — they connect, send a
length-prefixed JSON message, receive ack, exit.

If the daemon is down, the shell client falls back to the current
direct-write-to-JSONL behavior. No event is lost; some live capabilities
(scheduling, summarization queue) just don't fire until the daemon is
back. This is the operational graceful-degradation contract.

### Persistence

The daemon does not invent new storage. It writes through to:

- `$DATA/windows/<window_uuid>.jsonl` — same event log we have today.
- `$DATA/windows/<window_uuid>.meta.json` — same meta rollup, augmented
  with `summary`, `tags`, `tier` fields.
- `$DATA/transcripts/<sid>.jsonl` — new, mirrored from Claude's
  projects dir.
- `$DATA/archive/` — new, holds compressed warm/cold artifacts.
- `$CACHE/daemon.sock` — socket.
- `$CACHE/daemon.log` — log.
- `$CACHE/scheduler.jsonl` — persistent timer queue.

The picker, backfill, and other consumers continue reading the same files.
They don't need to know the daemon exists.

### Schema versioning

Meta files gain a `schema_version` field. Daemon refuses to start if it
sees a higher version than it understands (forward-compat safety).
Backwards-compat is required: a v1 meta must be readable by a v2 daemon
forever.

## Migration from the current model

This is a multi-stage migration. Each stage is shippable on its own.

### Stage 0: persistent target-timestamps for the bash-sleeper

(Not the daemon. Prerequisite that hardens the current model.)

Replace the current `arm.pid` file with `arm.json` containing
`{pid, target_ts, mode_at_target, pane_id, pane_uuid}`. On tmux server
start (a hook in `rescue.tmux.conf`), scan the directory and for each
entry whose `target_ts > now`, spawn a fresh sleeper with a recomputed
delay. Reboot-survivable hibernation without a daemon.

This is what the bash-sleeper model should always have done. Do it
regardless of whether the daemon ships.

### Stage 1: daemon shell + RPC, no new capabilities

Ship the daemon as a thin process that just receives the same events
the shell hooks would write directly, and writes them through to the
same JSONL files. Behavior identical to today; only difference is
where the writes originate. This validates the IPC, the supervision
story, the graceful-degradation contract.

### Stage 2: hibernation scheduler

Move the bash-sleeper into the daemon. Tmux focus-out hooks RPC to the
daemon's scheduler instead of spawning a sleeper. Daemon owns the
queue, persists it, replays on restart.

### Stage 3: transcript mirroring

Add the fsevents watcher. Begin mirroring. Update `find-sessions` to
prefer mirrored copies when Claude's original is gone.

### Stage 4: summarization

Add the headless-Claude worker pool. Backfill summaries for existing
sessions on first run, then incrementally on session_end.

### Stage 5: archival tiering

Add the daily pruner. Surface tier in the picker preview.

### Stage 6: introspection + suggestions

Build out `claude-rescue daemon status` and the suggested-resume hints
on new pane open.

## Prior art

OpenAI's [Symphony](https://github.com/openai/symphony) (April 2026)
is the closest published reference to this design. It is an Elixir/BEAM
daemon that orchestrates Codex agents pulling tickets from Linear.
Symphony solves a different problem — *spawning new autonomous coding
runs* — but its architectural choices are directly applicable here:

- **Single-authority orchestrator** (adopted; see Process model above).
- **Per-run ephemeral workers, persistent orchestrator** (adopted).
- **Lifecycle hooks** at well-defined transitions (adopted; see #8).
- **Dynamic config reload** without restart (adopted; see #9).
- **BEAM/Elixir as runtime** for supervision-tree workloads (adopted
  as a serious option in the language question below).

What we deliberately do **not** adopt from Symphony:

- **Tracker-driven recovery / no durable state**. Symphony rebuilds
  scheduling state on restart by re-reading Linear; their tracker is
  the source of truth. We have no upstream tracker analog —
  hibernation schedules, session identity, and tiering decisions are
  internally owned. We persist `scheduler.jsonl` and replay on
  restart.
- **Autonomous-agent scope**. Symphony is aimed at autonomous coding
  with humans reviewing PRs at the end. claude-rescue is a session
  *management* tool — we're not driving claude, we're observing and
  preserving it. The verbs differ: Symphony "spawn → drive →
  reconcile"; we "watch → mirror → summarize → archive."

## Open questions

- **Language**: Elixir/BEAM vs Go vs Rust.
  - Elixir has supervision trees and process isolation as
    first-class runtime primitives. The daemon's primary job is
    supervising N child processes with crash-recovery semantics —
    exactly BEAM's wheelhouse. Symphony's choice of Elixir for the
    same shape of problem is a strong signal.
  - Go: fastest iteration, lowest cognitive load, decent supervision
    via `errgroup` / `context`. Lacks BEAM's preemptive scheduling
    and process-level isolation.
  - Rust: lowest steady-state RSS, best for long-idle daemons.
    Forces you to reinvent supervision (Tokio supervisors are
    available but not idiomatic).
  - Lean Elixir for the supervision fit, with Rust as the
    runner-up if RSS becomes a hard constraint. Not decided.
- **Supervision**: launchd vs a tmux-startup hook that double-forks.
  launchd is the right answer for survivability across logout/login;
  tmux hook is simpler but ties daemon lifecycle to tmux.
- **Headless Claude cost**: per-session token spend is small but not
  zero. Defaults to Haiku, opt-in to Sonnet, opt-out entirely via
  config. Is anyone going to want this off?
- **Privacy**: summarization sends transcripts back through Claude's
  API. For sensitive sessions (passwords typed, secrets in scrollback),
  is there a session-level "do not summarize" annotation? Probably
  yes, set by a slash command or config glob.
- **Concurrency safety on JSONL**: the daemon and stale shell hooks
  could append to the same file simultaneously. Today we rely on
  PIPE_BUF atomicity for short lines. Daemon should serialize its own
  appends through a per-file actor. Stale shell hooks during daemon
  runtime is a documented edge case (graceful-degradation path is for
  daemon-down, not daemon-also-running).
- **Window vs session keying**: meta files are window-keyed today.
  Some daemon capabilities (summarization, archival) are
  session-keyed. Schema may need to evolve to track both first-class.

## Risks

- **Operational complexity**. A daemon is another thing to start, stop,
  watchdog, debug, version, log. Today the operational story is "no
  state, restart tmux." That's a real strength being given up.
- **Crash blind spots**. Today an event-script crash loses one event
  and is loud (stderr to a log file). A daemon crash loses every
  in-flight schedule and silently degrades the live state model until
  respawn. Watchdog + structured logging are non-negotiable.
- **Schema lock-in**. Once the daemon owns a richer data model, schema
  changes become real migrations. Today the schema rebuilds from
  events on every meta update — drift is self-healing. That property
  goes away.
- **Scope creep**. "Centralized manager of sessions" is the kind of
  framing that grows. Each capability above is individually
  justifiable, but together they're a project. Stage gating is the
  defense.

## Success metrics

- Zero "session existed but transcript is gone" entries filtered out by
  `find-sessions` for sessions <30 days old.
- p95 latency from `SessionEnd` hook to summary persisted: <60s.
- Daemon RSS steady-state: <50 MB.
- Daemon uptime ≥7 days under normal use without manual intervention.
- Picker content-search returns a relevant prior session in ≥80% of
  cases where the user knows one exists.
- Time spent grepping cache directories during debugging: zero.

## Decision

Not building this now. Capture as design direction. Hibernate
implementation in #45 stays in the bash-sleeper model with stage 0
(persistent target-timestamps + restart re-arm). Revisit this PRD when
transcript loss or findability becomes painful enough that the
operational cost of a daemon is the lesser evil.
