# claude-rescue — design plan

> **Note (historical):** This is the original design document. The shipped
> system has since evolved — most notably, the resource-reduction layer is now
> a **two-stage focus-driven hibernation** (Ctrl+Z soft suspend → `/exit` hard
> exit) rather than the raw `kill -STOP` / `kill -CONT` approach described
> below. See `docs/operations/hibernation.md` for the current implementation,
> `docs/operations/crash-recovery.md` for the resurrect-restore behavior, and
> `docs/operations/` generally for the live operational surface. The core
> identity model (`@claude-window-id`, `@claude-pane-id`, per-window event
> log, picker drill-down) remains as designed here.

A tmux-coupled persistence layer for Claude Code sessions. Survives crashes, indexes session history per tmux window, and provides a Finder-columns drill-down picker via fzf.

## Problem

When `claude` runs inside a tmux pane, the session UUID is only visible in the live scrollback. After a crash (claude, terminal, OS) that scrollback may be gone, even though Claude Code itself has persisted the conversation to `~/.claude/projects/`. Without the UUID, those persisted conversations become hard to find — you have to grep through JSONL files by content.

`tmux-continuum` already snapshots pane contents every minute, but those snapshots are keyed by volatile tmux pane IDs and aren't indexed in any human-friendly way. We need a stable identity for "the work I do in this window" plus an interactive picker that walks you back to any prior session.

Heat / RAM pressure on the host (the original symptom) is a separate concern handled by an opt-in SIGSTOP layer described at the end.

## Core idea

Stamp every tmux window that ever runs `claude` with a stable UUID (`@claude-window-id`). All claude sessions started in that window become children of that window. Title changes within a session become children of the session. The result is a three-level tree:

```
window-uuid
├── session-uuid-1
│   ├── title @ ts
│   ├── title @ ts
│   └── ...
├── session-uuid-2
│   └── ...
```

A two-column fzf drill-down navigates this tree. Selecting a session at any level resumes it via `claude --resume <uuid>`.

## Data model

```
~/.claude-rescue/
  windows/
    <window-uuid>.jsonl       append-only event log
    <window-uuid>.meta.json   cached rollup (cwd, created_at, last_seen, active_sessions[])
  no-tmux/
    <host>__<cwd-hash>.jsonl  fallback bucket for claude run outside tmux
```

### Event log format (`<window-uuid>.jsonl`)

Append-only JSONL. One event per line.

```json
{"ts":"2026-04-26T11:30:01Z","kind":"session_start","session_id":"abc-123","cwd":"/Users/.../dev","pane_id":"%14"}
{"ts":"2026-04-26T11:30:14Z","kind":"title","session_id":"abc-123","title":"claude: investigating heat issue"}
{"ts":"2026-04-26T11:42:08Z","kind":"title","session_id":"abc-123","title":"claude: tmux session rescue design"}
{"ts":"2026-04-26T11:55:02Z","kind":"session_end","session_id":"abc-123","reason":"clear"}
{"ts":"2026-04-26T11:55:04Z","kind":"session_start","session_id":"def-456","cwd":"...","pane_id":"%14"}
```

Title events are attributed to the most recent open `session_start` for the same `pane_id` within the window.

### Meta rollup (`<window-uuid>.meta.json`)

Cached so fzf doesn't replay the log every keystroke. Rebuilt by the writer on each event.

```json
{
  "window_uuid": "...",
  "first_seen": "...",
  "last_seen": "...",
  "primary_cwd": "/Users/.../dev",
  "sessions": [
    {
      "session_id": "abc-123",
      "started": "...",
      "ended": "...",
      "cwd": "...",
      "pane_id": "%14",
      "last_title": "claude: tmux session rescue design",
      "title_count": 7
    }
  ]
}
```

## Event sources

| Event           | Source       | Mechanism                                                                                                   |
|-----------------|--------------|-------------------------------------------------------------------------------------------------------------|
| `session_start` | Claude Code  | `SessionStart` hook in `~/.claude/settings.json` runs the writer; gets `session_id` via stdin JSON          |
| `session_end`   | Claude Code  | `SessionEnd` (or `Stop`) hook                                                                               |
| `title`         | tmux         | `set-hook -g pane-title-changed 'run-shell "rescue-log title #{pane_id} #{pane_title}"'` (debounced)        |
| `pane_died`     | tmux         | `set-hook -g pane-died` — final flush of the live pane buffer before tmux reaps it                          |
| `client_detach` | tmux         | `set-hook -g client-detached` — also forces a continuum save                                                |

