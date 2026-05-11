# Hibernation

Two-stage focus-driven pane suspension. Capture is the universal first step;
suspension method depends on how long the pane has been defocused.

## What starts the countdown

Two paths arm the per-pane hibernation timer:

1. **`pane-focus-out`** — fires when the currently-focused pane in some client
   loses focus (e.g., you switch windows or press into a different pane).
   Arms only the pane that just lost focus.
2. **`client-attached` / `client-session-changed`** — runs `arm-sweep`, which
   walks every pane and arms each claude pane that isn't currently focused.
   Without this, panes that are inactive-in-window — or that you never
   physically visited since attach — would sit forever without a countdown,
   because `pane-focus-out` only fires on transitions of the *active* pane.

Both paths invoke `cmd_hibernate_arm` with the same idempotent existing-timer
check, so a sweep that runs after a focus-out won't reset an already-running
timer.

## Model

```
focus-out
   │
   ▼
   ┌─ wait CLAUDE_RESCUE_SOFT_DELAY ─┐
   │      (default 60 min)            │
   │                                  ▼
   │                          busy? ──Y──► defer up to N×T, then skip
   │                            │
   │                            N
   │                            ▼
   │                    capture pane scrollback
   │                            │
   │                            ▼
   │                  send-keys C-z → SIGTSTP via tty
   │                            │
   │                            ▼
   │              marker: mode=soft, claude in T state
   │                            │
   ▼                            ▼
focus-in              wait CLAUDE_RESCUE_HARD_DELAY total
   │                            │
   ▼                            ▼
hibernate-resume:         send-keys "fg" Enter → "/exit" Enter
  read marker                   │
  mode=soft → fg<CR>            ▼
                delete    (fallback) SIGTERM → SIGKILL
                marker          │
  mode=hard → no-op             ▼
                (marker  send-keys "clr <sid>" (no Enter)
                survives)       │
                                ▼
                       marker: mode=hard
                       (cleared by session_start
                        when claude restarts in pane,
                        or pane_died for orphans)
```

### Why Ctrl+Z, not `kill -STOP`?

Raw `kill -STOP` followed by `kill -CONT` does NOT restore the tty foreground
process group via `tcsetpgrp`. After CONT, claude (and its child uv/python)
can immediately re-stop on TTIN/TTOU when reading from the controlling tty.
Empirically reproduced: SIGSTOP+SIGCONT leaves claude+children stuck in `T`.

`tmux send-keys C-z` writes the literal SUSP byte; the tty driver sends
SIGTSTP to the foreground process group, the shell takes terminal control,
and `fg` later does both SIGCONT and `tcsetpgrp` — children resume cleanly.

### Why `/exit` for hard, not Ctrl+C × 2?

claude's TUI catches Ctrl+C as "interrupt current op", not "exit". `/exit` is
claude's slash command for graceful shutdown — fires SessionEnd, flushes the
transcript, prints the resume hint. The fallback ladder (SIGTERM → SIGKILL)
runs only if `/exit` doesn't exit within ~3s.

## Files written

| Path | Lifetime | Contents |
|---|---|---|
| `$DATA/captures/<pane_uuid>.txt` | durable, overwritten on next hibernation | full pane scrollback at suspend time (ANSI preserved) |
| `$DATA/captures/<pane_uuid>.json` | durable | `{pane_uuid, window_uuid, session_id, pane_id, ts, cwd, pids}` |
| `$CACHE/hibernated/<pane_uuid>.json` | soft: until focus-in resumes the job. hard: until `session_start` fires in the pane (any claude — resumed via `clr <sid>` or a fresh `cl`) or until `pane_died`. Focus-in is a no-op for hard mode so the marker survives as crash-restore insurance. | `{mode, ts, pids, hard_ts?, hard_source?}` |
| `$CACHE/hibernated/_<sanitized_pane_id>.arm.pid` | while timer is running | the bash subshell pid holding the soft+hard sleeps |
| `$CACHE/busy/<pane_uuid>` | mtime-based freshness window | `{ts, claude_pid?}` JSON — body is for troubleshooting; the `is_busy()` check reads only the file's `mtime` |

