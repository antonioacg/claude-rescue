#!/usr/bin/env python3
"""Parallel orchestrator for the dual-trigger restore idempotency test.

Builds the image once, extracts the claude OAuth token from the macOS Keychain
into a shared read-only seed dir, then fans out scenarios as PARALLEL
`docker compose run` instances — each on its own compose project so they are
fully isolated — and aggregates each run's RESULT_JSON into one pass/fail report.

This is the layer that's meant to evolve: add scenarios, vary config, or repeat
for flakiness confidence, without touching the proven in-container bash harness.

Examples:
  ./orchestrate.py                    # default matrix: NPANES=1 and NPANES=2
  ./orchestrate.py --npanes 1 2 3     # three scenarios
  ./orchestrate.py --npanes 2 --repeat 5   # same scenario 5x in parallel
  ./orchestrate.py --max-parallel 2
"""
import argparse
import concurrent.futures as cf
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def extract_token(seed_dir: str) -> None:
    """Pull the claude OAuth token from the Keychain into seed_dir/.credentials.json."""
    user = os.environ.get("USER") or subprocess.check_output(["whoami"], text=True).strip()
    cred = os.path.join(seed_dir, ".credentials.json")
    for acct in (user, "antoniocasagrande"):
        r = subprocess.run(
            ["security", "find-generic-password", "-w", "-s", "Claude Code-credentials", "-a", acct],
            capture_output=True, text=True,
        )
        if r.returncode == 0 and r.stdout.strip():
            with open(cred, "w") as f:
                f.write(r.stdout)
            os.chmod(cred, 0o600)
            return
    raise SystemExit("FATAL: could not extract claude token from Keychain")


def run_scenario(idx: int, npanes: int, env: dict) -> dict:
    proj = f"clr-rt-{idx}"
    e = dict(env, NPANES=str(npanes))
    run = subprocess.run(
        ["docker", "compose", "-p", proj, "run", "--rm", "harness"],
        cwd=HERE, env=e, capture_output=True, text=True,
    )
    result = None
    for line in run.stdout.splitlines():
        if line.startswith("RESULT_JSON:"):
            try:
                result = json.loads(line.split("RESULT_JSON:", 1)[1])
            except json.JSONDecodeError:
                pass
    # Tear down the per-scenario project (network etc.); the container is --rm'd.
    subprocess.run(["docker", "compose", "-p", proj, "down", "-v"],
                   cwd=HERE, env=e, capture_output=True, text=True)
    return {"idx": idx, "npanes": npanes, "exit": run.returncode,
            "result": result, "stdout": run.stdout, "stderr": run.stderr}


def is_green(r: dict) -> bool:
    return r["exit"] == 0 and bool(r["result"]) and r["result"].get("fail") == 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--npanes", type=int, nargs="+", default=[1, 2],
                    help="pane counts to test (default: 1 2)")
    ap.add_argument("--repeat", type=int, default=1,
                    help="repeat each scenario N times for flakiness confidence")
    ap.add_argument("--max-parallel", type=int, default=4)
    args = ap.parse_args()

    env = dict(os.environ)
    seed_dir = tempfile.mkdtemp(prefix="clr-docker-seed.")
    os.chmod(seed_dir, 0o700)
    env["CLR_SEED"] = seed_dir
    try:
        extract_token(seed_dir)

        print("building image once...", flush=True)
        if subprocess.run(["docker", "compose", "build"], cwd=HERE, env=env).returncode != 0:
            raise SystemExit("image build failed")

        scenarios = list(enumerate(n for n in args.npanes for _ in range(args.repeat)))
        print(f"running {len(scenarios)} scenario(s), up to {args.max_parallel} in parallel...\n", flush=True)

        results = []
        with cf.ThreadPoolExecutor(max_workers=args.max_parallel) as ex:
            futs = {ex.submit(run_scenario, i, n, env): (i, n) for i, n in scenarios}
            for fut in cf.as_completed(futs):
                r = fut.result()
                results.append(r)
                res = r["result"] or {}
                tag = "PASS" if is_green(r) else "FAIL"
                print(f"  [{tag}] scenario {r['idx']} npanes={r['npanes']} "
                      f"pass={res.get('pass','?')} fail={res.get('fail','?')} exit={r['exit']}",
                      flush=True)

        green = sum(1 for r in results if is_green(r))
        print(f"\n=== {green}/{len(results)} scenarios green ===")
        if green != len(results):
            for r in sorted(results, key=lambda r: r["idx"]):
                if not is_green(r):
                    print(f"\n--- scenario {r['idx']} npanes={r['npanes']} (exit {r['exit']}) tail ---")
                    print("\n".join(r["stdout"].splitlines()[-25:]))
                    if r["stderr"].strip():
                        print("[stderr]", "\n".join(r["stderr"].splitlines()[-10:]))
            return 1
        return 0
    finally:
        shutil.rmtree(seed_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
