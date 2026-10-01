#!/usr/bin/env bash
# Single-run / interactive entry for the dual-trigger restore container test.
# For the parallel scenario matrix, use orchestrate.py instead.
#
# Extracts the claude OAuth token from the macOS Keychain into a 0700 tmpdir and
# mounts it read-only as the credential seed (the Keychain is only READ; the
# token never lands in the image or the repo), then drives docker compose.
#
#   run.sh build     build the image
#   run.sh test      run the harness once (default)
#   run.sh shell     interactive zsh in the wired container (cl/clr ready)
set -euo pipefail
cd "$(dirname "$0")"

CLR_SEED="$(mktemp -d /tmp/clr-docker-seed.XXXXXX)"; chmod 700 "$CLR_SEED"
export CLR_SEED
trap 'rm -rf "$CLR_SEED"' EXIT
security find-generic-password -w -s "Claude Code-credentials" -a "$(whoami)" \
  > "$CLR_SEED/.credentials.json" 2>/dev/null \
  || security find-generic-password -w -s "Claude Code-credentials" -a antoniocasagrande \
       > "$CLR_SEED/.credentials.json"
chmod 600 "$CLR_SEED/.credentials.json"
[ -s "$CLR_SEED/.credentials.json" ] || { echo "FATAL: could not extract claude token from Keychain" >&2; exit 1; }

D=/opt/claude-rescue/test/docker

# Pin the compose project. Without -p, compose takes the project name from
# $COMPOSE_PROJECT_NAME, which on a dev machine may already name an unrelated
# local service stack — the harness would then join that project, create its
# network, and report the developer's own containers as orphans. Worse, any
# later `docker compose down` here would reach them. -p wins over the
# environment (flag > COMPOSE_PROJECT_NAME > compose-file `name:` > directory),
# and orchestrate.py already pins one project per scenario. The image name is
# fixed in docker-compose.yml, so pinning this does not invalidate a built image.
DC=(docker compose -p clr-rt-run)

case "${1:-test}" in
  build)          exec "${DC[@]}" build ;;
  test)           exec "${DC[@]}" run --rm harness ;;
  multisession)   exec "${DC[@]}" run --rm harness bash "$D/harness-multisession.sh" ;;     # #2 regression
  wrapper-resume) exec "${DC[@]}" run --rm harness bash "$D/harness-wrapper-resume.sh" ;;   # #9 regression
  relaunch)       exec "${DC[@]}" run --rm harness bash "$D/harness-relaunch.sh" ;;         # 2026-10-01 regression
  shell)          exec "${DC[@]}" run --rm harness zsh -i ;;
  *) echo "usage: $0 [build|test|multisession|wrapper-resume|relaunch|shell]" >&2; exit 2 ;;
esac
