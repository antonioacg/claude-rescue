# Shared helpers for claude-rescue scripts. Source from bin/* and tmux/hooks/*.
# Requires bash, jq, uuidgen, tmux.
#
# Storage layout (XDG-style):
#   $CLAUDE_RESCUE_CONFIG_HOME — config file (config.sh, sourced if present)
#     default: ${XDG_CONFIG_HOME:-~/.config}/claude-rescue
#   $CLAUDE_RESCUE_DATA_HOME — durable event logs, indexes
#     default: ${XDG_DATA_HOME:-~/.local/share}/claude-rescue
#   $CLAUDE_RESCUE_CACHE_HOME — ephemeral state, error logs, sample cache
#     default: ${XDG_CACHE_HOME:-~/.cache}/claude-rescue

CLAUDE_RESCUE_CONFIG_HOME="${CLAUDE_RESCUE_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-rescue}"

# Source user config file if present. Allowed to override the data/cache homes
# below, and to set $CLAUDE_RESCUE_TITLE_FORMATTER and other tunables.
if [ -f "$CLAUDE_RESCUE_CONFIG_HOME/config.sh" ]; then
  # shellcheck disable=SC1090
  . "$CLAUDE_RESCUE_CONFIG_HOME/config.sh"
fi

CLAUDE_RESCUE_DATA_HOME="${CLAUDE_RESCUE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-rescue}"
CLAUDE_RESCUE_CACHE_HOME="${CLAUDE_RESCUE_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-rescue}"

RESCUE_DATA_DIRS=(
  "$CLAUDE_RESCUE_DATA_HOME"
  "$CLAUDE_RESCUE_DATA_HOME/windows"
  "$CLAUDE_RESCUE_DATA_HOME/no-tmux"
  "$CLAUDE_RESCUE_DATA_HOME/captures"
  "$CLAUDE_RESCUE_DATA_HOME/active"
)
RESCUE_CACHE_DIRS=(
  "$CLAUDE_RESCUE_CACHE_HOME"
  "$CLAUDE_RESCUE_CACHE_HOME/tmp"
  "$CLAUDE_RESCUE_CACHE_HOME/hibernated"
  "$CLAUDE_RESCUE_CACHE_HOME/busy"
)

ensure_dirs() {
  local d
  for d in "${RESCUE_DATA_DIRS[@]}" "${RESCUE_CACHE_DIRS[@]}"; do
    [ -d "$d" ] || mkdir -p "$d"
  done
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Walk up the process tree from $$ looking for an ancestor whose comm is
# "claude". Used by hook handlers (SessionStart, SessionEnd, etc.) to capture
# the originating claude PID into events for troubleshooting.
#
# Claude invokes hooks via `/bin/sh -c "<command>"`, so the script's parent is
# sh and the grandparent is claude. The walk is bounded (max 8 hops) so we
# don't loop on detached / re-parented processes.
find_my_claude_pid() {
  local pid=$$ depth=0 comm
  while [ "$pid" -gt 1 ] && [ "$depth" -lt 8 ]; do
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -z "$pid" ] && return 1
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's|.*/||' | tr -d ' ')"
    if [ "$comm" = "claude" ]; then
      echo "$pid"
      return 0
    fi
    depth=$((depth + 1))
  done
  return 1
}

log_err() {
  # tmux's run-shell -b swallows stderr; write directly to a file in cache.
  local err_file="$CLAUDE_RESCUE_CACHE_HOME/rescue-log.err"
  printf '[rescue-log %s] %s\n' "$(now_iso)" "$*" >> "$err_file"
}