The writer is a single small script (`bin/rescue-log`) shared by all event sources. It:

1. Reads `@claude-window-id` from the current tmux window (`tmux show-options -wv -t "$pane" @claude-window-id`).
2. If unset and the event is `session_start`, generates a UUID and stamps it. (Other event kinds bail out if no window-uuid exists — they have no session to attach to.)
3. Appends the event line and rebuilds the meta rollup.

## fzf picker — Finder-columns drill-down

`claude-rescue` (the user-facing command). Refuses to run unless `$TMUX` is set.

Two columns visible at every level. As you drill in, both columns shift right by one tier of the tree.

### Level 1 — windows

```
column 1 (fzf list):                column 2 (--preview):
─ windows by recency ─              ─ sessions in selected window ─
* dev (3 sessions)  2m ago          [abc-123] claude: tmux rescue design     just now
  ops (12 sessions) 1h ago          [def-456] claude: docker cleanup         2h ago
  bufferbloat-wr741 (2)  1d ago     [ghi-789] claude: ont-monitor wifi       1d ago
  ...                               ...
```

- `enter` on a window → drill in to Level 2.
- `ctrl-r` on a window → resume its **most recent** session directly (skip Level 2).

### Level 2 — sessions of one window

```
column 1 (fzf list):                column 2 (--preview):
─ sessions in dev (newest first) ─  ─ title history of selected session ─
* [abc-123] claude: tmux rescue d.  11:42  claude: tmux session rescue design
  [def-456] claude: heat investiga  11:30  claude: investigating heat issue
                                    11:25  claude: starting up
```

- `enter` on a session → `cd` to its `cwd` and run `claude --resume <session_id>`.
- `esc` → back to Level 1.

### Implementation notes

- Single binary (`bin/claude-rescue`) that re-execs itself with a `--level` flag and the parent selection as argv. Each level is one fzf invocation; `enter` exits with a known code and the parent dispatches the next call.
- `--preview` runs a tiny formatter that reads the `meta.json` for the highlighted row and prints the next column.
- Spawned in a `tmux display-popup -E -h 80% -w 90%` so it overlays the current pane without disturbing the layout.

## Persistence durability

`@claude-window-id` is a custom user-option set on the tmux window. tmux-resurrect doesn't natively save `@`-prefixed options, so claude-rescue ships its own pair of resurrect hooks: `post-save-layout` writes a sidecar TSV mapping `(session_name, window_index) → @claude-window-id` next to each saved state, and `post-restore-all` re-applies those options from the latest sidecar.

This is the **only** identity-propagation mechanism. There is no name/cwd-based heal: heuristic matching caused incorrect merges (different windows that happen to share name+cwd) and isn't necessary once the sidecar path is reliable. A window that gets restored gets its UUID back; a window that's freshly opened gets a fresh UUID, even if a closed window had the same shape before. Picker history fragments per UUID — accepted tradeoff.

## Edge cases

- **Multiple concurrent claude panes in one window** — same `@claude-window-id`, multiple open `session_start` events. Title events disambiguate via `pane_id`. Meta rollup tracks `active_sessions` as a list.
- **Claude run outside tmux** — writer detects no `$TMUX`, writes to `no-tmux/<host>__<cwd-hash>.jsonl` instead. fzf has a "(no-tmux)" virtual top-level entry.
- **Title flicker during streaming** — debounce in the writer: ignore title events that change again within 5 s. The log only records "settled" titles.
- **Session ID collisions across machines** (e.g. you sync `~/.claude/projects/`) — out of scope for v1; we treat `session_id` as a local opaque key.
- **Log growth** — append-only; rotate per-window log when it exceeds 10 MB (rare; titles are tiny). Meta rollup is bounded by session count.

## Implementation order

