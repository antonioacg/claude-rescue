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
case "${1:-test}" in
  build)          exec docker compose build ;;
  test)           exec docker compose run --rm harness ;;
  multisession)   exec docker compose run --rm harness bash "$D/harness-multisession.sh" ;;     # #2 regression
  wrapper-resume) exec docker compose run --rm harness bash "$D/harness-wrapper-resume.sh" ;;   # #9 regression
  shell)          exec docker compose run --rm harness zsh -i ;;
  *) echo "usage: $0 [build|test|multisession|wrapper-resume|shell]" >&2; exit 2 ;;
esac
