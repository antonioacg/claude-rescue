# Per-session config (claude-harness): read/write/resolve.
#
# Backs the popup editor (bin/claude-session-config), the PreToolUse gate
# (bin/claude-ask-hook), and any external indicator (e.g. limitline segment).
#
# Resolution chain (last wins via jq deep-merge):
#   1. built-in defaults — see session_config_builtin
#   2. user defaults     — $CLAUDE_RESCUE_CONFIG_HOME/session-config-defaults.json
#   3. per-session       — $CLAUDE_RESCUE_DATA_HOME/session-config/<session_id>.json
#
# Requires lib/common.sh to be sourced first (uses $CLAUDE_RESCUE_*_HOME and
# read_active_session).

session_config_dir() { printf '%s/session-config' "$CLAUDE_RESCUE_DATA_HOME"; }
session_config_path() { printf '%s/%s.json' "$(session_config_dir)" "$1"; }
session_defaults_path() { printf '%s/session-config-defaults.json' "$CLAUDE_RESCUE_CONFIG_HOME"; }

# Built-in baseline. Every key the popup or hook knows about MUST appear here
# so the merged config always resolves to a concrete value.
session_config_builtin() {
  cat <<'JSON'
{
  "ask_on_edits": false,
  "ask_on_bash": false,
  "editor_on_ask": false,
  "editor_command": "code -g"
}
JSON
}

resolve_session_config() {
  local sid="${1:-}"
  local user="{}" session="{}"
  local def_path
  def_path="$(session_defaults_path)"
  [ -f "$def_path" ] && user="$(cat "$def_path")"
  if [ -n "$sid" ]; then
    local sp
    sp="$(session_config_path "$sid")"
    [ -f "$sp" ] && session="$(cat "$sp")"
  fi
  printf '%s\n%s\n%s\n' "$(session_config_builtin)" "$user" "$session" \
    | jq -s 'reduce .[] as $o ({}; . * $o)'
}

get_session_config_value() {
  local sid="$1" key="$2"
  resolve_session_config "$sid" | jq -r --arg k "$key" '.[$k]'
}

# Writes a single key to the session-specific override file. $3 must be a
# JSON literal (true, false, "string", 123).
set_session_config_value() {
  local sid="$1" key="$2" value="$3"
  [ -n "$sid" ] || return 1
  mkdir -p "$(session_config_dir)"
  local f tmp existing="{}"
  f="$(session_config_path "$sid")"
  [ -f "$f" ] && existing="$(cat "$f")"
  tmp="$f.tmp.$$"
  printf '%s' "$existing" | jq --argjson v "$value" --arg k "$key" '.[$k] = $v' > "$tmp"
  mv -f "$tmp" "$f"
}

# Resolve the active claude session_id for a tmux pane via the same chain the
# resume picker uses: pane → @claude-pane-id → $DATA/active/<pane_uuid>.
# Empty stdout on any miss; callers decide whether absence is an error.
resolve_pane_session_id() {
  local pane="${1:-${CLAUDE_RESCUE_ORIG_PANE:-${TMUX_PANE:-}}}"
  [ -n "$pane" ] || return 0
  local puuid
  puuid="$(tmux show-options -pv -t "$pane" @claude-pane-id 2>/dev/null || true)"
  [ -n "$puuid" ] || return 0
  read_active_session "$puuid"
}