1. **Writer + Claude hooks + tmux hooks** — `bin/rescue-log`, wire up `SessionStart`/`SessionEnd`/`Stop` in `~/.claude/settings.json`, add `pane-title-changed` / `pane-died` / `client-detached` hooks in `~/.tmux.conf`. Logs start populating immediately, no UI yet. Verify a day's worth of normal use produces sensible logs.
2. **Pre-flight verification** — confirm `SessionStart` hook input shape includes `session_id`; confirm whether resurrect persists `@`-prefixed user options. Adjust heal step if needed.
3. **Picker — Level 1 + Level 2** — `bin/claude-rescue` with the two-column drill-down. Bind to `prefix + R` in tmux.
4. **SIGSTOP layer (opt-in, separate)** — `pane-focus-out` hook arms a 5-min timer; if the pane stays unfocused, `kill -STOP` any `claude` PID descended from that pane's shell. `pane-focus-in` immediately `kill -CONT`s them. Tradeoff: the open HTTPS connection to Anthropic's API will time out during the pause; on `CONT`, claude may need to reconnect or be restarted. Acceptable for idle panes, harmful mid-stream — gated by a "no output for N seconds" heuristic.

## Repository layout

```
~/dev/claude-rescue/
  PLAN.md                this file
  bin/
    rescue-log           writer (called by hooks)
    claude-rescue        fzf picker (user-facing)
  tmux/
    rescue.tmux.conf     hooks to source from ~/.tmux.conf
  claude/
    hooks-snippet.json   SessionStart / SessionEnd / Stop entries to merge into ~/.claude/settings.json
  install.sh             symlinks bin/* into ~/.local/bin/, prints config snippets to add
```

## Test plan

All development and validation runs against an **isolated tmux server** (`tmux -L claude-rescue-test`), never against the live default server. Hooks and config live in a dedicated `tmux/test.conf` so the live `~/.tmux.conf` is untouched until promotion.

### Isolation primitives

```sh
SOCK=claude-rescue-test
RESCUE_HOME=$(mktemp -d -t claude-rescue.XXXXXX)
export CLAUDE_RESCUE_HOME="$RESCUE_HOME"   # writer respects this; defaults to ~/.claude-rescue

tmux -L "$SOCK" -f tmux/test.conf new-session -d -s t1
tmux -L "$SOCK" attach -t t1
# ... run scenarios ...
tmux -L "$SOCK" kill-server
rm -rf "$RESCUE_HOME"
```

Every test fixture creates a fresh `CLAUDE_RESCUE_HOME` dir and a fresh server. Nothing persists between tests. The writer and picker both honor `$CLAUDE_RESCUE_HOME` so the live data store at `~/.claude-rescue/` is never touched during tests.

### Scenarios to validate

| # | Scenario | Expected outcome |
|---|----------|------------------|
| 1 | First `claude` ever in a new window | `@claude-window-id` is set; window meta + `session_start` event written |
| 2 | Second `claude` after `/clear` in same window | Same `@claude-window-id`; new `session_id`; meta lists both sessions |
| 3 | Two concurrent claude panes in one window | One `@claude-window-id`, two open sessions, title events correctly attributed by `pane_id` |
| 4 | Claude updates window title rapidly during streaming | Debounce keeps log clean; only settled titles recorded |
| 5 | `kill -9` on a claude PID | `pane-died` hook fires; final pane snapshot archived; session marked ended (reason: `crash`) |
| 6 | `tmux -L $SOCK kill-server` then restart with continuum restore | Window reappears; `@claude-window-id` either survives (Q1=yes) or heal step adopts the prior UUID via `(name, cwd)` lookup |
| 7 | Rearrange windows mid-session (`swap-window`, `move-window`) | UUID and event log unaffected; no spurious events |
| 8 | Claude run outside tmux | Events land in `no-tmux/<host>__<cwd-hash>.jsonl`; picker shows the virtual entry |
| 9 | Picker drill-down: window → session → resume | `claude --resume <uuid>` runs in the correct `cwd`; no impact on other panes |
| 10 | Picker invoked outside `$TMUX` | Refuses with a clear message |

### Hook shape verification (Q1, Q2 from open questions)

Two micro-tests run before any other scenario:

- **Resurrect user-option persistence**: in the test server, set `@claude-window-id foo` on a window, run `tmux-resurrect`'s save script, kill the server, restart, run resurrect's restore, then `tmux -L $SOCK show-options -wv @claude-window-id`. If `foo` returns, Q1 is yes.
- **Claude SessionStart input**: temporarily wire `SessionStart` to a script that just dumps stdin to a file. Start a claude session in the test pane. Inspect the dumped JSON to confirm `session_id` and any other fields we care about.

These are cheap and answer the design's two load-bearing questions in minutes.

### Promotion gate

