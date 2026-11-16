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
- **Watcher Adapter** — one native process per tmux server. It obtains one
  consolidated pane snapshot per tick, detects lifecycle/title/activity
  changes in-process, publishes Captures through the State Owner, caches status
  labels as window options, and schedules Recovery Checkpoint due-checks away
  from status redraws. Keeping this Adapter per server preserves tmux socket
  locality without coupling the global State Owner to any one tmux environment.
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
- **Crash-promote** — on restore after a server death, every pane the
  snapshot shows resurrect relaunching through the wrapper gets a hard marker
  with `hard_source: "crash-promote"` (a soft marker is promoted; a pane with
  none gets one). The wrapper, not keystrokes, brings it back, so
  crash-promoted panes must never receive injected keys while the relaunch is
  in flight. Every other marker becomes plain hard and is pre-filled. If the
  relaunch dies before SessionStart clears the marker (the wrapper's
  `relaunch_pid` is gone), the restore's watch demotes it and pre-fills it.

## Capture & peek

- **Capture** — the pane-scrollback snapshot taken at hibernation time:
  `$DATA/captures/<pane_uuid>.txt` (ANSI content) + `.json` (meta:
  session_id, cwd — *last-active*, not launch — pids, ts). Access via
  `capture_txt_path` / `capture_meta_path` / `capture_meta_field`
  (lib/common.sh), same rule as the hibernation marker.
- **Capture Blob** — content-addressed watcher output under
  `$DATA/captures/blobs/<sha256>.txt`, written by the State Owner. Identical
  pane content is stored once even when observed repeatedly or across Epochs.
- **Capture Reference** — a semantic historical link from a Pane UUID and
  Epoch to a Capture Blob (title/activity/visibility/create). Floor polling
  updates the current Capture but does not create history. References use
  dense recent and hourly older retention; current Captures are protected.
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

## Transcript corpus

- **Transcript corpus** — claude's *own* session files, at
  `$CLAUDE_PROJECTS_DIR/<slug>/<session_id>.jsonl` (slug per
  `encode_cwd_for_projects`). Distinct from our History Events: the corpus is
  written by claude, covers sessions we never observed, and is the only place a
  session's model is recorded. Read it through the `model` / `latest` /
  `resume-dir` subcommands, never by re-deriving paths at the call site.
  Only `<slug>/<sid>.jsonl` is resumable — subagent transcripts live at
  `<slug>/<sid>/subagents/agent-*.jsonl` and `claude --resume` rejects their
  `agent-*` stems, so every corpus glob is deliberately single-level.
- **Model repair** — re-adding the `[1m]` suffix that `--resume` drops behind a
  non-first-party `ANTHROPIC_BASE_URL` when the session model differs from
  settings.json's `model` (upstream anthropics/claude-code#93021): the session
  silently returns with a 200K context window instead of 1M. `claude-rescue
  model <sid>` reads every model a transcript names — `attachment.type=model`
  (the configured id at process start, but NEW, so older sessions lack it),
  `attachment.*.model` such as `batching_reminder_sent` (the configured id,
  suffix intact, present throughout the history), and `message.model` (the API
  echo, which gives the chronological last model but always strips the suffix).
  Base comes from the LAST id, so an in-session switch is honoured, and `[1m]`
  is re-added only when THAT SAME base was seen carrying it — per-base
  evidence, because an invalid model id fails the resume outright, which is
  worse than the 200K it was fixing. The suffix is the only thing ever added,
  so the repair can restore a window the session demonstrably had but never
  changes which model it runs. Only sessions whose model differs from
  settings.json's `model` are affected at all: with the two equal, resume keeps
  the window (measured). It feeds
  `--model` on the `clr` resume path. Best-effort by contract: it sits in the
  Pre-fill path, so every failure is empty stdout and exit 0, and the caller
  resumes exactly as it did before the repair existed.
- **Pane labels** — what a hard-hibernated pane tells other tools: pane
  options `@claude-session-id` (the session its `clr <sid>` pre-fill resumes)
  and `@claude-state hibernated`, set exactly while the pane's Hibernation
  marker is hard (`label_pane`, re-derived at every hard transition and healed
  by arm-sweep). The session picker that used to live here moved to the
  dotfiles' Session Radar (prefix+S, and `clr`/`clrf`), which has no tie to
  this repo: it reads these labels to show a hibernated pane as asleep and go
  to it, rather than resuming its conversation a second time.
- **Resume dir** — the directory a session belongs to, i.e. the one whose slug
  holds its jsonl (`resume_dir_for_session`, exposed as `resume-dir`). A
  resumed session runs with the *shell's* cwd, so resuming from elsewhere
  points it at the wrong project — wrong CLAUDE.md, wrong relative paths.
  Resolution is not at stake: verified on claude 2.1.257, `claude -r <sid>`
  finds a session from any directory. A candidate is only ever accepted when
  the session's jsonl exists under its slug, which is what makes the lossy
  reverse of `encode_cwd_for_projects` unnecessary.
- **Purge guard** — `bin/claude-rescue-purge-guard`, started hourly by the
  default server's Watcher Adapter. Claude Code deletes a transcript nobody
  has written to for its `cleanupPeriodDays`, and a hard-hibernated pane never
  writes to its conversation. So a conversation a hard pane holds is *due*
  `CLAUDE_RESCUE_PURGE_LEAD_DAYS` (14) before that, unless a live Claude Code
  holds it. Due conversations are archived one at a time: the transcript is
  copied, a fresh headless `claude -p` (safe mode, no session saved, Opus 1M,
  read-only tools plus writing `summary.md`) reads the copy and writes the
  summary, and the pane is closed. The conversation itself is never touched,
  and Claude Code deletes it on schedule. `archive <sid>` does the same on
  demand; `summarize <sid>` rewrites a summary from the archive's copy.
- **Session archive** — `$DATA/session-archive/<sid>/`: `transcript.jsonl` (the
  copy, as found), `session-files/` (subagents, saved tool results),
  `summary.md`, `run.log`, `meta.json` (`status`: copied, summarizing,
  archived, failed; `pane_closed`). Its `transcript_mtime` is the transcript as
  copied; while the transcript still matches, the conversation is never due
  again. `lib/transcript-render.jq` is how the summarizer pages through a copy.
