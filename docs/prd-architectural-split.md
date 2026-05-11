# PRD: split claude-rescue into a generic tmux layer + claude extension

Status: draft
Owner: TBD
Created: 2026-05-10

## Summary

claude-rescue currently mixes two distinct concerns: **generic tmux pane
lifecycle** (durable pane identity, capture-on-defocus, optional
hibernation primitives) and **claude-specific session management**
(session UUID tracking, busy-state markers from claude hooks, picker,
resume wrapper).

This PRD proposes splitting the implementation into two cleanly layered
projects, **coordinated by a central daemon that owns live state**:

- **`tmux-pane-rescue`** — a generic tmux plugin that gives every pane a
  durable identity and captures its scrollback on defocus. Hibernation
  primitives ship in the plugin as opt-in, per-pane capabilities — not
  default behaviors. Its event hooks and CLI commands are thin clients
  of the daemon; rich pane status (last capture, hibernation state,
  current foreground tree) is answered by the daemon.
- **`claude-rescue`** — the existing project, slimmed to claude-specific
  concerns. Becomes a consumer of `tmux-pane-rescue`, opts panes into
  hibernation when claude starts in them, and provides the session
  picker and resume tooling. Its picker and status commands query the
  daemon for rich live information about sessions (busy state,
  hibernation mode, transcript freshness, etc.).
- **`claude-rescue-daemon`** — the central authority on live state.
  Subscribes to pane lifecycle events from the tmux plugin and to
  session events from claude's hooks. Owns scheduling (hibernation
  timers, summarization queue, archival pruner). Exposes a unix socket
  RPC surface that both layers query for rich information. Detailed in
  the companion daemon PRD; this document covers how the split layers
  plug into it.

The daemon-centric framing is the load-bearing design choice. The two
layers are intentionally thin: they detect events, they execute pane
operations on demand (capture, send-keys), and they delegate every
decision and every rich query to the daemon. This is the same
single-authority discipline OpenAI's Symphony spec adopts; here it
extends across the layer boundary.

The split is not blocked work. The current implementation is converging
on stable; this PRD captures the right shape for the next refactor and
sets direction so future changes (the daemon PRD, the bash-sleeper
hardening) don't pull in the wrong direction.

## Problem statement

Three issues with the current single-project structure:

1. **Useful primitives are buried under a claude-shaped wrapper.**
   Capture-on-defocus + print-on-return is valuable for any long-running
   process in a tmux pane: tail-following server logs, supervising a
   training run, watching a deploy. Today it's reachable only by
   pretending you're a claude session.

2. **The macOS SIGSTOP/SIGCONT investigation wasn't a claude problem.**
   The bug we worked around (raw `kill -STOP` / `kill -CONT` doesn't
   survive tty-job-control re-stop on children) was a general tmux +
   POSIX issue. The fix (Ctrl+Z + fg via shell job control) is a tmux
   insight worth giving back to the community.

3. **Durable pane identity is a missing tmux primitive.** Tmux ships
   `@`-prefixed user options but no story for keeping them stable across
   crash + resurrect-restore. The sidecar-TSV approach we built is
   reusable for any plugin needing stable pane identity, not just for
   correlating claude sessions.

4. **Failure-mode debugging is muddled.** "Hibernation behaving
   strangely" today goes to "claude-rescue ate my pane." A split makes
   the failure surface honest: lower-layer issues are lower-layer
   issues, upper-layer issues are claude integration issues.

## Goals

- A generic tmux plugin owns pane lifecycle, identity, and capture.
- Hibernation primitives ship in the generic plugin **as opt-in**,
  configured per-pane.
- Capture-on-defocus ships as the **default** behavior in the generic
  plugin — universally useful, low-risk, lets crash-restore scenarios
  benefit immediately without any per-pane configuration.
- claude-rescue becomes a thin consumer of the generic plugin: it tags
  claude panes for hibernation, supplies the claude-specific exit-key
  sequence, registers a busy-state delay hook, and provides the
  session-aware picker.