Only after scenarios 1–10 pass against the isolated server do we:
1. Add the hooks block to the live `~/.tmux.conf` (commented-out section first, with a `source-file` of the production config so it can be toggled).
2. Merge `claude/hooks-snippet.json` into `~/.claude/settings.json`.
3. Symlink `bin/*` into `~/.local/bin/`.

A single `install.sh --dry-run` prints the diff of what it would do, so the live system change is reviewable before commit.

## Resolved design decisions

### Q1 — `@claude-window-id` survival across resurrect restore: **NO natively, but we extend resurrect via its hook system**

**Resurrect's native behavior**: `dump_windows()` in `tmux-resurrect/scripts/save.sh` saves only `session_name`, `window_index`, `window_name`, `window_active`, `window_flags`, `window_layout`, and the single option `automatic-rename`. No `@`-prefixed user options are serialized. Verified against actual save files.

**Resurrect's hook system** (documented at `tmux-resurrect/docs/hooks.md` plus undocumented `post-restore-all` present in `restore.sh:382`):

| Hook                                       | When                              | Args            |
|--------------------------------------------|-----------------------------------|-----------------|
| `@resurrect-hook-post-save-layout`         | After all sessions/panes/windows saved | resurrect file path |
| `@resurrect-hook-post-save-all`            | End of save                       | none            |
| `@resurrect-hook-pre-restore-all`          | Before restore                    | none            |
| `@resurrect-hook-pre-restore-pane-processes` | Before pane processes restored  | none            |
| `@resurrect-hook-post-restore-all`         | After restore (undocumented but stable) | none      |

**Primary persistence mechanism**: register `post-save-layout` and `post-restore-all` hooks in `~/.tmux.conf` to save/restore `@claude-window-id` (and any other user options we care about) via a sidecar file alongside resurrect's state file.

**Save side** (`tmux/hooks/save-userops.sh`, called with the state file path):

```sh
state_file="$1"
sidecar="${state_file%.txt}.claude-userops.tsv"
tmux list-windows -aF $'#{session_name}\t#{window_index}\t#{window_name}\t#{@claude-window-id}' \
  | awk -F'\t' 'NF==4 && $4 != ""' > "$sidecar"
```

**Restore side** (`tmux/hooks/restore-userops.sh`):

```sh
state_file=$(readlink ~/.local/share/tmux/resurrect/default/last)
state_file="$HOME/.local/share/tmux/resurrect/default/$state_file"
sidecar="${state_file%.txt}.claude-userops.tsv"
[ -f "$sidecar" ] || exit 0
while IFS=$'\t' read -r session_name window_index window_name uuid; do
  tmux set-option -wt "$session_name:$window_index" @claude-window-id "$uuid" 2>/dev/null || true
done < "$sidecar"
```

Wired in `~/.tmux.conf`:

```tmux
set -g @resurrect-hook-post-save-layout '~/.config/tmux/hooks/save-userops.sh "$1"'
set -g @resurrect-hook-post-restore-all '~/.config/tmux/hooks/restore-userops.sh'
```

**Heal removed**: an earlier draft included a `(window_name, primary_cwd)` heuristic matcher that would re-adopt a prior UUID for "same-shape" windows. It was removed because (a) the sidecar already covers the kill+restore case deterministically, and (b) heal could incorrectly merge two genuinely-different windows that happened to share the same name and cwd. A new window with no live `@claude-window-id` always mints a fresh UUID; closed-and-reopened workflows show as separate picker entries.

### Q2 — Claude Code `SessionStart` hook input: confirmed

Stdin JSON, with these fields:

```json
{
  "session_id": "abc-123-...",
  "transcript_path": "/Users/.../.claude/projects/<encoded-cwd>/<uuid>.jsonl",
  "cwd": "/Users/...",
  "hook_event_name": "SessionStart",
  "source": "startup|resume|clear|compact",
  "model": "claude-sonnet-4-6"
}
```

**Key implications for our design:**

- `source` distinguishes a fresh session from a `--resume`/`--continue`/`/clear`/`/compact`. We use it to write the right event kind: `source=startup|resume` → `session_start`; `source=clear|compact` → emit a `session_end` for the prior session followed by `session_start` for the new one (same window, same `cwd`, new `session_id`).
- `transcript_path` is the on-disk JSONL Claude itself maintains. Storing it in our event log gives us a direct pointer into Claude's own session storage — useful for the picker's preview pane (we can show the first user message of a session as a richer label than just the UUID).
- `SessionEnd` fires on session termination with the same base fields. We use it directly for the `session_end` event.
- `Stop` fires per-turn (end of one Claude response). **Not used** for our `session_end` — would over-fire.
- `StopFailure` fires on API error end-of-turn. Useful as a `kind: "turn_failed"` event for forensic context, optional.