## Env vars

| Var | Default | Purpose |
|---|---|---|
| `CLAUDE_RESCUE_SOFT_DELAY` | `3600` | Seconds of focus-out before soft hibernation fires. |
| `CLAUDE_RESCUE_HARD_DELAY` | `86400` | Seconds total (from focus-out) before hard hibernation. Must be ≥ `SOFT_DELAY`; remaining wait after soft = `HARD_DELAY - SOFT_DELAY`. |
| `CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES` | `3` | If busy marker is fresh at soft-fire time, sleep `DEFER_SECONDS` and re-check up to this many times. |
| `CLAUDE_RESCUE_HIBERNATE_DEFER_SECONDS` | `60` | Per-defer wait. |
| `CLAUDE_RESCUE_BUSY_FRESHNESS` | `1800` | Seconds; busy marker is "fresh" if its mtime is within this window. Protects against a crashed claude leaving a stale busy file. |
| `CLAUDE_RESCUE_TARGET_COMM` | `claude` | `comm` name to look for in pane process tree (record-keeping; the actual signaling goes via tty). |

## Manual test recipes

**Pre-flight**: `scripts/staging.sh setup`, then set fast delays:

```bash
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_SOFT_DELAY 8
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_HARD_DELAY 16
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES 0
```

Attach: `scripts/staging.sh attach`. In a pane in the staging dir, run `cl`,
send any prompt so a transcript file is created.

### A. Soft hibernation only

1. Note pane uuid: `tmux -L claude-rescue-staging show-options -pv -t %1 @claude-pane-id`.
2. From outside the staging socket OR via prefix-keybind: focus another pane.
3. Wait 10s.
4. **Verify:**
   - claude PID state = `T` (`ps -o stat= -p <claude_pid>`).
   - `$CACHE/hibernated/<uuid>.json` has `mode: "soft"`.
   - `$DATA/captures/<uuid>.{txt,json}` exist; sidecar `session_id` matches the visible status-bar UUID.

### B. Soft → resume

5. Focus back on the pane within `(HARD_DELAY - SOFT_DELAY)` window.
6. **Verify:** claude PID back to `S+`, marker gone, no `fg: no current job` error in pane.

### C. Soft → hard escalation

5'. Don't focus back. Wait an additional `HARD_DELAY - SOFT_DELAY` seconds.
6'. **Verify:**
   - claude (and uv/python children) gone from `ps`.
   - Pane content shows claude's "Resume this session with: claude --resume <sid>" message.
   - Pane shell prompt is **pre-filled** with `clr <sid>` (no Enter pressed).
   - Marker has `mode: "hard"`, `hard_ts` set.

### C2. Hard → focus-in (marker survives)

After C: focus the hard-hibernated pane *without* pressing Enter.

