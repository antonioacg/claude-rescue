# Shared helpers for claude-rescue scripts. Source from bin/* and tmux/hooks/*.
# Requires bash, jq, uuidgen, tmux.

CLAUDE_RESCUE_HOME="${CLAUDE_RESCUE_HOME:-$HOME/.claude-rescue}"
RESCUE_DIRS=(
  "$CLAUDE_RESCUE_HOME"
  "$CLAUDE_RESCUE_HOME/windows"
  "$CLAUDE_RESCUE_HOME/tmp"
  "$CLAUDE_RESCUE_HOME/stopped"
  "$CLAUDE_RESCUE_HOME/no-tmux"
)

ensure_dirs() {
  local d
  for d in "${RESCUE_DIRS[@]}"; do
    [ -d "$d" ] || mkdir -p "$d"
  done
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_err() { printf '[rescue-log %s] %s\n' "$(now_iso)" "$*" >&2; }

# Atomic JSONL append. Lines under PIPE_BUF (typically 512+ bytes) are atomic.
append_event() {
  local window_uuid="$1" json="$2"
  printf '%s\n' "$json" >> "$CLAUDE_RESCUE_HOME/windows/$window_uuid.jsonl"
}

# tmux helpers ----------------------------------------------------------------

tmux_get_window_uuid() {
  local pane_id="$1"
  tmux show-options -wv -t "$pane_id" @claude-window-id 2>/dev/null || true
}

tmux_set_window_uuid() {
  local pane_id="$1" uuid="$2"
  tmux set-option -wt "$pane_id" @claude-window-id "$uuid" >/dev/null
}

# Returns TSV: session_name<TAB>window_index<TAB>window_name<TAB>pane_current_path
tmux_pane_info() {
  local pane_id="$1"
  tmux display-message -p -t "$pane_id" \
    -F $'#{session_name}\t#{window_index}\t#{window_name}\t#{pane_current_path}' 2>/dev/null
}

# Heal lookup: find a recent index entry matching (window_name, primary_cwd).
# Empty result if no match.
heal_lookup() {
  local window_name="$1" cwd="$2"
  local idx="$CLAUDE_RESCUE_HOME/index.jsonl"
  [ -f "$idx" ] || return 0
  jq -rs --arg wn "$window_name" --arg cwd "$cwd" '
    map(select(.window_name == $wn and .primary_cwd == $cwd))
    | sort_by(.last_seen) | reverse | .[0].window_uuid // empty
  ' "$idx"
}

# Acquire a mkdir-based lock keyed by (session_name, window_name). Returns
# the lockdir path on stdout. Caller must release_window_lock when done.
acquire_window_lock() {
  local session_name="$1" window_name="$2"
  local key lockdir elapsed=0 timeout_ds=100  # 10 s in deciseconds
  key="$(printf '%s|%s' "$session_name" "$window_name" | shasum | cut -c1-12)"
  lockdir="$CLAUDE_RESCUE_HOME/tmp/wlock-$key"
  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 0.1
    elapsed=$((elapsed + 1))
    if [ $elapsed -ge $timeout_ds ]; then
      log_err "acquire_window_lock: timed out on $key"
      return 1
    fi
  done
  echo "$lockdir"
}

release_window_lock() {
  local lockdir="$1"
  [ -n "$lockdir" ] && rmdir "$lockdir" 2>/dev/null || true
}

# Get-or-create the window UUID for a pane. Logs a heal event when adopting.
# Serialized per (session_name, window_name) to avoid the double-mint race.
ensure_window_uuid() {
  local pane_id="$1"
  local existing
  existing="$(tmux_get_window_uuid "$pane_id")"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi

  local info session_name window_index window_name cwd
  info="$(tmux_pane_info "$pane_id")" || true
  if [ -z "$info" ]; then
    return 1  # pane gone
  fi
  IFS=$'\t' read -r session_name window_index window_name cwd <<< "$info"

  local lockdir
  lockdir="$(acquire_window_lock "$session_name" "$window_name")" || return 1

  # Re-check under the lock — another concurrent writer may have set it.
  existing="$(tmux_get_window_uuid "$pane_id")"
  if [ -n "$existing" ]; then
    release_window_lock "$lockdir"
    echo "$existing"
    return 0
  fi

  local healed
  healed="$(heal_lookup "$window_name" "$cwd")"
  if [ -n "$healed" ]; then
    tmux_set_window_uuid "$pane_id" "$healed"
    append_event "$healed" "$(jq -nc \
      --arg ts "$(now_iso)" --arg pane "$pane_id" \
      --arg sn "$session_name" --arg wn "$window_name" --arg cwd "$cwd" \
      '{ts:$ts, kind:"heal", pane_id:$pane, session_name:$sn, window_name:$wn, cwd:$cwd}')"
    update_index "$healed" "$session_name" "$window_name" "$cwd"
    release_window_lock "$lockdir"
    echo "$healed"
    return 0
  fi

  local fresh
  fresh="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  tmux_set_window_uuid "$pane_id" "$fresh"
  update_index "$fresh" "$session_name" "$window_name" "$cwd"
  release_window_lock "$lockdir"
  echo "$fresh"
}

# Update index.jsonl entry for window_uuid (last_seen, latest session_name/window_name/cwd).
update_index() {
  local window_uuid="$1" session_name="$2" window_name="$3" cwd="$4"
  local idx="$CLAUDE_RESCUE_HOME/index.jsonl"
  local tmp
  tmp="$(mktemp "$idx.XXXXXX")"
  {
    if [ -f "$idx" ]; then
      jq -c --arg uuid "$window_uuid" 'select(.window_uuid != $uuid)' "$idx" || true
    fi
    jq -nc \
      --arg uuid "$window_uuid" \
      --arg sn "$session_name" --arg wn "$window_name" \
      --arg cwd "$cwd" --arg ts "$(now_iso)" \
      '{window_uuid:$uuid, session_name:$sn, window_name:$wn, primary_cwd:$cwd, last_seen:$ts}'
  } > "$tmp"
  mv "$tmp" "$idx"
}

# Rebuild meta.json rollup for a window from its event log.
# Recognizes both observed (`session_start`, `title`) and backfill (`session_start_backfill`,
# `title_backfill`, `session_meta_backfill`) event kinds. `startswith` matches the observed
# event AND its `_backfill` sibling.
rebuild_meta() {
  local window_uuid="$1"
  local log="$CLAUDE_RESCUE_HOME/windows/$window_uuid.jsonl"
  local meta="$CLAUDE_RESCUE_HOME/windows/$window_uuid.meta.json"
  [ -f "$log" ] || return 0
  local tmp
  tmp="$(mktemp "$meta.XXXXXX")"
  jq -s --arg uuid "$window_uuid" '
    {
      window_uuid: $uuid,
      first_seen: (map(.ts) | min),
      last_seen:  (map(.ts) | max),
      primary_cwd: (
        [.[] | select(.cwd != null and .cwd != "") | .cwd]
        | if length == 0 then null else .[-1] end
      ),
      session_name: (
        [.[] | select(.session_name != null and .session_name != "") | .session_name]
        | if length == 0 then null else .[-1] end
      ),
      window_name: (
        [.[] | select(.window_name != null and .window_name != "") | .window_name]
        | if length == 0 then null else .[-1] end
      ),
      sessions: (
        [.[] | select(.session_id != null)]
        | group_by(.session_id)
        | map({
            session_id: .[0].session_id,
            started:      (map(select(.kind | startswith("session_start"))) | .[0].ts // null),
            ended:        (map(select(.kind | startswith("session_end")))   | .[0].ts // null),
            cwd:          (map(select(.cwd != null and .cwd != "")) | .[0].cwd // null),
            pane_id:      (map(select(.pane_id != null)) | .[0].pane_id // null),
            source:       (map(select(.source != null)) | .[0].source // null),
            session_name: (map(select(.session_name != null and .session_name != "")) | .[0].session_name // null),
            window_name:  (map(select(.window_name != null and .window_name != ""))   | .[0].window_name // null),
            transcript_path: (map(select(.transcript_path != null)) | .[0].transcript_path // null),
            first_user_message: (
              map(select(.first_user_message != null and .first_user_message != ""))
              | .[0].first_user_message // null
            ),
            last_title: (
              map(select(.kind | endswith("title")))
              | sort_by(.ts) | .[-1].title // null
            ),
            title_count: (map(select(.kind | endswith("title"))) | length)
          })
        | sort_by(.started // .ended // "") | reverse
      )
    }
  ' "$log" > "$tmp"
  mv "$tmp" "$meta"
}
