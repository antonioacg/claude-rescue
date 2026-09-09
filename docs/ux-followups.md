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

The picker (`bin/claude-rescue`, bound to `prefix + R`) was rewritten: the
two-stage window→session drill-down over our event log is gone, replaced by a
flat, ripgrep-backed search over claude's own transcript corpus, ordered by
last-active, scoped to the current project with `tab` to widen. Most of the
items that used to live here were about the old surface. What that rewrite
settled:

- ~~**Human-readable local-time timestamps** *(#19)*~~ — done, rows carry a
  relative age column (`7m`, `16h`, `2d`), computed in the render pass.
- ~~**Clarify "scrollback" / "(no metadata)" labels** *(#20)*~~ — obsolete,
  those preview paths (`preview_window` / `preview_session`) are gone. The new
  preview shows the session id, cwd, the model it resumes with, and the last
  few prompts the human actually typed.
- ~~**Arrow key navigation** *(#22)*~~ — done, the active keys are rendered in
  `--footer` and the scope in `--header`.
- ~~**Fork-on-conflict when resuming an active session** *(#30)*~~ — done, and
  without needing a `ps` scan: a session held by a live pane is labelled with
  that pane (`session:window.pane`, from a `tmux list-panes` join against the
  active files) and cannot be selected at all. Offering a fork instead of a
  block is still open if it ever feels too strict.

Still open, re-pointed at what exists now:

- **Surface session provenance** *(#21)*. Rows show title, cwd and age but not
  how the session got here. Less useful than it was — the corpus is claude's
  own, so there is no backfill-vs-hook distinction to show — but a marker for
  sessions that only exist in the event log (no transcript) may be worth it.

- **Title formatter plugin point — verify end-to-end** *(#29)*. Now narrower
  than it was: the bash `format_title` is gone with the old picker, so
  `CLAUDE_RESCUE_TITLE_FORMATTER` is honoured only by
  `state_owner/watcher.py` for status labels. A validator scenario pointing the
  env var at a stub and asserting the label flows through would still catch a
  silent break.

- **Resume action: open in new pane** *(#36)*. The old ctrl-n (new window) and
  ctrl-w (new session) actions were dropped as unused; `enter` types the resume
  into the pane the picker was opened from. If a second target is ever wanted,
  a split-window action is the one to add.

- **Multi-cwd and last-window-index in preview** *(#32, #33)*. Both were about
  the window-level preview, which no longer exists. A session's own cwd is now
  a row column; "which window was this in last time" would have to come from
  the event log if it is still wanted.

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
  away (upstream rotation deleted it — the State Owner's retention pins
  the `last` target), restore bails. Should fall back to the
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