7'. **Verify:**
   - Marker still present at `$CACHE/hibernated/<uuid>.json` (focus-in is a no-op for hard mode).
   - No `unhibernated` event in the window log (claude isn't actually back yet).
   - Pane prompt still shows `clr <sid>`.

### C3. Hard → real resume cleans marker

After C2: press Enter on the `clr <sid>` prompt (or type `cl` to start a fresh session). Wait for the new claude to render.

8'. **Verify:**
   - `session_start` event for this pane_uuid in window log.
   - Marker is gone (cleaned up by `cmd_session_start`).
   - `unhibernated` event emitted with `mode: "hard"`.

### D. Busy-aware skip

5''. Submit a long-running prompt to claude, immediately focus away.
6''. Wait `SOFT_DELAY + DEFER_TIMES * DEFER_SECONDS`. While claude is mid-stream, the busy marker (`$CACHE/busy/<pane_uuid>`) is fresh (PreToolUse/PostToolUse hooks refresh its mtime).
7''. **Verify:** `skip:busy` event in the window log; claude was NOT stopped.

### E. Fast guard (non-claude pane)

8. Focus a pane that has never run claude (e.g., the nvim window pane).
9. Wait `SOFT_DELAY + 5s`.
10. **Verify:** no arm pid file, no hibernated marker, no capture file for that pane. Fast guard checks `@claude-pane-id` and returns early.

### F0. Focus-in during hard cleanup preserves `clr <sid>` pre-fill

A subtle race: between cmd_hibernate_arm writing the hard marker and sending
`clr <sid>` to the prompt, the user might focus the pane. cmd_hibernate_resume
sees a live arm subshell whose argv matches the orphan-safety pattern — but
killing it now would drop the in-flight `clr` send-keys.

The fix: cmd_hibernate_resume reads the marker mode first. For `mode=hard`,
the arm subshell is left alone (it's finishing critical cleanup). For
`mode=soft` (or no marker), the kill happens as before.

To reproduce: arm with SOFT=2 HARD=4, wait ~3s (after soft but before hard),
focus the pane during the brief window between hard marker write and clr
send. Verify the `clr <sid>` text still arrives on the prompt.

### F. arm-sweep fires on attach (covers backgrounded panes)

The fixture has 3 claude panes plus an nvim pane. After fixture exit the
active pane is the nvim one; none of the claude panes are focused.

11. From outside the staging socket, drive the sweep that `client-attached` would invoke:
    `tmux -L claude-rescue-staging run-shell -b 'claude-rescue-log arm-sweep'`
12. **Verify:** within 1s, three arm pid files appear in `$CACHE/hibernated/`
    (one per backgrounded claude pane). nvim's pane has none (fast guard).
13. Repeat the same command — **verify** the arm pids in the files are
    unchanged (idempotent; the second sweep does not reset live timers).

## Claude hook wiring

The busy marker is driven by claude's own hook system (configured via
`~/.claude/settings.json`, managed in `dot_claude/modify_settings.json.tmpl`):

| Claude hook | Action |
|---|---|
| `UserPromptSubmit` | `mark_busy(pane_uuid, claude_pid)` — write `{ts, claude_pid}` body (the claude PID is captured via `find_my_claude_pid`, the PPID walk that finds the ancestor claude that fired the hook) |
| `PreToolUse` / `PostToolUse` | refresh — rewrites the JSON body with current `ts`, bumping the file's mtime so the marker stays "fresh" during long agentic loops |
| `Stop` | `clear_busy(pane_uuid)` — `rm -f` the marker |
| `SessionEnd` | safety-net `clear_busy` (in case Stop didn't fire) |

`is_busy()` returns true only when the marker file exists AND its mtime is
within `CLAUDE_RESCUE_BUSY_FRESHNESS` (default 1800s = 30min). A claude that
crashes mid-prompt without firing Stop has its stale marker age out naturally.

## Event schema additions: `claude_pid`

`session_start` and `session_end` events written by the corresponding claude
hooks carry an optional `claude_pid` field. It's populated by
`find_my_claude_pid` (in `lib/common.sh`), which walks `$PPID` from the
script up to 8 hops looking for an ancestor whose `comm` is `claude` — that's
the claude that fired the hook. If no ancestor claude is found (e.g. the
handler is invoked from a non-hook context like `validate.sh`), the field is
omitted from the event JSON.

The same PID is also written into the busy marker body. Together they make
it possible to cross-reference "which claude wrote this event / busy marker"
without scanning the live process tree, useful for post-mortem inspection.

`hibernated` events carry a `pids` array (the claude pids the tree-walk found
at hibernation time). Those are not the same field as `claude_pid` — the
`hibernated`/`unhibernated` events come from `cmd_hibernate_arm` /
`cmd_hibernate_resume`, which run as backgrounded tmux subshells **without**
an ancestor claude, so the PPID walk would find nothing.

### Backfill kinds

`bin/claude-rescue-backfill` synthesizes historical events from resurrect
snapshots, emitted with `_backfill`-suffixed kinds: `session_start_backfill`,
`title_backfill`, `session_meta_backfill`. `rebuild_meta` (`lib/common.sh`)
recognizes both the observed (`session_start`, `title`) and backfill
variants via `startswith("session_start")` etc., so meta rollups treat them
uniformly. Backfill events do **not** carry `claude_pid` (no live claude
during backfill).