- A daemon owns live state and scheduling. Both layers' event hooks
  publish to the daemon; both layers' rich-info commands query the
  daemon. Decisions (when to hibernate, when to defer, when to upgrade
  soft→hard) live in the daemon, not in shell scripts scattered across
  layers.
- Both layers gracefully degrade when the daemon is down: events fall
  back to direct JSONL writes (current behavior), rich-info commands
  report degraded mode. No data loss, only reduced live capability.
- Failure surfaces split cleanly between layers: pane-lifecycle bugs
  vs. claude-integration bugs vs. daemon bugs.
- The generic plugin is installable via TPM and useful as a standalone
  package — including when paired with the daemon to power rich
  status-line displays for non-claude panes.

## Non-goals

- Replacing tmux-resurrect or tmux-continuum **at this PRD's scope**.
  The generic plugin uses resurrect's hooks for sidecar persistence;
  it does not duplicate resurrect's scope. **Note:** a follow-up PRD
  (`prd-resurrect-absorption.md`) argues this non-goal should be
  revisited once the daemon and split are in place. The argument is
  that we've already customized both plugins extensively, and the
  daemon owns a richer state model than either provides. Treat the
  non-goal here as scope-limit for the split itself, not as a
  permanent commitment.
- Doing the split *now*. This PRD captures architectural direction;
  execution waits until the hibernation feature has real-world miles.
- Rewriting the picker as a generic tool. The session picker stays
  upper-layer (claude-rescue). The generic plugin *may* later grow a
  "browse pane captures" picker as a separate command, but that's not
  in this PRD's scope.
- Becoming a process manager. Hibernation primitives are mechanisms,
  not policies. Policy (when to hibernate, when to skip, when to
  escalate) lives in consumers — claude-rescue today, others if they
  want.
- Replacing claude itself or claude's hook surface.

## The split

### What goes where

