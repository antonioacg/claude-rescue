# claude-rescue — operational docs

Procedures for adding features, shipping fixes, and validating in a staging
environment without touching the live tmux server.

| Doc | Purpose |
|---|---|
| [staging.md](./staging.md) | Spin up an isolated tmux server wired exactly like production. The harness for everything below. |
| [hibernation.md](./hibernation.md) | Soft (Ctrl+Z) and hard (Ctrl+C → exit) suspension. Env vars, expected behaviors, manual test recipes. |
| [crash-recovery.md](./crash-recovery.md) | What survives a tmux crash, what's reborn, and how the resurrect/continuum pipeline interacts with claude-rescue. |
| [deploying.md](./deploying.md) | chezmoi flow + cutover procedure for the live server. |

## Where things live

- `bin/` — user-facing CLIs (symlinked to `~/.local/bin/` by `scripts/install.sh`).
- `lib/` — shared shell helpers sourced by the bins.
- `tmux/` — production `rescue.tmux.conf` (sourced from `~/.tmux.conf`) + a minimal `tmux/test/test.conf` used by `scripts/validate.sh`.
- `scripts/` — developer tooling: installer, staging harness, isolated-test runner, end-to-end validator.
- `docs/operations/` — this directory.

## Standard dev loop

1. **Make the change** in `bin/` / `lib/` / `tmux/` (live system picks it up via symlinks — no install step).
2. **Validate scripted basics** — `bash scripts/validate.sh` (isolated server, ~30s, 11 unit-level scenarios).
3. **Validate hibernation + crash-restore** — `scripts/validate-hibernation.sh` (~90s, 22 assertions) and `scripts/validate-crash-restore.sh` (~3 min, 15 assertions). Both destroy current staging on entry/exit; both build the fixture from scratch via `staging-fixture.sh`.
4. **Validate interactively** in staging if needed — `scripts/staging.sh setup` + `scripts/staging-fixture.sh`. See [staging.md](./staging.md).
5. **Update or add docs** in this directory as the operational surface changes.
6. **Ship** — see [deploying.md](./deploying.md).