# Authority check for an in-flight hibernate-arm subshell.
#
# An arm subshell is detached from its tmux server (run-shell -b → PPID becomes
# 1 the moment tmux exits). It can outlive a kill -9'd server, a teardown, or
# a validator's cleanup. When it wakes from sleep it MUST NOT act on whatever
# pane currently bears the numeric pane_id it captured — that pane might be a
# brand-new unrelated session on a fresh server, or a different claude entirely.
#
# Returns 0 if BOTH:
#   1. The arm pid file still contains our subshell's pid (no setup sweep,
#      no resurrect-restore cleanup, no concurrent arm has rewritten it).
#      The caller passes its own subshell pid in $2 — on bash 4+ this is
#      $BASHPID; on bash 3.2 (macOS default) discover it via
#      $(exec sh -c 'echo $PPID') since $BASHPID is unset.
#   2. The pane's current @claude-pane-id still matches the puuid we armed
#      against (the pane hasn't been recreated; we are still acting on the
#      same logical claude pane).
#
# Args: $1=arm_pid_file, $2=expected_subshell_pid, $3=pane_id, $4=expected_puuid
arm_still_authoritative() {
  local arm_pid_file="$1" expected_bashpid="$2" pane_id="$3" expected_puuid="$4"
  local file_pid current_puuid
  file_pid="$(cat "$arm_pid_file" 2>/dev/null)"
  [ "$file_pid" = "$expected_bashpid" ] || return 1
  current_puuid="$(tmux show-options -pv -t "$pane_id" @claude-pane-id 2>/dev/null)"
  [ "$current_puuid" = "$expected_puuid" ] || return 1
  return 0
}

# Send a signal to a pid only if its current comm matches the expected target
# (default: claude). Defends against pid recycling: if the OS handed our
# recorded pid to an unrelated process between arm and fire, we MUST NOT kill it.
#
# Args: $1=signal (TERM|KILL|0|…), $2=pid, $3=optional target comm (default claude)
kill_only_if_comm() {
  local sig="$1" pid="$2" target="${3:-claude}"
  [ -n "$pid" ] || return 0
  local comm
  comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's|.*/||' | tr -d ' ')"
  [ "$comm" = "$target" ] || return 1
  kill -"$sig" "$pid" 2>/dev/null || true
  return 0
}