| Concern                                        | Lower (`tmux-pane-rescue`) | Daemon (`claude-rescue-daemon`) | Upper (`claude-rescue`) |
|------------------------------------------------|----------------------------|---------------------------------|-------------------------|
| `@pane-uuid` minting + sidecar propagation     | ✓                          |                                 |                         |
| Pane event detection (focus-out/in, died)      | ✓ (publishes to daemon)    |                                 |                         |
| Pane operations (capture-pane, send-keys)      | ✓ (executes on daemon's request) |                            |                         |
| Live pane state (last capture, hibernation mode, foreground tree) |              | ✓ (authority)                   |                         |
| Scheduler: hibernation timers, defer logic     |                            | ✓                               |                         |
| Pane event log (durable JSONL backing store)   | ✓ (writes through, daemon owns the live view) | ✓                |                         |
| Capture-on-defocus + sidecar metadata          | ✓ (default ON, daemon notified) | ✓ (indexes captures live)  |                         |
| `pane-rescue print` / `pane-rescue status`     | ✓ (CLI surface; queries daemon when up) | ✓ (rich answers)   |                         |
| Soft hibernation (Ctrl+Z via terminal)         | ✓ (mechanism)              | ✓ (decision + scheduling, opt-in per pane) |                |
| Hard hibernation (configurable exit keys)      | ✓ (mechanism)              | ✓ (decision + scheduling, opt-in per pane) |                |
| Busy-state delay logic                         |                            | ✓ (consults busy markers; opt-in per pane) |                |
| Two-stage timer (soft → hard upgrade)          |                            | ✓                               |                         |
| Tmux hook installation (focus-out/in, resurrect) | ✓                        |                                 |                         |
| TPM packaging                                  | ✓                          |                                 |                         |
| Daemon RPC client library (Bash + small native helper) | ✓                  |                                 | ✓                       |
| Graceful degradation when daemon is down       | ✓ (direct JSONL write-through) |                             | ✓ (direct JSONL write-through) |
| Live session state, transcript freshness, summarization queue, archival tier |  | ✓                            |                         |
| `@claude-window-id` + window-level event log   |                            |                                 | ✓                       |
| Claude `session_id` from SessionStart hook     |                            |                                 | ✓ (publishes to daemon) |
| Session-attribution: pane_uuid ↔ session_id    |                            | ✓ (live join)                   | ✓ (durable record)      |
| Picker (session drill-down, resume actions)    |                            |                                 | ✓ (queries daemon for rich rows) |
| `claude-rescue-resume` wrapper for resurrect   |                            |                                 | ✓                       |
| Busy-marker writes from UserPromptSubmit/Stop  |                            |                                 | ✓ (publishes to daemon) |
| Per-pane hibernation enrollment when claude starts |                       | ✓ (state)                       | ✓ (publishes intent)    |
| Override hard-exit keys to `/exit\n`           |                            | ✓ (per-pane config)             | ✓ (declares intent at enrollment) |
| Transcript mirroring, summarization, archival  |                            | ✓                               |                         |

### The opt-in/opt-out distinction

This is the load-bearing detail of the split. Not all features in the
lower layer should be on for all panes.

**Default ON: capture-on-defocus.**

- Cheap (one `tmux capture-pane` call when focus changes).
- Universally useful — crash-restore scenarios benefit, even for users
  who never explicitly opt in.
- No side effects on the pane's running process. Pure observation.
- Disk cost bounded (one capture file per pane, overwritten on each
  defocus or on a configurable interval).

**Default OFF, opt-in per-pane: soft hibernation, hard hibernation,
busy-state delay.**

- These actively suspend or terminate the pane's foreground process.
- For a pane running `tail -F /var/log/app.log`, soft hibernation is
  exactly wrong — the user wants to come back to a live tail, not a
  Ctrl+Z'd one. Hard hibernation that sends `/exit` to a process that
  doesn't know what that means is worse.
- Must be opt-in. Mechanism: a tmux pane option set when the consumer
  wants this pane managed. Concretely:

  ```tmux
  # Enable soft hibernation on this pane after 60min defocus
  set-option -p @pane-rescue-soft-delay 3600

  # Enable hard escalation 24h after focus-out (soft must also be enabled)
  set-option -p @pane-rescue-hard-delay 86400

  # Custom exit key sequence for hard hibernation (default: "C-c C-c")
  set-option -p @pane-rescue-hard-exit-keys "/exit Enter"

  # Path to a busy marker file. If present AND fresh
  # (mtime < @pane-rescue-busy-freshness), skip hibernation.
  set-option -p @pane-rescue-busy-file "$XDG_CACHE_HOME/claude-rescue/busy/<uuid>"
  set-option -p @pane-rescue-busy-freshness 1800
  ```

  claude-rescue sets these per-pane in its `SessionStart` handler. A
  user running `tail -F` sets nothing — defocus captures scrollback but
  the pane stays running.

- For users who *do* want hibernation on non-claude panes (heavy IDE
  daemons, idle dev servers), the mechanism is available: set the pane
  options manually, possibly via a wrapper command (`pane-rescue
  enroll --soft 3600 --hard 86400`).

### Architecture: how the layers talk

**The daemon is the spine.** Both layers' event-detection hooks publish
to the daemon over a unix socket; both layers' rich-info commands query
the daemon over the same socket. The layers themselves are deliberately
thin and stateless except for their fallback durability path.

**Event flow (daemon up — the normal path):**

1. tmux fires `pane-focus-out` on pane `%N`.
2. Lower layer's hook sends a JSON message to the daemon:
   `{"kind":"pane.focus_out", "pane_uuid":"…", "tmux_pane":"%N",
   "pane_pid":12345, "ts":"…"}`. It also synchronously runs `tmux
   capture-pane` and writes the scrollback to disk (default-ON
   capture; the daemon is informed but not required for capture
   execution).
3. The daemon receives the event, joins it with current state
   (session enrolled? busy marker fresh? soft delay set?), and decides
   what to schedule. If hibernation is opted in and not deferred, the
   daemon enqueues a timer.
4. When the timer fires, the daemon RPCs to the lower layer (via a
   short-lived `tmux send-keys` invocation it spawns directly): "send
   `C-z` to pane %N". The lower layer's only role at this point is to
   execute pane operations on demand — it has no scheduler of its own.
5. The daemon records the state transition (`pane_uuid:hibernated
   mode=soft`) and updates its live view. Subsequent queries from any
   client see the new state immediately.

**Query flow (daemon up):**

The picker, status-line displays, and `pane-rescue status` commands
all RPC to the daemon for rich information rather than re-reading
JSONL. Example: `claude-rescue` picker rendering a session row asks
the daemon "for window W, give me each session's current state (busy?
hibernated? transcript age?)". The daemon answers from its in-memory
index. No JSONL parsing per keystroke.