**Critical gotcha**: stdout from a `SessionStart` hook is **injected into Claude's conversation context**. The writer must emit nothing to stdout — all logging goes to stderr or to disk. Errors visible only via `claude --debug-file`. `hooks-snippet.json` will redirect: `"command": "/path/to/rescue-log session_start 2>/tmp/rescue-log.err"` (or similar).

### Q3 — Title debounce: 5 s + forced flush on session boundary

The writer holds the candidate title in memory (a small per-pane state file at `$CLAUDE_RESCUE_HOME/tmp/title-debounce-<pane_id>.json`). A `pane-title-changed` event:

1. Writes `{title, ts}` to the per-pane state file.
2. Schedules a delayed commit via `(sleep 5 && rescue-log title-commit <pane_id>) &` — only if no commit is already pending for that pane.
3. The commit reads the state file; if the title there is still the same as 5 s ago, it appends a `kind: "title"` event. If the title has churned in between, the commit no-ops and a fresh delayed commit is already pending from the latest change.

`SessionEnd` and `session_start` (for `source=clear|compact`) **force-flush** any pending title for the pane regardless of debounce, so the last task name before a `/clear` or graceful exit is always captured.

### Q4 — "Open in new tmux window" alongside "resume here": **yes**

Picker exit options (final level, with a session highlighted):

| Key   | Action                                                                                                              |
|-------|---------------------------------------------------------------------------------------------------------------------|
| `enter` | Resume in the current pane: `cd <cwd> && claude --resume <session_id>`                                            |
| `ctrl-n` | Resume in a **new tmux window** in the current session: `tmux new-window -c <cwd> "claude --resume <session_id>"` |
| `ctrl-w` | Resume in a **new tmux session**: `tmux new-session -d -c <cwd> -n claude "claude --resume <session_id>" \; switch-client -t '$last'` |
| `ctrl-y` | Copy the session UUID to clipboard (`pbcopy`) for manual use                                                      |

The popup footer shows the keybinds for the current selection level.

### Q5 — SIGSTOP layer: **v1, integrated**

Bundled into the initial release. Implementation:

- New tmux hooks:
  - `pane-focus-out` → arm a 5-minute timer per pane (background script, lockfile per pane).
  - `pane-focus-in` → cancel any pending timer for that pane; if a SIGSTOP was already issued, immediately `kill -CONT` all suspended PIDs on that pane and log a `kind: "resume_unstop"` event.
- The arm script, after 5 minutes:
  1. Confirms the pane is still unfocused (re-check `#{pane_in_mode}`, `#{window_active}`, `#{client_activity}`).
  2. Walks the pane's process tree from `#{pane_pid}` and finds processes with command name `claude` (or matching a configurable regex).
  3. Issues `kill -STOP <pid>` to each, records the PIDs in `$CLAUDE_RESCUE_HOME/stopped/<pane_id>.json`.
  4. Logs a `kind: "stopped"` event with the `session_id` if one is currently open for the pane.
- `pane-focus-in` reads the stopped-PIDs file and `kill -CONT`s them.

**Heuristic to avoid mid-stream pause** (tradeoff acknowledged): before issuing SIGSTOP, the arm script captures the current `#{pane_title}`. If the title contains the streaming-spinner indicator (claude uses `✳` prefix when actively working — visible in every pane in the resurrect dump), suspension is **deferred by another 60 s**. Repeats up to 3 times, then either suspends anyway or logs `kind: "stop_skipped"` and abandons. The threshold is configurable via env var.

**Connection-loss caveat documented**: when the user returns and `kill -CONT` resumes claude, an inflight HTTPS request to Anthropic's API may have timed out. Claude Code typically surfaces this as a network error and the user retries the prompt; the **session itself is unaffected** (Anthropic's transcript is server-side, the local JSONL is intact). For an idle session at the prompt, the `CONT` is invisible.

**Memory benefit**: while the process is in `T` (stopped) state, macOS's swap and compressor will aggressively page out its working set under memory pressure (which the host already has). No special action needed — that's exactly what the original "dump memory to disk" goal wanted.

