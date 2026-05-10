# Follow-up work

Items captured during initial validation that aren't blocking but would be
worth revisiting once the core system has run live for a while.

## 1. Direct tmux pane-event hooks (sub-second title + immediate pane-died)

### Current behavior

`@resurrect-hook-post-save-layout` runs every continuum-save-interval (1 min
on this user's setup) and samples every pane's title + presence. Title
transitions and pane-disappearance get logged at minute granularity.

### Why we landed here

Tmux 3.6 silently rejects pane-scoped hooks at server-global scope:

| Attempted form                                | Result                                                                                          |
|-----------------------------------------------|-------------------------------------------------------------------------------------------------|
| `set-hook -g pane-title-changed …`            | Silently ignored. `show-hooks -g` shows nothing.                                                |
| `set-hook -gp pane-title-changed …` (global pane default) | Registers, fires on panes that exist *at the time of registration*, **does not propagate** to panes created later (split-window, new-window, respawn-pane). |
| `set-hook -p -t %N pane-title-changed …`      | Works, but is per-pane; not viable as a global wiring.                                          |

Same applies to `pane-died`, `pane-exited`, `pane-mode-changed`, `pane-focus-in`, `pane-focus-out`.

### What a direct-event design would look like

Propagate the pane hook to every newly-spawned pane via tmux's `after-*`
command hooks:

```tmux
# Initial coverage at session creation
set-hook -g session-created \
  'run-shell -b "claude-rescue-log register-pane-hooks #{session_id}"'

# Coverage as new panes appear
set-hook -g after-split-window \
  'run-shell -b "claude-rescue-log register-pane-hooks #{session_id}"'
set-hook -g after-new-window \
  'run-shell -b "claude-rescue-log register-pane-hooks #{session_id}"'
set-hook -g after-respawn-pane \
  'run-shell -b "claude-rescue-log register-pane-hooks #{session_id}"'
```

`register-pane-hooks` would walk the session's panes and run
`tmux set-hook -p -t %N pane-title-changed …` for each, idempotent.

### Tradeoff

| | Continuum-driven (current) | Direct-event |
|---|---|---|
| Title resolution | ~60s (continuum-save-interval) | sub-second |
| Pane-died detection | next save (~60s) | immediate |
| Hook count | 1 (`post-save-layout`) | ~4 + per-pane registrations |
| Edge cases | none — every pane is sampled unconditionally | any pane creation path that doesn't trigger an `after-*` hook leaves panes uncovered (e.g. mouse-driven splits in some terminals, plugin-spawned panes) |
| Code path | shared with backfill — same logic, single tested implementation | duplicated logic for live + backfill |

### Recommendation

Stay on continuum unless we measurably miss titles in the picker that we
wish we'd captured. The session UUID — the load-bearing recovery datum —
arrives via Claude's own SessionStart hook (not tmux), so it's already
real-time. Title is just for picker preview labels, where minute granularity
is enough to distinguish work-streams.

Revisit if:
- Users report missing titles for short-lived tasks.

---

## 2. SessionEnd should preserve Claude's reason if provided

`cmd_session_end` in `bin/claude-rescue-log` currently hardcodes
`reason: "exit"`. Claude's `SessionEnd` hook input JSON likely includes a
`reason` field on `/clear` and `/compact` flows; we should pass it through:

```sh
reason="$(jq -r '.reason // "exit"' <<<"$json")"
```

Visible in meta as `session_end{reason: "clear"|"compact"|"logout"|"exit"}`
which the picker could render distinctly (e.g. "/clear" badge vs "exit" badge).

Cosmetic. No behavioral impact — both still mark the session ended.

---

## 3. Dead code: `cmd_title`, `cmd_title_commit`, `cmd_pane_died`

These three subcommands are no longer wired to any tmux hook (we replaced
them with the resurrect-driven sampling). They still work if invoked
manually and are exercised by `scripts/validate.sh`, but production never
calls them.

Options:
- **Keep as-is** — useful for manual testing and back-compat if someone
  configures the older tmux hook style. Cost: ~80 lines of dead code,
  some test surface.
- **Remove** — cleaner code, but loses the "manual fire" debugging path.
  Some validate.sh scenarios would need rewiring.

No urgency. Defer until we have firmer confidence the resurrect-driven
path covers everything we want.

---

## 4. Hibernation layer (shipped)

The original SIGSTOP/SIGCONT design didn't survive contact with macOS — raw
`kill -CONT` doesn't restore `tcsetpgrp`, so claude+children would re-stop on
TTIN/TTOU as soon as they touched the controlling tty. Replaced with a
**two-stage focus-driven hibernation** that uses terminal-driven SIGTSTP via
`tmux send-keys C-z` (soft) and claude's `/exit` slash command (hard).

`pane-focus-out` and `pane-focus-in` DO register at `-g` on tmux 3.6+ — the
propagation worry noted in #1 turned out to apply only to a small set of
hooks (`pane-title-changed`, `pane-died`), not to focus events.

See `docs/operations/hibernation.md` for env vars, file paths, manual test
recipes; `docs/operations/crash-recovery.md` for what happens to hibernated
panes across a tmux crash + resurrect-restore.

---

## 5. Interactive picker UX testing

`scripts/validate.sh` exercises the picker's data plane (list-windows,
list-sessions, preview-window, preview-session) but not the actual fzf
popup interaction (drill-down, exit keys: enter / ctrl-n / ctrl-w / ctrl-y).

Status: untested in interactive mode. Will likely surface small ergonomic
issues (column widths, color contrast, header text) that need a real
human at the keyboard to identify.

`scripts/staging.sh` provides the environment to do this — bind `prefix + R`
already wired in staging.conf.

---

## 6. Backfill `--deep` flag

`bin/claude-rescue-backfill` runs in ~17s on 10K snapshots via the
single-pass awk pipeline. The current default scope is unbounded.

Future enhancement: a `--deep` flag (or `--max-snapshots N`) for users
with very large resurrect histories who want to cap work or do an
incremental import. The marker file (`.backfill-done`) already supports
incremental runs — `--max-snapshots` would be an additional knob.

Priority: low. The default already runs fast enough for most users.

---

## 7. `chezmoi apply` hardens the install

`run_once_after_15-install-claude-rescue.sh.tmpl` runs `install.sh
--apply` once. If the install script is updated upstream, the once-only
semantics mean users won't auto-pick up the changes — they'd need to
manually `chezmoi state delete-bucket --bucket=scriptState` or unlink
the binaries and re-run.

This was a deliberate choice (avoid surprise re-runs on update). But
it's worth documenting and considering: should we switch to
`run_onchange_` keyed on the install script's checksum? Tradeoff is
auto-application of upstream changes (good for trust-the-author
projects, risky for ones in flux).

---

## 8. `@continuum-save-interval 0` doesn't disable autosave

Setting `@continuum-save-interval 0` on a live tmux server does **not**
suppress the continuum save daemon — it keeps ticking at its default
cadence. To actually pause autosaves during diagnostics or staged
restore tests, set the interval to a large number (e.g. `99999`) so
the daemon's wait-loop never hits zero.

Observed during test #14 / #17 development: while debugging the
sidecar-vs-state race, setting interval to 0 left autosaves firing
every minute, clobbering `last` with empty saves. Switching to 99999
fixed it.

Source confirmation lives in
`~/.config/tmux/plugins/tmux-continuum/scripts/continuum_save.sh` —
0 is treated as "use default", not "disabled".

Action: either patch tmux-continuum upstream to honour 0, document the
quirk in `config.sh.example`, or wrap a "freeze autosaves" helper into
`scripts/staging.sh` for diagnostic flows.
