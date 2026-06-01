# Server-cycle validation

Re-runnable checklist for validating that the watcher, save-guarded, and
claude-rescue-resume wiring survive a `kill-server` + resurrect-restore
cycle end-to-end. Run after any change to:

- `bin/claude-rescue-watcher` (capture logic, state keying, floor)
- `scripts/save-guarded.sh` (bundle layout, server-name derivation)
- `tmux/rescue.tmux.conf` (hook wiring, config-source triggers)
- `bin/claude-rescue-resume` (process wrapper for restored claude panes)
- tmux-resurrect / tmux-continuum plugin upgrades

Run on a **second tmux server** (`tmux -L test`) so the live default server
is untouched. Tick boxes as you go.

## Phase 1 — Setup test panes on the test server

- [ ] Set `@resurrect-strategy-nvim 'session'` (so nvim buffers survive)
- [ ] Create a target file for nvim (e.g. `/tmp/restore-test.md` with a
      few lines and a designated edit point)
- [ ] Add nvim window editing the target file, cursor at known line
- [ ] Edit the file inside nvim (mark a modified state so restore-check
      can verify the session preserved it)
- [ ] Add a window with real `claude` running (active session — gets
      `@claude-pane-id` via SessionStart hook)
- [ ] Add a window where we simulate post-hibernation state: kill claude,
      send-keys `clr <sid>` (no Enter). Bypasses the 60min+24h hibernation
      timer while exercising the same restore mechanism.

## Phase 2 — Verify pre-cycle state

- [ ] All 4 windows' panes captured in `$DATA/scrollback/test/pane-*`
- [ ] `@claude-pane-id` set on the active-claude pane (via SessionStart)
- [ ] `@claude-window-id` set on its window (via cmd_session_start)
- [ ] `clr <sid>` text visible in the simulated-hibernated pane's
      captured scrollback file

## Phase 3 — Save round-trip

- [ ] Trigger save via `tmux -L test run-shell "bash …/save-guarded.sh quiet"`
- [ ] `~/.local/share/tmux/resurrect/test/pane_contents.tar.gz` exists
- [ ] `tar tzf` shows entries for all 4 panes (pane-0:1.1, pane-0:2.1, …)
- [ ] Sidecar `*.claude-userops.tsv` written with the active-claude's
      window-uuid + pane-uuid (these are what `claude-rescue-resume` needs
      to look up the session on restore)

## Phase 4 — Cycle the test server

- [ ] User detaches the test session (prefix + d)
- [ ] `tmux -L test kill-server` (keep `resurrect/test/` intact — that's
      what continuum will restore from)
- [ ] User runs `tmux -L test new-session` in fresh non-tmux terminal
- [ ] Continuum auto-restore fires (saw `@continuum-boot-started` get set)

## Phase 5 — Verify restore

- [ ] Watcher spawned automatically on the new server (tracer entry +
      `watcher-test.pid` present)
- [ ] `.server-pid` reflects the NEW tmux PID (not the old one)
- [ ] `.state` got nuked + rebuilt cleanly (no spurious pane-died/created
      spam in window logs from stale old-server pane_ids)
- [ ] All 4 windows recreated with the right structure
- [ ] **Shell pane**: scrollback re-painted from `cat` prefix
- [ ] **nvim pane**: nvim re-opened with the file, modified state
      preserved (`:set modified?` shows `modified` or the line edit is
      visible)
- [ ] **Active claude pane**: claude resumed the SAME session
      (transcript continues, same session_id, prompt + history intact)
- [ ] **Hibernated claude pane**: `clr <sid>` text visible in re-painted
      scrollback; typing Enter resumes the session
- [ ] `watcher-audit.log` has no new `floor-caught` entries from the
      restored panes (would indicate event coverage holes)

## Open questions / known unknowns

- `@resurrect-strategy-nvim` not in `dot_tmux.conf`; needs to be set
  manually on the test server for each run. If repeated validations
  confirm nvim restore works, promote it to chezmoi.
- `@resurrect-processes` pattern is `claude->claude-rescue-resume *`. The
  `*` keeps original argv. For a fresh claude (no args) this becomes
  `claude-rescue-resume` only — which uses `@claude-pane-id` to find the
  session. We trust that path; each run verifies it again.
- Simulated hibernated state vs. real hibernation diverge in one way: real
  hibernation has the SOFT (Ctrl+Z) phase first, leaving claude in a `T`
  state before the hard exit. The simulation skips that. Pane-content-wise
  the end state (`clr <sid>` in the pane) is identical, which is what the
  restore path consumes.

## Run log

Track which runs passed/failed below. One entry per validation pass.

<!-- Format: YYYY-MM-DD reviewer — outcome (pass/fail with notes) -->
