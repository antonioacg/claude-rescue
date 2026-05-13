# UX follow-ups

Improvements to the operator-facing surface (picker, backfill workflow,
hibernation behavior, runbook ergonomics) that have come up during real
use but been deferred because the core path was the priority. Listed in
roughly the order they'd matter to a daily user.

Not a planning document — pick one when there's time, ship it on its own,
strike it from the list. Cross-linked to numbered tasks in the TODO
system where applicable.

---

## Picker

The two-stage drill-down (`bin/claude-rescue`, bound to `prefix + R`) is
the most-used surface. Most of the deferred items below cluster here.

- **Human-readable local-time timestamps** *(#19)*. The picker preview
  prints raw ISO timestamps (`2026-05-12T01:15:20Z`). For "when did this
  happen" reasoning the operator's brain has to add timezone offset and
  parse a 20-char string. A relative-time column (`2h ago`, `yesterday
  14:30`) on the row list plus local-time annotation in previews would
  make the picker feel an order of magnitude faster to scan.
  Implementation hint: `format_session_rows` already calls `humanize_age`
  for the age column; same path could feed local-time conversion.

- **Clarify "scrollback" / "(no metadata)" labels** *(#20)*. Some preview
  paths fall back to placeholder labels that aren't meaningful to a user
  trying to decide which session to resume. Audit the empty-state strings
  in `preview_window` and `preview_session` and replace with text that
  describes *why* nothing is showing (e.g., "no title events captured —
  pane never had @claude-pane-id minted" beats "(no metadata)").

- **Surface session/window/pane provenance** *(#21)*. Right now the
  picker shows session_id and cwd but not how the entry got into the
  event log (live SessionStart hook vs `session_start_backfill` from a
  saved `-r` argv vs `session_meta_backfill` from a transcript). The
  `source` field is captured in the events but not displayed. A small
  annotation column would help debug picker entries that don't behave as
  expected.

- **Arrow key navigation** *(#22)*. fzf already supports arrow keys, but
  the picker's two-stage flow has its own keybinds for level transitions
  (tab/shift-tab to cycle filter mode, ↩ to drill in, esc to back out).
  Worth verifying that the configured keys are intuitive — particularly
  ctrl-w (resume in new tmux session) is non-obvious. A `--header`
  with the active keybinds rendered would help.

- **Title formatter plugin point — verify end-to-end** *(#29)*.
  `CLAUDE_RESCUE_TITLE_FORMATTER` is documented in `format_title()` and
  exercised on every preview render, but no validator scenario covers it.
  Risk: an upstream change to title encoding silently breaks the
  formatter integration. A `scripts/validate.sh` scenario that points
  the env var at a stub script and asserts the output flows through
  would catch regressions.

- **Fork-on-conflict when resuming an active session** *(#30)*. If you
  pick a session_id that's already running in another live claude pane,
  the picker happily fires `clr <sid>` and you end up with two claudes
  writing the same transcript on disk — undefined behavior. The picker
  should detect this (`ps -A | grep -- "-r <sid>"`) and offer to fork
  (`claude --resume-fork-session` semantics) or open a new pane.

- **Window preview shows multiple cwds when applicable** *(#32)*. A
  single tmux window can have panes in different cwds. The picker's
  window preview shows one `primary_cwd`. For multi-cwd windows, list
  all cwds (or at least surface that there are N).

- **Last-known window_index in preview** *(#33)*. Operator selecting an
  old session wants to know "which window number was this in last
  time?" — useful for muscle memory after a restore. Currently
  preview omits the index.

- **Resume action: open in new pane** *(#36)*. Current resume actions
  are: ↩ in-place, ctrl-n new window, ctrl-w new session. Missing: new
  pane (split-window). Add as another action key. The implementation is
  3 lines in `action_resume_*` patterns.

- **cwd+branch filter mode** *(#39)*. The filter scope cycle currently
  exposes `all / window / pane / cwd`. Adding `cwd+git-branch` (filter
  to sessions whose cwd is the current repo AND on the current branch)
  would help operators flipping between feature branches recover the
  right session. Requires `git -C <cwd> branch --show-current` at
  filter-cycle time.

- **Surface git info in preview** *(#40)*. If the session's cwd is a
  git repo, show the branch + dirty status in the preview. Same `git
  -C` call as above. The picker becomes a session-and-branch picker
  for free.

- **Resilient restore against dangling `last` symlink** *(#41)*.
  `cmd_resurrect_restore` reads `$resurrect_dir/last` to find the
  snapshot to replay. If `last` points at a file that's been rotated
  away (cleanup-resurrect-snapshots.sh or upstream rotation deleted
  it), restore bails. Should fall back to the
  newest-by-filename `.txt` in the dir.

---

## Backfill workflow

The pane-uuid backfill heuristic is the source of three real-world
problems we've now seen across two production rollouts.

- **Reconciler for post-cutover panes**. `backfill-pane-uuids.sh` is a
  one-shot per cutover. Any claude pane created *after* cutover doesn't
  get an `@claude-pane-id` minted automatically — it sits invisibly
  outside the rescue system until the operator notices. Caught on
  2026-05-13 with pane `%11`, created post-cutover on 2026-05-12, no
  pane_uuid until manual re-backfill. Fix shape: a periodic
  reconciler triggered by `client-attached` (or its own arm-sweep-style
  background loop) that scans for `claude` panes lacking
  `@claude-pane-id` and mints. `capture-truthful-sids.sh` already
  provides the truthful sid; pair it with `tmux_set_pane_uuid` and
  `write_active_session` and you have idempotent reconciliation.

- **Replace mtime heuristic with bottom-status scrape**.
  `backfill-pane-uuids.sh` picks Nth-most-recent transcript per cwd.
  In the 2026-05-12 rollout, this disagreed with the truthful sid in
  13 of 21 panes (multi-pane cwds, /resume forks, manually-moved
  jsonls). `capture-truthful-sids.sh` (introduced in commit
  `385c7b4`) scrapes claude's bottom-status line for the visible
  session_id — that's authoritative. Fold it back into
  `backfill-pane-uuids.sh` as the primary path, with the mtime
  heuristic as fallback for panes whose visible sid can't be read
  (hibernated, capture-paused, etc.).

- **Self-collision false positive in pre-run sanity check**.
  Runbook §4c tells the operator to run `ps -A | grep -- "-r <sid>"`
  before backfilling. Today the check returns a hit for the pane being
  backfilled itself (its argv has the sid the heuristic chose), making
  it indistinguishable from a real collision (two different panes
  claiming the same sid). The check should exclude the pane being
  minted, or compare pid+sid pairs rather than just sids.

---

## Hibernation

- **Hard stage: stop sending `/exit`** *(#48)*. Current hard-hibernation
  sends `/exit` to claude, which writes a message into the conversation
  transcript. That pollutes the session history with rollout-internal
  state. Migrate to `Ctrl+C × 2` (claude's signal-based clean exit)
  which doesn't write to transcripts. The validator scenarios for hard
  hibernation already exist; they'd need their assertion shape updated.

- **Tunables to a config file with hot-reload** *(#46)*. Knobs like
  `CLAUDE_RESCUE_SOFT_DELAY`, `CLAUDE_RESCUE_HARD_DELAY`,
  `CLAUDE_RESCUE_RESTORE_DELAY`, `CLAUDE_RESCUE_TITLE_FORMATTER` are
  env-var-driven, which means changing them requires editing the
  hooks-running shell's env or restarting tmux. A `~/.config/claude-rescue/config.toml`
  (or `.env`) read by `lib/common.sh` on each invocation would let
  operators tune without ceremony. Hot-reload comes free with
  "re-read on each invocation."

---

## Runbook & operator ergonomics

- **`send-keys` long-string + `Enter` interpreted as multi-line**.
  Caught on the 2026-05-12 rollout. Calls like `tmux send-keys -t %N
  "long prompt text" Enter` get treated by claude as a single
  multi-line message instead of "type then submit". Workaround: split
  into two `send-keys` calls with `sleep 1` between them. The runbook
  has several `send-keys ... Enter` patterns (§5 recovery recipes,
  §5b restore-zsh-to-claude.sh) that should adopt the two-call form
  by default — or be wrapped in a helper that does the right thing.

- **Post-cutover doctor command**. Today the operator has no scripted
  way to ask "is my system healthy?" after a rollout. They have to
  hand-check arm.pid counts, active/ files, busy markers, and the
  event log shape (per runbook §6). A `claude-rescue doctor` subcommand
  that runs all those checks and reports green/yellow/red would
  shorten the post-rollout watch window and make day-2 incidents
  faster to triage.

- **Picker keybind discoverability**. `prefix + R` opens the picker,
  but there's no in-tmux indication of this. A line in `status-right`
  (or a hint in the prefix-highlight plugin's display) would help
  fresh-Mac operators find it.

---

## What's NOT on this list

- Anything in [FOLLOWUPS.md](../FOLLOWUPS.md) — that file covers
  architectural / system-level follow-ups (direct tmux pane-event
  hooks, hibernation layer, dead code, etc.). This list is purely
  the operator-facing surface.
- Anything in the PRDs (`docs/prd-*.md`) — those track the daemon /
  resurrect-absorption / architectural-split vision. Items above might
  inform those PRDs but aren't planning documents themselves.
- Anything blocked by external code (upstream tmux pane-hook bugs,
  Claude Code's `/exit` behavior, etc.) — captured in FOLLOWUPS.md
  where applicable.
