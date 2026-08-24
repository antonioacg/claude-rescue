# claude-rescue — domain glossary

Names for the concepts this codebase is built around. Use these terms in
code comments, docs, and commit messages; when a new concept earns a helper
or a file, add it here.

## Identity

- **Pane UUID** — the durable identity of a pane, minted once and stored as
  tmux option `@claude-pane-id`. Survives server restarts via the resurrect
  sidecar. Everything durable (markers, captures, active files, event
  attribution) is keyed by pane UUID, never by tmux's recycled `%N` pane id.
- **Active session file** — `$DATA/active/<pane_uuid>`: which claude
  session id the pane currently holds open. Written by every SessionStart
  (including in-claude `/resume`); the resume wrapper's priority-1 lookup.
- **Epoch** — one tmux server generation. Pane ids (`%N`) RECYCLE across
  epochs; pane UUIDs don't. Any state keyed by pane id must be
  epoch-guarded: swept on resurrect-restore (arm.pids, title cache),
  scoped by server PID (post-restore claims, watcher state), or re-verified
  live before acting (`arm_still_authoritative`). State that must survive
  epochs is keyed by pane UUID instead (markers, captures, active files).

## State ownership

- **State Owner** — the single-writer process behind
  `claude-rescue-state`. It serializes durable History Events into SQLite
  and exposes a local Unix-socket Interface for publishing and queries.
  Shell hooks never open the database directly.
- **History Event** — an immutable, idempotent state transition committed
  by the State Owner. Each carries an event id, source, kind, occurrence
  time, optional Epoch / Pane UUID / session id, and a JSON payload. Commit
  sequence, not wall-clock time, defines durable ordering.
- **Outage spool** — `$DATA/state/spool/`: atomically-written History Events
  waiting for the State Owner. The publisher writes here when the socket is
  unavailable; replay is at-least-once and event-id deduplication makes it
  effectively exactly-once in the journal.
- **Recovery Checkpoint** — a completed tmux-resurrect save retained for
  crash recovery, not used as the History Event model. The State Owner indexes
  checkpoints and applies bounded tiered retention: dense recent recovery,
  progressively coarser older recovery, then expiry.
- **Archive spool** — `$DATA/state/archive-spool/`: hardlinked checkpoint
  inputs waiting for the State Owner. It preserves the checkpoint and paired
  pane contents without allowing a save hook to write the archive index.

## Hibernation

- **Hibernation** — freeing resources held by an idle claude pane. Two
  stages: **soft** (Ctrl+Z suspend after `SOFT_DELAY`) and **hard** (`/exit`
  after `HARD_DELAY`; claude fully gone, shell prompt holds the pre-fill).
- **Forced hibernation** — the on-demand path (`prefix+a` popup →
  `hibernate-now`): skips delays, guards, and the Ctrl+Z/fg dance; goes
  straight to hard. Its in-flight marker carries `forced: true`, which makes
  focus-in a no-op (claude is live until `/exit` lands — see the marker
  phase table in `cmd_hibernate_resume`).
- **Hibernation marker** — `$CACHE/hibernated/<pane_uuid>.json`, the single
  source of truth for a pane's hibernation state
  (`{mode, forced?, hard_source?, hard_ts?, pids[]}`). Access it only via
  `hibernated_marker_path` / `hibernated_marker_field` (lib/common.sh).
  A hard marker is **crash-restore insurance**: it survives focus-in and is
  cleared only by SessionStart (claude actually came back) or pane death.
- **Arm subshell** — the detached, HUP-immune subshell that holds the
  soft→hard timers and executes the hibernation pipeline. Its pid lives in
  `$CACHE/hibernated/<sanitized_pane_id>.arm.pid`; it re-verifies its own
  authority (`arm_still_authoritative`) before every side effect.
- **Crash-promote** — on restore after a server death, soft markers are
  rewritten to hard with `hard_source: "crash-promote"`: the suspended
  claude died with the server, and the resurrect wrapper (not keystrokes)
  brings it back. Crash-promoted panes must never receive injected keys.

## Capture & peek

- **Capture** — the pane-scrollback snapshot taken at hibernation time:
  `$DATA/captures/<pane_uuid>.txt` (ANSI content) + `.json` (meta:
  session_id, cwd — *last-active*, not launch — pids, ts). Access via
  `capture_txt_path` / `capture_meta_path` / `capture_meta_field`
  (lib/common.sh), same rule as the hibernation marker.
- **Paint / the peek** — replaying the capture into a pane at the shell
  (`claude-rescue print`) so the user can see what the session was without
  resuming it. Needed because claude runs on the terminal's alternate
  screen: after `/exit` or a crash-restore, the session's last screen is
  otherwise not visible.
- **Pre-fill (resume recipe)** — `clr <sid>` (post-restore: anchored as
  `cd <launch-cwd> && clr <sid>`) typed at the shell prompt with **no
  Enter**: live readline input the user reviews and executes. Not captured
  by tmux-resurrect, hence the marker-survival rules above.

## Keystroke injection

- **Enter discipline** — the invariant from the 2026-06-05 RCA
  (docs/operations/rca-2026-06-05-restore-keystroke-race.md): any
  Enter-terminated injection carries its own leading C-u in the SAME atomic
  `send-keys` call, so the Enter can only ever submit exactly the intended
  line. Applies to both targets we inject into — a shell prompt (C-u wipes
  stray readline input) and claude's input box (C-u clears a leftover draft
  so `/exit` or `fg` lands clean). Enforced by `send_enter_burst`
  (lib/common.sh) — never send `<text> Enter` through raw
  `send_keys_logged`.
- **Shell gate** — only inject executing keystrokes when the pane's
  foreground is an interactive shell. Single authority: `is_shell_cmd`
  (lib/common.sh).
- **Injection log** — every internal `send-keys` goes through
  `send_keys_logged`, which records reason, pane, foreground command, and
  claudes-in-subtree to `$DATA/send-keys.log`. The forensic backbone for
  every keystroke incident so far.

## Process inspection

- **Pane subtree walk** — BFS over `pgrep -P` from a pane's root pid to find
  claude processes living under it. Single implementation: `subtree_pids`
  (lib/common.sh).
- **Busy marker** — `$CACHE/busy/<pane_uuid>`, mtime-freshness file
  maintained by Claude Code hooks (UserPromptSubmit/Pre|PostToolUse/Stop);
  `is_busy` gates hibernation so a mid-task claude isn't suspended.
