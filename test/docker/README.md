# Dockerized dual-trigger restore test

Proves the post-restore pre-fill is **idempotent under the real production
dual restore-trigger** — the exact race that caused the 2026-06-05 incident
(`docs/operations/rca-2026-06-05-restore-keystroke-race.md`).

## Why a container

The incident's root cause is two restores firing on one boot: tmux-continuum's
own auto-restore **and** the boot-guard `restore-wrapper.sh`. Continuum's
auto-restore *self-suppresses when another tmux server is running*
(`another_tmux_server_running_on_startup`), so on the host — where the live
default server is always up — it never fires, and the dual-trigger can't be
reproduced. A container is the **only** way to run the test server as the *only*
tmux server, so the genuine dual-trigger happens with zero simulation.

It also enables proper crash testing (`kill -9` the in-container server / kill
the container) with full isolation from the live stack.

## Fidelity

Everything matches the host so the version-sensitive restore hooks behave
identically:

- **tmux 3.6a, neovim 0.12.0, claude 2.1.170, node 24.14.1** — installed via
  mise, pinned in `mise.toml` (mirrors the host's `~/.config/mise/config.toml`).
- **Real, authenticated claude** — the OAuth token is extracted from the macOS
  Keychain at runtime into a 0700 tmpdir, mounted read-only as the seed; it
  never lands in the image or the repo. Runs as a **non-root** user (claude
  refuses `bypassPermissions` under root, and production isn't root).
- **Real tmux-resurrect + tmux-continuum + restore-wrapper.sh** — mounted from
  the host `~/.config/tmux`. The `cl`/`clr` aliases come from the host
  `~/.config/zsh`. The claude-rescue **working tree** is mounted at
  `/opt/claude-rescue`, so the test exercises uncommitted changes directly.

Known fidelity gap: the container is Linux, the host is macOS — faithful for the
concurrency/race/hook logic (what's under test), **not** for BSD-vs-GNU shell
portability. Keep the host `scripts/validate-*.sh` for that.

## Files

| File | Role |
|---|---|
| `Dockerfile` + `mise.toml` | Image: base tools + host-pinned tmux/nvim/claude/node |
| `entrypoint.sh` | Env prep: credentials, claude-rescue hooks, onboarding flags |
| `container.tmux.conf` | Production-mirroring config that fires BOTH restore triggers at boot |
| `harness.sh` | In-container test (tmux-native, bash). Emits `RESULT_JSON:` |
| `run.sh` | Single run / interactive shell |
| `orchestrate.py` | Parallel scenario matrix over isolated compose projects |
| `docker-compose.yml` | Service wiring (build, mounts, env) |

## Usage

```sh
# one run (NPANES defaults to 2)
test/docker/run.sh

# interactive zsh in the wired container — cl/clr are ready
test/docker/run.sh shell

# parallel scenario matrix (build once, fan out, aggregate)
test/docker/orchestrate.py --npanes 1 2 3
test/docker/orchestrate.py --npanes 2 --repeat 5   # flakiness confidence
```

Requires Docker Desktop running and the claude token in the macOS Keychain
(service `Claude Code-credentials`).

## What it asserts

Per pane, after a `kill -9` crash + dual-trigger reboot:

- both restore triggers fired (`resurrect-restore` hook ≥2× this boot);
- **exactly one** `post-restore-clr` per session (idempotency guard held under
  the real concurrent double-fire) — the load-bearing check;
- exactly one idempotency claim dir;
- the pre-fill is cwd-anchored `cd <launch-cwd> && clr <sid>` (launch cwd via
  `find-sessions`, which real claude transcripts exercise), present in exactly
  one pane, at a shell, with no garbled concatenation.

## Notes

- The image disables apt signature checks (`99insecure`) because this host's
  clock reads 2026, which makes Debian's archive keys look expired. Throwaway
  **local test image only** — never ship it.
- `IS_SANDBOX=1` suppresses claude's bypass-mode warning; onboarding flags in
  `entrypoint.sh` skip the first-run theme picker and trust dialogs.