**Tmux status-line integration** (future use case the daemon unlocks):
the user's tmux status-line can call `pane-rescue status -p
#{pane_id}` which returns a one-line summary (`active`, `hibernated:
soft`, `idle 23m`). The daemon answers in microseconds; the
status-line stays responsive.

**Graceful degradation (daemon down):**

Both layers detect daemon-unreachable (socket connect fails or times
out fast) and fall back to **direct JSONL write-through**. Events go
to:

- `$XDG_DATA_HOME/tmux-pane-rescue/panes/<pane-uuid>.jsonl` (lower)
- `$XDG_DATA_HOME/claude-rescue/windows/<window-uuid>.jsonl` (upper)

Rich-info commands degrade to "best-effort from disk" mode — they
read the JSONL files and reconstruct what they can, but they cannot
answer questions about live state (e.g. "is this pane currently
running an active timer?" is unanswerable when no scheduler is
running). The picker still functions; preview rows are tagged
`(degraded)` when the daemon was unreachable.

When the daemon comes back up, it replays recent JSONL appends to
rebuild its in-memory index from the durable backing store, then
resumes operation. No data is lost during the gap; only live
capabilities (scheduling, summarization, suggestions) pause.

**Why daemon-favored is the right shape:**

- **Single authority avoids races.** Today's bash-sleeper-per-pane
  model already breaks when two focus-out events arm overlapping
  timers; the daemon's queue is a single mutator.
- **Both layers benefit symmetrically.** The same RPC surface that
  powers claude-rescue's session picker also powers
  `pane-rescue status` for a tail-following terminal. Each layer gets
  richer the more state the daemon accumulates.
- **Tmux-side hooks unlock real status-line use cases.** A
  `#{pane_id}`-keyed query from the status-line is a feature
  impossible to provide responsively from cold JSONL.
- **The daemon PRD already commits to this surface.** Building the
  split atop the daemon's unix socket avoids inventing a second IPC
  for cross-layer coordination.

### Tmux hook ownership

The lower layer installs all pane-related tmux hooks:

- `pane-focus-out` → capture scrollback + (if opted in) arm soft timer
- `pane-focus-in` → (if opted in) cancel arm + fg suspended job
- `client-detached` → log; consumers can subscribe
- `@resurrect-hook-post-save-layout` → write `@pane-uuid` sidecar
- `@resurrect-hook-pre-restore-pane-processes` → re-apply
  `@pane-uuid` from sidecar before resurrect respawns processes

The upper layer installs only claude-related hooks via Claude Code's
`settings.json`:

- `SessionStart` → record session_id, set the pane-rescue opt-in
  options on the pane
- `SessionEnd` → record session_end
- `UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Stop` → maintain
  busy marker file

If the upper layer is absent, the lower layer still works (and any pane
that ran claude before keeps its captures available). If the lower
layer is absent, the upper layer degrades to file-only event logging
without pane identity or capture.

## Capabilities by layer

### Lower layer: `tmux-pane-rescue`

The lower layer is a **thin event source + on-demand pane operator.**
It detects pane lifecycle events, publishes them to the daemon, and
executes pane operations (capture, send-keys) when the daemon asks.
Scheduling and policy live in the daemon.

