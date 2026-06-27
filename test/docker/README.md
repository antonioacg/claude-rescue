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
  The image runs `mise activate zsh` (like the host `~/.zshrc`) so commands
  resolve to their install bins and process **argv stays bare** (`nvim`, not the
  shim's full install path) — matching macOS, so the *same* production
  `@resurrect-processes` proc-match restores nvim/claude in the container.
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
| `container-single-trigger.tmux.conf` | Cleanup variant: continuum-restore off, restore-wrapper sole path (one trigger) |
| `harness.sh` | Default scenario: N hard-hibernated panes → dual/single idempotency + nvim restore. Emits `RESULT_JSON:` |
| `harness-multisession.sh` | #2 regression: ≥2 sessions in one pane → pre-fill anchors the *captured* session's cwd (not find-sessions `head -1`) |
| `harness-wrapper-resume.sh` | #9 regression: soft-hibernate + force restore into `$HOME` → the `@resurrect-processes` wrapper cd-rescues and resumes the *same* session |
| `run.sh` | Single run / scenario / interactive shell |
| `orchestrate.py` | Parallel scenario matrix over isolated compose projects |
| `docker-compose.yml` | Service wiring (build, mounts, env) |

## Usage

```sh
# one run (NPANES defaults to 2, dual-trigger)
test/docker/run.sh

# single-trigger cleanup variant (continuum off, restore-wrapper sole path)
CLR_MODE=single test/docker/run.sh

# review follow-up regression scenarios (each is a self-contained run)
test/docker/run.sh multisession     # #2 — multi-session-per-pane cwd disambiguation
test/docker/run.sh wrapper-resume   # #9 — wrapper-resume cd-rescue into the right dir

# interactive zsh in the wired container — cl/clr are ready
test/docker/run.sh shell

# parallel scenario matrix (build once, fan out, aggregate)
test/docker/orchestrate.py --npanes 1 2 3
test/docker/orchestrate.py --mode dual single        # prod wiring vs the cleanup
test/docker/orchestrate.py --npanes 2 --repeat 5     # flakiness confidence
```

## Trigger modes

- **`dual`** (default) — mirrors the deployed `dot_tmux.conf`: continuum's own
  auto-restore **and** the boot-guard `restore-wrapper.sh` both fire. Proves the
  idempotency guard holds under the genuine double-fire.
- **`single`** (`CLR_MODE=single`) — the proposed cleanup: `@continuum-restore
  off` + the boot-guard rewired so `restore-wrapper.sh` is the sole restore
  path. Proves restore still fires **exactly once** and still brings back claude
  pre-fills **and nvim** — i.e. the cleanup loses nothing.

Requires Docker Desktop running and the claude token in the macOS Keychain
(service `Claude Code-credentials`).

## What it asserts

After a `kill -9` crash + reboot:

- restore triggers fired the expected number of times — `≥2` in `dual` mode,
  **exactly 1** in `single` mode (the cleanup proof);
- per pane, **exactly one** `post-restore-clr` per session (idempotency guard;
  load-bearing in `dual`, trivially true in `single`) and exactly one claim dir;
- the pre-fill is cwd-anchored `cd <launch-cwd> && clr <sid>`, with launch cwd
  resolved via the `find-sessions` **primary** path (asserted directly — real
  claude transcripts make it resolvable), present in exactly one pane, at a
  shell, with no garbled concatenation;
- **nvim is restored** (process back + buffer content visible) — proves restore
  brings back non-claude processes too, in both modes (the single-mode case
  answers "does the cleanup still restore nvim?").

## Notes

- The image disables apt signature checks (`99insecure`) because this host's
  clock reads 2026, which makes Debian's archive keys look expired. Throwaway
  **local test image only** — never ship it.
- `IS_SANDBOX=1` suppresses claude's bypass-mode warning; onboarding flags in
  `entrypoint.sh` skip the first-run theme picker and trust dialogs.