# Atomic JSONL append. Lines under PIPE_BUF (typically 512+ bytes) are atomic.
append_event() {
  local window_uuid="$1" json="$2"
  printf '%s\n' "$json" >> "$CLAUDE_RESCUE_DATA_HOME/windows/$window_uuid.jsonl"
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

# Pane UUID: same identity model as window UUID but pane-scoped (`-p`).
# Minted on first SessionStart in a fresh pane; preserved across kill+restore
# via the resurrect sidecar. No lock — a single pane has only one process
# firing SessionStart at a time, so check-then-mint is race-free.
tmux_get_pane_uuid() {
  local pane_id="$1"
  tmux show-options -pv -t "$pane_id" @claude-pane-id 2>/dev/null || true
}

tmux_set_pane_uuid() {
  local pane_id="$1" uuid="$2"
  tmux set-option -pt "$pane_id" @claude-pane-id "$uuid" >/dev/null
}

ensure_pane_uuid() {
  local pane_id="$1"
  local existing
  existing="$(tmux_get_pane_uuid "$pane_id")"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  local fresh
  fresh="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  tmux_set_pane_uuid "$pane_id" "$fresh"
  echo "$fresh"
}

# Unset the pane-scoped @claude-pane-id. Called from the arm-sweep voluntary-
# exit branch when claude vanished without firing SessionEnd (SIGKILL, dialog
# dismiss in some claude versions, etc.) AND no hibernation marker is in
# flight. A SessionEnd-driven exit intentionally KEEPS the option so the
# hibernation marker (keyed by pane_uuid) stays addressable and cmd_session_start
# can clean it up if claude returns. ensure_pane_uuid mints a fresh UUID next
# time SessionStart fires in the pane.
tmux_unset_pane_uuid() {
  local pane_id="$1"
  tmux set-option -upt "$pane_id" @claude-pane-id 2>/dev/null || true
}

# Active session-id file: $DATA/active/<pane_uuid> contains the current claude
# session_id for that pane. Authoritative source for `claude-rescue-resume`,
# preferred over the saved tmux-resurrect `-r <sid>` cmdline (which freezes at
# save time and goes stale on in-claude `/resume`).
#
# Under DATA, not CACHE, so it survives a tmux server restart and isn't subject
# to `~/.cache` cleanup. Cleared by cmd_session_end / cmd_pane_died / arm-sweep.
active_session_file() {
  printf '%s/active/%s' "$CLAUDE_RESCUE_DATA_HOME" "$1"
}

write_active_session() {
  local pane_uuid="$1" sid="$2"
  [ -n "$pane_uuid" ] || return 0
  [ -n "$sid" ] || return 0
  local f tmp
  f="$(active_session_file "$pane_uuid")"
  tmp="$f.tmp.$$"
  printf '%s\n' "$sid" > "$tmp" && mv -f "$tmp" "$f"
}

clear_active_session() {
  local pane_uuid="$1"
  [ -n "$pane_uuid" ] || return 0
  rm -f "$(active_session_file "$pane_uuid")"
}

read_active_session() {
  local pane_uuid="$1"
  [ -n "$pane_uuid" ] || return 0
  local f
  f="$(active_session_file "$pane_uuid")"
  [ -r "$f" ] || return 0
  # Trim trailing newline; tolerate the file disappearing under us.
  head -1 "$f" 2>/dev/null | tr -d '\n'
}

# Returns TSV: session_name<TAB>window_index<TAB>window_name<TAB>pane_current_path
tmux_pane_info() {
  local pane_id="$1"
  tmux display-message -p -t "$pane_id" \
    -F $'#{session_name}\t#{window_index}\t#{window_name}\t#{pane_current_path}' 2>/dev/null
}

# Acquire a mkdir-based lock keyed by (session_name, window_name). Returns
# the lockdir path on stdout. Caller must release_window_lock when done.
acquire_window_lock() {
  local session_name="$1" window_name="$2"
  local key lockdir elapsed=0 timeout_ds=100  # 10 s in deciseconds
  key="$(printf '%s|%s' "$session_name" "$window_name" | shasum | cut -c1-12)"
  lockdir="$CLAUDE_RESCUE_CACHE_HOME/tmp/wlock-$key"
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

# Get the window UUID for a pane, minting a fresh one if not yet set.
# Identity model: a UUID is born on first SessionStart in a window with no
# @claude-window-id. Reuse happens ONLY via the resurrect sidecar
# (kill+restore propagates the option). No name/cwd-based matching: those
# heuristics caused incorrect merges and aren't needed once the sidecar path
# is reliable.
#
# The per-(session_name, window_name) lock prevents two near-simultaneous
# SessionStart hooks (e.g. multi-pane window) from each minting a fresh UUID.
ensure_window_uuid() {
  local pane_id="$1"
  local existing
  existing="$(tmux_get_window_uuid "$pane_id")"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi

  # session_name + window_name are only needed to key the mint-race lock.
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

  local fresh
  fresh="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  tmux_set_window_uuid "$pane_id" "$fresh"
  release_window_lock "$lockdir"
  echo "$fresh"
}

# Rebuild meta.json rollup for a window from its event log.
# Recognizes both observed (`session_start`, `title`) and backfill (`session_start_backfill`,
# `title_backfill`, `session_meta_backfill`) event kinds. `startswith` matches the observed
# event AND its `_backfill` sibling.
rebuild_meta() {
  local window_uuid="$1"
  local log="$CLAUDE_RESCUE_DATA_HOME/windows/$window_uuid.jsonl"
  local meta="$CLAUDE_RESCUE_DATA_HOME/windows/$window_uuid.meta.json"
  [ -f "$log" ] || return 0
  local tmp
  tmp="$(mktemp "$meta.XXXXXX")"
  jq -s --arg uuid "$window_uuid" '
    . as $all
    | {
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
        | map(
            {
              session_id: .[0].session_id,
              started:      (map(select(.kind | startswith("session_start"))) | .[0].ts // null),
              ended:        (map(select(.kind | startswith("session_end")))   | .[0].ts // null),
              cwd:          (map(select(.cwd != null and .cwd != "")) | .[0].cwd // null),
              pane_uuid:    (map(select(.pane_uuid != null)) | .[0].pane_uuid // null),
              source:       (map(select(.source != null)) | .[0].source // null),
              session_name: (map(select(.session_name != null and .session_name != "")) | .[0].session_name // null),
              window_name:  (map(select(.window_name != null and .window_name != ""))   | .[0].window_name // null),
              transcript_path: (map(select(.transcript_path != null)) | .[0].transcript_path // null),
              first_user_message: (
                map(select(.first_user_message != null and .first_user_message != ""))
                | .[0].first_user_message // null
              ),
              own_titles: (
                map(select(.kind | startswith("title")))
                | sort_by(.ts)
              )
            }
            | . + (
                # Fall back to window-level title events (no session_id)
                # within this session''s [started, ended] window when the
                # session itself has no own title events. Keeps backfilled
                # sessions from showing "(no title)" when the window-level
                # timeline obviously covers them.
                if (.own_titles | length) > 0
                then {
                  last_title:  (.own_titles | .[-1].title // null),
                  title_count: (.own_titles | length)
                }
                else
                  ($all
                    | map(select(
                        (.kind | startswith("title"))
                        and (.session_id == null or .session_id == "")
                        and (. as $e | ($e.ts >= (.started // $e.ts)))
                      ))
                    | map(select(
                        (.session_id == null or .session_id == "")
                      ))
                  ) as $win_titles
                  |
                  {
                    last_title: (
                      [
                        $win_titles[]
                        | select(
                            (.ts >= (.started // .ts))
                          )
                      ]
                      | (map(.title)) as $titles
                      | $titles[-1] // null
                    ),
                    title_count: 0
                  }
                end
              )
            | del(.own_titles)
          )
        | sort_by(.started // .ended // "") | reverse
      )
    }
    | . + {
        # Apply per-session window-title fallback now that started/ended are known.
        sessions: (
          .sessions | map(
            . as $s
            | if .last_title != null then .
              else
                . + {
                  last_title: (
                    $all
                    | [.[] | select(
                        (.kind | startswith("title"))
                        and (.session_id == null or .session_id == "")
                        and ($s.started == null or .ts >= $s.started)
                        and ($s.ended   == null or .ts <= $s.ended)
                      )]
                    | sort_by(.ts) | .[-1].title // null
                  )
                }
              end
          )
        ),

        # Distinct cwds touched anywhere in this window, with the latest
        # event ts that referenced each. Useful when a window has had panes
        # in multiple project dirs over its lifetime. Uses $all (the full
        # event array) — `.` here is the rolling meta object, not events.
        cwds: (
          [$all[] | select(.cwd != null and .cwd != "") | {cwd, ts}]
          | group_by(.cwd)
          | map({cwd: .[0].cwd, last_seen: (map(.ts) | max)})
          | sort_by(.last_seen) | reverse
        ),

        # Per-pane summary keyed by pane_uuid (durable identity). Events
        # without pane_uuid (legacy or pre-SessionStart) are excluded — the
        # writer no longer emits transient tmux pane_id, so there is no
        # secondary identity to group by.
        panes: (
          [$all[] | select(.pane_uuid != null and .pane_uuid != "")]
          | group_by(.pane_uuid)
          | map({
              pane_uuid: .[0].pane_uuid,
              first_seen: (map(.ts) | min),
              last_seen:  (map(.ts) | max),
              cwds: (
                [.[] | select(.cwd != null and .cwd != "") | {cwd: .cwd, ts: .ts}]
                | group_by(.cwd)
                | map({cwd: .[0].cwd, last_seen: (map(.ts) | max)})
                | sort_by(.last_seen) | reverse
              ),
              session_count: (
                [.[] | select(.kind | startswith("session_start")) | .session_id]
                | unique | length
              )
            })
          | sort_by(.last_seen) | reverse
        )
      }
  ' "$log" > "$tmp"
  mv "$tmp" "$meta"
}