## Updated implementation order

1. **Pre-flight: install.sh skeleton + `bin/rescue-log` writer** — single script that handles all event kinds: `session_start`, `session_end`, `title`, `title-commit`, `pane-died`, `client-detached`, `stopped`, `resume_unstop`. Writes to `$CLAUDE_RESCUE_HOME` (defaults to `~/.claude-rescue/`).
2. **tmux hooks file** (`tmux/rescue.tmux.conf`): `pane-title-changed`, `pane-died`, `client-detached`, `pane-focus-out`, `pane-focus-in`. Sourced from a guarded line in `~/.tmux.conf`.
3. **Claude hooks snippet** (`claude/hooks-snippet.json`): `SessionStart` (matchers for `startup`, `resume`, `clear|compact`), `SessionEnd`. Stdout redirected to /dev/null, stderr to a debug log.
4. **Picker** (`bin/claude-rescue`): two-column drill-down, popup launch, four exit keys.
5. **SIGSTOP arm/cancel scripts** invoked from the focus hooks.
6. **Backfill importer** (`bin/rescue-backfill`) — confirmed in scope.

## Backfill importer — design

A one-shot script (`bin/rescue-backfill`) that reconstructs as much history as possible from existing on-disk artifacts before the claude-rescue writer was installed.

### Sources

| Source                                                          | Provides                                                                                  |
|------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| `~/.local/share/tmux/resurrect/default/tmux_resurrect_*.txt`     | Per-snapshot: session/window structure, `pane_title`, `pane_command`, `pane_current_path`, timestamp embedded in filename |
| `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`          | Authoritative list of all sessions Claude itself knows about, with first user message, model, timestamps |

### Algorithm

1. **Enumerate snapshots in chronological order** by parsing the timestamp from `tmux_resurrect_YYYYMMDDTHHMMSS.txt` filenames.
2. **For each snapshot, parse `pane` lines**: extract `(session_name, window_index, pane_index, pane_title, pane_command, pane_current_path)`.
3. **Track per-pane title transitions across snapshots**: when a pane's title differs from the previous snapshot for the same `(session_name, window_index, pane_index)`, emit a synthetic `kind: "title"` event timestamped at the *current* snapshot's time. This gives us a coarse but real title timeline at the resurrect-save cadence (1 minute, in your config).
4. **Extract resumed session UUIDs** from `pane_command` lines containing `-r <uuid>` or `--resume <uuid>` — directly attributable to that pane at that snapshot. Emit `kind: "session_start"` at the snapshot timestamp with `source: "resume_backfill"`.
5. **Cross-reference with `~/.claude/projects/`**: for every backfilled `session_id`, verify a transcript JSONL exists. If yes, read its first user message for a richer label and confirm `cwd`. If no transcript exists, the UUID is dead — log it but don't include in the picker.
6. **Map historical panes to current `@claude-window-id`s**: for windows that still exist (matched by `(session_name, current pane_current_path)`), associate backfilled events with the live UUID. For windows that have since been closed, mint synthetic UUIDs prefixed `bf-<short-hash>` so they appear in the picker as a separate "(backfilled)" branch — distinguishable from live windows but resumable.
7. **Write all backfilled events** as a separate pass into `~/.claude-rescue/windows/<window-uuid>.jsonl` with `kind` values suffixed `_backfill` (`title_backfill`, `session_start_backfill`) so a later forensic pass can tell synthesized events apart from observed ones.

### Idempotence

Backfill writes a marker `~/.claude-rescue/.backfill-done` after success with the highest snapshot timestamp processed. Re-running the importer skips snapshots already covered. Safe to run repeatedly.

### Limitations to document

- Title resolution is bounded by the resurrect save interval (1 minute in current config). Faster transitions are lost.
- Fresh-session UUIDs not seen via `--resume` in any saved snapshot are unrecoverable through backfill — but if Claude's own JSONL transcript still exists, we can list it as an "orphaned" session in the picker (no associated window/title history, but still resumable).
- Pane index and window index can drift between snapshots if windows were rearranged. Tracking is by `(session_name, window_name, pane_index)` rather than `window_index` to mitigate.

## Open questions before coding

None — all design questions resolved above. Remaining unknowns are implementation-level (e.g. exact regex for the streaming-spinner indicator, exact process-tree walking logic) and will be answered while building against the isolated test server.