1. **Durable pane identity.** `@pane-uuid` minted on first pane-focus-out
   for any pane (or on first explicit opt-in, configurable). Propagated
   across kill/restore via resurrect sidecar (5-column TSV: type, key,
   value, ts, source).

2. **Event publisher.** Pane lifecycle events (focus-out, focus-in,
   died) RPC to the daemon over the unix socket. Each event also
   writes to a durable JSONL backing store so the daemon can replay
   after a restart. If the daemon is unreachable, the JSONL write is
   the only effect (graceful degradation).

3. **Capture-on-defocus (default ON).** Every focus-out synchronously
   runs `tmux capture-pane -peJ -S -` and writes the scrollback to
   `$XDG_DATA_HOME/tmux-pane-rescue/captures/<pane-uuid>.txt`. Sidecar
   JSON records ts, cwd, foreground process tree. The capture is
   executed by the lower layer (no daemon round-trip needed for the
   actual capture); the daemon is notified post-write so it can index
   the new capture.

4. **Pane operations on demand.** Exposes a `pane-rescue exec` surface
   the daemon can drive (`pane-rescue exec send-keys %N "C-z"`,
   `pane-rescue exec capture %N`). These are thin wrappers around
   `tmux send-keys` / `tmux capture-pane` that exist so the daemon can
   trigger them without spawning tmux itself in unusual environments.

5. **CLI surface (queries the daemon when up):**
   - `pane-rescue status [-p pane_id]` — rich live status for one pane
     or all panes (active/hibernated/idle, last capture age, opt-in
     state, foreground command). Answered by the daemon.
   - `pane-rescue print [uuid]` — cats the saved capture; pure
     filesystem read, no daemon needed.
   - `pane-rescue enroll [--soft S] [--hard H] [--exit-keys K] [--busy-file F]`
     — opts a pane into hibernation. Sets tmux pane options AND
     informs the daemon so the scheduler picks up the new opt-in
     immediately.
   - `pane-rescue gc` — remove captures for panes that no longer
     exist; coordinated with the daemon's pane registry to avoid
     deleting captures the daemon is still tracking.

6. **Status-line helper.** A documented format snippet
   (`#(pane-rescue status -p #{pane_id} --short)`) for users who want
   pane-rescue state in their tmux status-line. Cheap because the
   daemon answers from memory.

### Daemon: `claude-rescue-daemon`

The daemon is the authority on live state. Detailed in the companion
daemon PRD. Its responsibilities **relevant to this split**:

1. **In-memory state model.** A live join of (pane lifecycle from
   tmux-pane-rescue) × (session lifecycle from claude-rescue). Every
   subscriber can ask "for pane X, what's the current state across
   both layers?" and get one answer.

2. **Scheduler.** Hibernation timers live here (not in bash sleepers).
   On `pane.focus_out`, the daemon enqueues an event. On the configured
   delay, it consults busy markers, opt-in state, and current focus,
   then either fires hibernation (by RPC'ing the lower layer to send
   keys) or skips. Two-stage soft→hard upgrade is one priority queue
   walking forward in time.

3. **Rich query API.** Unix socket RPC surface for both layers. Examples:
   - `pane.status pane_uuid=…` → live state object
   - `session.status session_id=…` → busy, hibernated, transcript path
   - `window.list` → all windows with embedded session summaries
   - `pane.events pane_uuid=… since=…` → event stream replay

4. **Backing-store ownership.** The daemon writes events to the JSONL
   files both layers also read in their degraded mode. This keeps the
   durable store consistent across daemon-up and daemon-down periods.

5. **Bootstrap from JSONL on cold start.** Replays recent events from
   both layers' JSONL files to rebuild in-memory state before
   accepting RPCs. Older events are not loaded — the picker reads
   JSONL directly for deep history.

### Upper layer: `claude-rescue` (slimmed)

The upper layer is the **claude-specific extension.** It publishes
claude events to the daemon and presents claude-aware UIs.

1. **Session identity publishing.** `SessionStart` and `SessionEnd`
   hooks RPC to the daemon. The daemon performs the pane_uuid ↔
   session_id join in its live model.

