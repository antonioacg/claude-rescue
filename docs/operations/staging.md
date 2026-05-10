# Staging server

`scripts/staging.sh` brings up a real tmux server (separate socket, separate
data dir) wired exactly like a chezmoi-applied production system. Use it to
validate behavior end-to-end before committing changes that affect live state.

## What it touches

- Symlinks `bin/claude-rescue*` into `~/.local/bin/` via `scripts/install.sh`
  (idempotent; teardown can remove them).
- Creates `~/claude-rescue-staging/` (override with `CLAUDE_RESCUE_STAGING_DIR`)
  containing:
  - `.claude/settings.json` — project-level claude hooks (your global `~/.claude/settings.json` is **not** touched).
  - `.config/tmux/staging.conf` — sources your real `~/.tmux.conf`, then overrides resurrect/continuum for isolation.
  - `data/` — `CLAUDE_RESCUE_DATA_HOME` for events, captures, and meta.
  - `data/cache/` — `CLAUDE_RESCUE_CACHE_HOME` for busy markers, hibernated markers, error logs.
- Starts a tmux server on socket `claude-rescue-staging` (independent of your default).

## Usage

```bash
scripts/staging.sh setup            # install + start staging server (production-default delays)
scripts/staging.sh setup --fast     # same, plus SOFT=15s HARD=60s DEFER_TIMES=0 (interactive testing)
scripts/staging.sh attach           # tmux -L claude-rescue-staging attach
scripts/staging.sh status           # what's running, where logs are, env overrides on the server
scripts/staging.sh teardown         # kill server, optionally remove dir + symlinks

scripts/staging-fixture.sh          # populate a fresh server with the validation fixture
```

`--fast` is an opt-in shortcut for interactive hibernation testing. Without
it, the staging server mirrors production timing (60min soft, 24h hard) —
useful when you want to mimic live behavior, frustrating when you want to
see hibernation fire while you're sitting at the terminal. The flag mutates
the staging server's global env via `tmux set-environment -g`, which every
`tmux run-shell -b` subprocess (including the focus-driven hibernate-arm
hook) inherits. Validators set their own delays explicitly inside the
script, so they're independent of how setup was invoked. Tracked in #46 for
a proper config-file replacement.

`--fast` deliberately does NOT touch `CLAUDE_RESCUE_BUSY_FRESHNESS` (default
1800s = 30 min): for a 15s/60s test cycle, the busy marker can't possibly
age out before the test completes, so the production default is fine. If
you're testing the freshness-age-out path itself, set it manually:
`tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_BUSY_FRESHNESS 60`.

`setup` is idempotent — re-run to refresh `settings.json` and `staging.conf`
after making changes to those templates in the script.

`staging-fixture.sh` builds a known multi-window layout on top of a fresh
`setup`. Layout:

| Pane | cwd | foreground |
|---|---|---|
| `main:1.1` | `~/claude-rescue-staging` | claude (with transcript) |
| `main:1.2` | `~/claude-rescue-staging/projectA` | claude (with transcript) — split-window -v below 1.1 |
| `main:2.1` | `~/claude-rescue-staging/projectB` | claude (with transcript) |
| `main:3.1` | `/tmp` | nvim on `/tmp/claude-rescue-staging-scratch.md` |

Each claude pane is fed `hi` so a transcript file lands in
`~/.claude/projects/<encoded-cwd>/` — without this, `find-sessions` would
filter the session out and the resurrect wrapper would resume the wrong
session (or none). The fixture refuses to run against a non-empty server;
tear down and re-setup first. To pick up the refreshed
config in a still-running server:

```bash
tmux -L claude-rescue-staging source-file \
  ~/claude-rescue-staging/.config/tmux/staging.conf
```

## Speed-up env vars (testing)

Set on the staging server before driving tests:

```bash
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_SOFT_DELAY 8
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_HARD_DELAY 16
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_HIBERNATE_DEFER_TIMES 0
tmux -L claude-rescue-staging set-environment -g CLAUDE_RESCUE_BUSY_FRESHNESS 60
```

Unset (`set-environment -gu <NAME>`) when done; the server uses sensible
production defaults (60min soft, 24h hard) when these are absent.

## Driving tests from outside the server

Most validation can be scripted via the staging socket without attaching:

```bash
# Inspect current panes and their pane-uuids
tmux -L claude-rescue-staging list-panes -aF \
  '#{pane_id} cmd=#{pane_current_command} pane_uuid=#{@claude-pane-id}'

# Switch the attached client's window/pane (fires pane-focus-out/-in hooks)
tmux -L claude-rescue-staging switch-client -c <client_tty> -t main:3
tmux -L claude-rescue-staging select-pane -t %1

# Send keystrokes to a pane (claude or shell input)
tmux -L claude-rescue-staging send-keys -t %1 "cl" Enter

# Capture the visible scrollback for assertions
tmux -L claude-rescue-staging capture-pane -p -t %1 | tail -20

# Force a resurrect snapshot (otherwise auto-saves every minute)
tmux -L claude-rescue-staging run-shell \
  '~/.config/tmux/plugins/tmux-resurrect/scripts/save.sh'

# Force a resurrect-restore (for crash-test simulation)
tmux -L claude-rescue-staging run-shell \
  '~/.config/tmux/plugins/tmux-resurrect/scripts/restore.sh'
```

## ⚠ Never run `tmux attach` directly against the staging socket

Always use `scripts/staging.sh attach`. The wrapper checks the server is up
and bails out if it isn't.

**Why this matters**: if the staging server has died (e.g. you `kill -9`'d
it during testing) and you run `tmux -L claude-rescue-staging attach`,
tmux auto-starts a new server using your **main `~/.tmux.conf`**, not
`staging.conf`. That has two consequences:

1. `@continuum-restore` is "on" (your main default) — continuum's boot
   wrapper auto-restores from the staging resurrect snapshot, bringing
   panes back without you asking.
2. The new server has none of the `CLAUDE_RESCUE_*` env vars set, because
   you didn't go through `staging.sh setup`. Restored claudes inherit
   empty env. Their `SessionStart` hooks fire, `claude-rescue-log` falls
   back to the XDG default `~/.local/share/claude-rescue/`, and **staging
   events silently land in your production data dir** — visible only to a
   forensic grep.

The safe pattern always:

```bash
scripts/staging.sh teardown   # if server is alive but you want to reset
scripts/staging.sh setup --fast
scripts/staging.sh attach
```

Tracked in #47 (validator scenario) and ultimately fixed by #46 (config
file with hot-reload — eliminates the env-propagation footgun entirely).

## Important: focus-driven hooks need a real client

`tmux select-pane` from outside any client does **not** fire the
`pane-focus-out` / `pane-focus-in` hooks — they're driven by client focus
changes. Either:

- Attach a client with `scripts/staging.sh attach` and switch panes interactively, or
- Invoke the hibernation/resume code paths directly via `tmux run-shell`:

```bash
tmux -L claude-rescue-staging run-shell -t %1 \
  'claude-rescue-log hibernate-arm #{pane_id} #{pane_pid}'
tmux -L claude-rescue-staging run-shell -t %1 \
  'claude-rescue-log hibernate-resume #{pane_id}'
```

## Watching events fire

```bash
tail -F ~/claude-rescue-staging/data/cache/rescue-log.err   # script-level errors
tail -F ~/claude-rescue-staging/data/cache/hibernate.err    # hibernate timer errors
tail -F ~/claude-rescue-staging/data/cache/restore-keys.err # post-restore keys errors

# Live event stream for a window:
ls ~/claude-rescue-staging/data/windows/                    # find window UUIDs
tail -F ~/claude-rescue-staging/data/windows/<uuid>.jsonl | jq -c
```

## Scripted validation

Three validator scripts cover the operational surface. All run autonomously
(no attached client required), tear staging down + bring it up fresh on entry,
clean up on exit, exit non-zero on any failure.

| Script | Scope | Server |
|---|---|---|
| `scripts/validate.sh` | 11 unit-level scenarios from the original PLAN: window UUID minting, `/clear` handling, multi-pane sharing, title debounce, pane-died flush, resurrect cycle, window swap, no-tmux fallback, picker data plane, install dry-run, JSONL validity | isolated `claude-rescue-validate` socket, temp data dir — doesn't touch staging |
| `scripts/validate-hibernation.sh` | 22 assertions across soft hibernation, soft resume, hard escalation (with `clr <sid>` pre-fill), and the fast guard on non-claude panes | uses staging: teardown + `staging.sh setup` + `staging-fixture.sh` + drives via `tmux run-shell` |
| `scripts/validate-crash-restore.sh` | 15 assertions across the two crash-restore paths: (1) soft-saved-as-claude → wrapper auto-resumes session, marker auto-promoted with `hard_source: "crash-promote"`; (2) hard-saved-as-zsh → post-restore-keys subshell prints capture + pre-fills `clr <sid>` | uses staging: rebuilds between the two scenarios via `bring_up_fresh` |

```bash
bash scripts/validate.sh                 # ~30s, isolated, safe to run anytime
bash scripts/validate-hibernation.sh     # ~90s, destroys current staging
bash scripts/validate-crash-restore.sh   # ~3 min, destroys current staging twice
```

The `validate-hibernation.sh` and `validate-crash-restore.sh` runs leave
staging torn down on exit. Re-populate with
`scripts/staging.sh setup && scripts/staging-fixture.sh` if you want to
continue interactive work afterward.
