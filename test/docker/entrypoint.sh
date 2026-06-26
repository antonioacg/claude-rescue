#!/usr/bin/env bash
# Container entrypoint — prepare a ready-to-use claude environment, then exec the
# command. Keeps environment prep (creds, onboarding flags, tracking hooks) out
# of the test logic, and means an interactive `zsh -i` shell ALSO has a working
# `cl`/`clr` (run.sh shell), not just the harness.
set -e

# 1. Credentials (extracted host-side from the macOS Keychain, mounted at /seed).
if [ -f /seed/.credentials.json ]; then
  mkdir -p "$HOME/.claude"
  cp /seed/.credentials.json "$HOME/.claude/.credentials.json"
  chmod 600 "$HOME/.claude/.credentials.json"
fi

# 2. claude-rescue tracking hooks. session_start is the load-bearing one: it
#    mints @claude-pane-id and writes the event meta find-sessions reads.
cat > "$HOME/.claude/settings.json" <<'JSON'
{ "hooks": {
  "SessionStart":     [{"hooks":[{"type":"command","command":"claude-rescue-log session_start"}]}],
  "SessionEnd":       [{"hooks":[{"type":"command","command":"claude-rescue-log session_end"}]}],
  "Stop":             [{"hooks":[{"type":"command","command":"claude-rescue-log stop"}]}],
  "UserPromptSubmit": [{"hooks":[{"type":"command","command":"claude-rescue-log user_prompt_submit"}]}],
  "PreToolUse":       [{"hooks":[{"type":"command","command":"claude-rescue-log pre_tool_use"}]}],
  "PostToolUse":      [{"hooks":[{"type":"command","command":"claude-rescue-log post_tool_use"}]}]
} }
JSON

# 3. Onboarding-complete + bypass-accepted flags so claude skips the first-run
#    theme picker, the per-project trust dialog, and the bypass-mode warning
#    (IS_SANDBOX=1, set in compose, also suppresses the bypass warning). The
#    harness merges per-project entries on top for its own project dirs.
if [ ! -f "$HOME/.claude.json" ]; then
  jq -n '{hasCompletedOnboarding:true, theme:"dark", numStartups:100,
          lastOnboardingVersion:"1.0.5", bypassPermissionsModeAccepted:true,
          projects:{}}' > "$HOME/.claude.json"
fi

exec "$@"