2. **Hibernation enrollment on `SessionStart`.** The hook calls
   `pane-rescue enroll --soft … --hard … --exit-keys "/exit Enter"
   --busy-file …` which (via the lower layer) sets pane options and
   informs the daemon.

3. **Busy marker writes.** Pre/Post/UserPromptSubmit hooks touch the
   busy file the daemon consults. (The marker file is the cross-layer
   contract: lower layer's scheduler doesn't know what "claude" is,
   only "this pane has a busy-file; if fresh, skip hibernation.")

4. **Picker.** Window/session drill-down. Each row's live status
   (busy/hibernated/transcript fresh) is queried from the daemon as
   the user navigates. Capture preview uses `pane-rescue print`.

5. **Window-level event log + meta rollups.** Same as today for the
   durable record, minus pane-lifecycle events which migrate to the
   lower layer's log.

6. **`claude-rescue-resume` wrapper** for resurrect process
   restoration. Unchanged in behavior; informed by daemon state if
   available.

7. **Daemon-powered "rich session info"** is the user-visible upgrade.
   Today the picker shows whatever is in `meta.json`; with the daemon,
   it can show "currently mid-response", "hibernated 12m ago, soft",
   "transcript pruned by Claude, mirrored copy available", "summary:
   …", "tags: refactor, auth". All from one RPC per row.

## Migration plan

The split is sequenced **behind** the daemon's introduction. Building
the daemon first means the split can be done atop its RPC surface
instead of inventing cross-layer coordination twice. Each stage is
shippable independently.

### Stage 0: stabilize current implementation

Continue current trajectory in the single `claude-rescue` repo:
hibernation hardening, bash-sleeper target-timestamp persistence
(Stage 0 from the daemon PRD), validate in production. Do not split
mid-stabilization.

### Stage 1: daemon arrives

Ship the daemon per the daemon PRD's stages 1–2. At this point the
daemon is a single binary running alongside the existing
`claude-rescue` codebase, owning scheduling and live state, with
graceful fallback to JSONL when the daemon is down. **No split yet.**
Existing event hooks become daemon clients.

This stage is the prerequisite for the rest. Doing the split first
would force inventing an inter-layer IPC that the daemon's socket
would then replace.

### Stage 2: in-place factor

Within the `claude-rescue` repo, isolate the lower-layer code into a
single directory (`lib/pane-rescue/`, `bin/pane-rescue`, `tmux/
pane-rescue.conf`). Treat that directory as if it were a separate
project: no upward dependencies on claude-specific code, all
pane-uuid-keyed state. Both the lower-layer code and the upper-layer
code talk to the daemon over the same socket; they don't talk to each
other directly.

Behavior identical to Stage 1. This is the "make the split obvious
before doing it" stage. Catches anywhere the layers are currently
entangled and ensures the daemon's RPC surface covers every
cross-layer query.

### Stage 3: split repo

