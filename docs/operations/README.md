# claude-rescue — operational docs

Procedures for adding features, shipping fixes, and validating in a staging
environment without touching the live tmux server.

| Doc | Purpose |
|---|---|
| [staging.md](./staging.md) | Spin up an isolated tmux server wired exactly like production. The harness for everything below. |
| [hibernation.md](./hibernation.md) | Soft (Ctrl+Z) and hard (Ctrl+C → exit) suspension. Env vars, expected behaviors, manual test recipes. |
| [crash-recovery.md](./crash-recovery.md) | What survives a tmux crash, what's reborn, and how the resurrect/continuum pipeline interacts with claude-rescue. |
| [deploying.md](./deploying.md) | chezmoi flow + cutover procedure for the live server (concepts). |
| [production-rollout.md](./production-rollout.md) | Step-by-step runbook for cutting a live machine over to a new release — state dump, apply, server restart, verify, rollback. |
| [rollout-2026-05-11-postmortem.md](./rollout-2026-05-11-postmortem.md) | Postmortem of the first production rollout. Bugs caught, root causes unresolved at that time, recovery paths validated. |
| [rollout-2026-05-12-postmortem.md](./rollout-2026-05-12-postmortem.md) | Second rollout on the same machine. Snapshot race (continuum-save during restore), wrapper P3-fallback bug, active/ bulk-clear bug; five patches that make the restore path durable. **Read this before doing the rollout on another machine** — the 2026-05-11 hypotheses became reproducible here. |
| [rca-2026-06-05-restore-keystroke-race.md](./rca-2026-06-05-restore-keystroke-race.md) | Real macOS crash → continuum auto-restore fired **twice**, double-running the non-idempotent post-restore UX path. The two passes concatenated `clr <sid>` + `claude-rescue print` and executed the garble; every hard-hibernated session failed to resume and landed in `~`. Recovery procedure + proposed fixes (single restore trigger, idempotency guard, cwd-correct pre-fill). |

## Where things live

- `bin/` — user-facing CLIs (symlinked to `~/.local/bin/` by `scripts/install.sh`).
- `lib/` — shared shell helpers sourced by the bins.
- `tmux/` — production `rescue.tmux.conf` (sourced from `~/.tmux.conf`) + a minimal `tmux/test/test.conf` used by `scripts/validate.sh`.
- `scripts/` — developer tooling: installer, staging harness, isolated-test runner, end-to-end validator.
- `docs/operations/` — this directory.

## Standard dev loop

1. **Make the change** in `bin/` / `lib/` / `tmux/` (live system picks it up via symlinks — no install step).
2. **Validate scripted basics** — `bash scripts/validate.sh` (isolated server, ~30s, 36 assertions across 14 unit-level scenarios — adds snapshot-race lock + wrapper-find-sessions-over-stale-`-r`).
3. **Validate hibernation + crash-restore** — `scripts/validate-hibernation.sh` (~3 min, 57 assertions across 9 scenarios — adds SessionEnd arm.pid reap + arm-sweep voluntary-exit detection) and `scripts/validate-crash-restore.sh` (~4 min, 31 assertions across 4 crash-recovery paths — adds wrapper-prefers-active-file). Both destroy current staging on entry/exit; both build the fixture from scratch via `staging-fixture.sh`.
4. **Validate interactively** in staging if needed — `scripts/staging.sh setup` + `scripts/staging-fixture.sh`. See [staging.md](./staging.md).
5. **Update or add docs** in this directory as the operational surface changes.
6. **Ship** — see [deploying.md](./deploying.md).