Extract `tmux-pane-rescue` to its own repo. Publish on GitHub. Make
TPM-installable. claude-rescue's installer learns to require
`tmux-pane-rescue` as a sibling install. The daemon stays in the
claude-rescue repo (its primary value is claude session management;
tmux-pane-rescue users without claude get a useful subset of features
that don't require it).

Backwards compat for existing claude-rescue users: their event logs
already include `pane_uuid`. The split reads the same options
(`@claude-pane-id` → renamed to `@pane-uuid` with a back-compat
alias). Capture files move from `$CLAUDE_RESCUE_DATA_HOME/captures/`
to `$XDG_DATA_HOME/tmux-pane-rescue/captures/` with a migration step
in the installer.

### Stage 4: claude-rescue uses upstream

claude-rescue's `bin/claude-rescue-log` no longer implements pane
lifecycle, capture, hibernation, or `@pane-uuid` plumbing — those come
from `tmux-pane-rescue`. claude-rescue calls `pane-rescue enroll` on
SessionStart and queries the daemon for rich session state.

### Stage 5: daemon-aware tmux-pane-rescue features

Now that `tmux-pane-rescue` and the daemon are both in the wild,
extend the plugin with daemon-powered features that don't require
claude:

- `pane-rescue status` returns rich state for any pane (cwd history,
  last capture age, opt-in summary, current foreground process tree).
- Documented status-line snippets (`#(pane-rescue status --short -p
  #{pane_id})`) for users who want pane state in their tmux bar.
- Cross-pane queries: `pane-rescue list --hibernated`, `pane-rescue
  list --idle 1h`.
- Optional `pane-rescue browse` — a generic picker for captures
  across all panes (separate from claude-rescue's session picker).

### Stage 6: optional polish

- Public docs and examples for non-claude use cases.
- Maybe-PR for upstream tmux to consider `@pane-uuid` style identity
  as a built-in feature (probably won't happen, but worth proposing).

## Open questions

- **Naming.** `tmux-pane-rescue` is OK but clashes with `claude-rescue`.
  Alternatives: `tmux-pane-memory` (captures the print-on-return idea),
  `tmux-pane-archive`, `tmux-pane-sidekick`, `tmux-pane-keeper`. I lean
  `tmux-pane-memory` for clarity of purpose, `tmux-pane-rescue` for
  continuity. No strong vote yet.

- **Daemon RPC schema versioning.** Both layers will be at different
  release cadences than the daemon. Need a versioned wire format with
  forward/backward compat rules. Lean: messages carry a `v` field,
  daemon refuses messages with `v > server_v`, clients log+ignore
  unknown reply fields.

- **Daemon socket path.** Shared between two repos. Convention:
  `$XDG_RUNTIME_DIR/claude-rescue-daemon.sock`, falling back to
  `$XDG_CACHE_HOME/claude-rescue/daemon.sock`. Both layers read the
  same env var (`CLAUDE_RESCUE_DAEMON_SOCK`) for override. Documenting
  this contract is daemon-PRD work but it affects this split.

- **Default capture interval / disk cost.** Capture-on-defocus is one
  write per focus-out. For users who flip between many panes rapidly,
  that's a lot of writes. Need a debounce or coalesce: "don't re-capture
  if last capture was <N seconds ago." Tunable, default ~30s.

- **Capture file size cap.** A user with tmux `history-limit` 50000 and
  a chatty pane could produce multi-megabyte captures. Should the lower
  layer cap at a configurable size (e.g. last N lines) by default? Lean
  yes — default 2000 lines, override with `@pane-rescue-capture-lines`.

- **Per-pane vs per-window enrollment.** `@pane-uuid` is pane-scoped.
  Enrolling all panes of a window in hibernation requires walking the
  window. Should the plugin support `@pane-rescue-soft-delay` at window
  scope as a default, with pane-scope override? Lean yes — matches how
  most tmux options work.

- **TPM vs install script.** TPM is conventional for tmux plugins. But
  `tmux-pane-rescue` needs to symlink binaries into `~/.local/bin/` for
  the `pane-rescue` command to be on PATH. TPM doesn't handle that
  natively. Either: TPM for the tmux config bits + a separate
  `install.sh` for the binaries, or skip TPM and require a shell
  install. Lean the hybrid.

- **Should the lower layer have its own picker?** Not in v1. Capture
  + print is enough surface for general users. A `pane-rescue browse`
  command lands in Stage 5 once the daemon's rich-query API is
  available; without the daemon it'd be JSONL grep which is bikeshed-
  prone (what axes? by cwd? by command? by recency?).

- **Coordinating opt-in for SessionStart-driven enrollment with
  resurrect-restore.** When resurrect restores a claude pane,
  `SessionStart` fires; claude-rescue calls `pane-rescue enroll`; but
  the pane is already running. Need to make `pane-rescue enroll`
  idempotent and safe to call against an already-enrolled pane.

- **Backwards-compat with existing claude-rescue data.** Sidecar TSV
  formats, event log schemas, option names. The split should not
  invalidate any current user's data. Migration is read-old, write-new,
  and a fallback path for tools that haven't migrated.

- **Can `tmux-pane-rescue` be useful *without* the daemon?** Yes —
  capture-on-defocus + `pane-rescue print` work entirely from
  filesystem, no daemon required. Hibernation primitives technically
  work in a degraded "no busy-defer, no hard-upgrade scheduling" mode
  via the bash-sleeper fallback. The marketing for the plugin should
  be honest: "useful standalone, more useful with the daemon."

## Risks

- **More moving parts.** Two installs, one daemon, two configs, two
  repos. The current single-install story is a real strength of
  claude-rescue — copy/paste a few lines into chezmoi and it works.
  The daemon-centric design pushes this further. Mitigation: graceful
  degradation (no daemon, no problem for the basic features); the
  install script bootstraps the daemon at first use rather than
  requiring manual setup.

- **Versioning drift across three projects.** Lower layer, upper
  layer, daemon — each can move at its own pace. RPC schema versioning
  is the main contract; tmux options are the secondary contract.
  Mitigation: semver all three conservatively, daemon refuses
  incompatible client versions with a clear error, document the
  contract explicitly in a `PROTOCOL.md` shared between repos.

- **Daemon down means degraded rich features.** Status-line snippets
  show stale data, the picker can't tell you what's currently busy,
  hibernation timing falls back to the bash-sleeper fallback. The user
  experience differential between "daemon up" and "daemon down" is
  large enough to be a real risk if the daemon flakes. Mitigation:
  watchdog (launchd/systemd respawn), structured logging, the
  introspection CLI surfaces daemon health prominently.

- **Surface for unrelated feature requests.** Publishing a generic
  tmux plugin invites issues like "can you add Discord notifications
  when a pane is hibernated" or "hibernation policy based on system
  memory." Need to be willing to say "this is a mechanism plugin, not
  a policy manager" repeatedly — though some of these requests are
  legitimate daemon features and might get routed there.

- **Refactor cost.** A non-trivial amount of code to move across
  repos and a daemon to build alongside it. Mitigation: the
  daemon-first ordering means the IPC surface is settled before any
  cross-repo work happens, so the split itself is mostly mechanical.

- **Default-ON capture is a behavior change for current users.**
  Today capture only fires on hibernation. Default-ON capture on every
  focus-out means more disk activity and slightly different semantics
  ("capture is always current" vs "capture is the last hibernation
  snapshot"). Mostly an improvement, but worth documenting in the
  release notes.

## Success metrics

- claude-rescue's codebase shrinks by ≥40% (lines of bash) when the
  lower layer is extracted, with no loss of functionality.
- `tmux-pane-rescue` is independently useful: at least one documented
  non-claude use case (e.g. preserve scrollback for `tail -F` panes
  across crashes) with a recipe in the README.
- Bug reports stop hitting claude-rescue for issues that are actually
  pane-lifecycle bugs.
- Capture file disk usage stays within a configurable budget per user
  (default ≤500MB, tunable).
- p95 latency from `pane.focus_out` event to daemon-confirmed
  scheduling: <50ms.
- p95 latency for picker row rich-info query (`session.status`):
  <10ms.
- Picker shows rich live state (busy/hibernated/transcript-fresh) for
  ≥95% of rows when daemon is up.

## Decision

Not building this now. Capture as architectural direction for the
next major refactor. Sequence:

1. **Daemon first** (daemon PRD stages 0–2): the IPC surface and
   live-state model must exist before the split can plug into it.
2. **In-place factor** (Stage 2 above): rearrange code without
   splitting repos, with both halves talking through the daemon.
3. **Split repo** (Stage 3 above): mechanical extraction once Stage 2
   shows the boundary is clean.
4. **Daemon-aware lower-layer features** (Stage 5 above): unlock the
   tmux-side rich queries that motivated this PRD's revision.

The right moment for any of this is after hibernation has logged
real-world miles and the file layout has stopped moving. The
daemon-favored framing means the eventual split inherits a coordinated
state model rather than two layers awkwardly file-tailing each other.
