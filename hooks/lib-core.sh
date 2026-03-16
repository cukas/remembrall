#!/usr/bin/env bash
# sourced by lib.sh
# lib-core.sh — Core utilities: config, debug, hashing, comparisons

# ─── Debug Logging ─────────────────────────────────────────────────
# Enable via config: remembrall_config_set "debug" "true"
# Or env: REMEMBRALL_DEBUG=1
# Logs to ~/.remembrall/debug.log (rotated at 1MB)

remembrall_debug() {
  # Fast path: check cached env var (no jq call after first invocation)
  case "${_REMEMBRALL_DEBUG_CACHED:-}" in
    0) return 0 ;;  # debug off — cached
    1) ;;           # debug on — fall through to log
    *)
      # First call: resolve from env or config, then cache
      if [ "${REMEMBRALL_DEBUG:-}" = "1" ]; then
        export _REMEMBRALL_DEBUG_CACHED=1
      else
        local debug_enabled
        debug_enabled=$(remembrall_config "debug" "false" 2>/dev/null)
        if [ "$debug_enabled" = "true" ]; then
          export _REMEMBRALL_DEBUG_CACHED=1
        else
          export _REMEMBRALL_DEBUG_CACHED=0
          return 0
        fi
      fi
      ;;
  esac

  local log_file="$HOME/.remembrall/debug.log"
  mkdir -p "$HOME/.remembrall" 2>/dev/null

  # Rotate at 1MB
  if [ -f "$log_file" ]; then
    local size
    size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ')
    if [ "${size:-0}" -gt 1048576 ] 2>/dev/null; then
      mv "$log_file" "${log_file}.1" 2>/dev/null
    fi
  fi

  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${REMEMBRALL_HOOK:-remembrall}" "$*" >> "$log_file" 2>/dev/null
}

# ─── Configurable Thresholds ──────────────────────────────────────
# Users can override nudge thresholds via config.json:
#   threshold_journal (default: 60) — first nudge: "run /handoff"
#   threshold_warning (default: 35) — second nudge: "run /handoff then EnterPlanMode"
#   threshold_urgent  (default: 15) — final nudge: two-stage block

remembrall_threshold() {
  local name="$1"
  local default="$2"
  local val
  val=$(remembrall_config "threshold_${name}" "$default" 2>/dev/null)
  if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] && [ "$val" -lt 100 ] 2>/dev/null; then
    echo "$val"
  else
    echo "$default"
  fi
}

# Require jq — exit gracefully if not available
remembrall_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "remembrall: jq not found — hook disabled" >&2
    exit 0
  fi
}

# Cross-platform md5 hash
remembrall_md5() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -qs "$1"
  elif command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  else
    return 1
  fi
}

# Normalize a directory path for stable per-project storage keys.
# Strips trailing slashes and resolves symlinks when the directory exists.
remembrall_normalize_dir() {
  local path="$1"
  [ -n "$path" ] || return 1

  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done

  if [ -d "$path" ]; then
    (cd -P "$path" 2>/dev/null && pwd -P) || return 1
  else
    printf '%s\n' "$path"
  fi
}

remembrall_project_hash() {
  local cwd="$1"
  local normalized
  normalized=$(remembrall_normalize_dir "$cwd") || return 1
  remembrall_md5 "$normalized"
}

remembrall_project_slug() {
  local cwd="$1"
  local normalized
  normalized=$(remembrall_normalize_dir "$cwd") || return 1

  local project_name
  project_name=$(basename "$normalized")
  project_name=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | sed 's/^\.*//' | sed 's/[^a-z0-9_-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  [ -z "$project_name" ] && project_name="default"
  printf '%s\n' "$project_name"
}

remembrall_project_storage_dir() {
  local root="$1"
  local cwd="$2"
  local full_hash
  full_hash=$(remembrall_project_hash "$cwd") || return 1
  local project_name
  project_name=$(remembrall_project_slug "$cwd") || return 1
  local short_hash
  short_hash=$(printf '%s' "$full_hash" | cut -c1-8)
  local new_dir="$root/${project_name}-${short_hash}"
  local old_dir="$root/${full_hash}"

  if [ -d "$new_dir" ]; then
    echo "$new_dir"
    return
  fi

  if [ -d "$old_dir" ]; then
    echo "$old_dir"
    return
  fi

  # Compatibility fallback: if a pre-normalization directory exists with the
  # same hash suffix but a different slug, reuse it.
  local candidate
  local compatible_dir=""
  local matches=0
  for candidate in "$root"/*-"$short_hash"; do
    [ -d "$candidate" ] || continue
    compatible_dir="$candidate"
    matches=$((matches + 1))
  done
  if [ "$matches" -eq 1 ]; then
    echo "$compatible_dir"
  else
    echo "$new_dir"
  fi
}

# Cross-platform file age in seconds (returns 0 on stat failure)
remembrall_file_age() {
  local file="$1"
  local mtime
  if [ "$(uname)" = "Darwin" ]; then
    mtime=$(stat -f %m "$file" 2>/dev/null) || { echo 0; return; }
  else
    mtime=$(stat -c %Y "$file" 2>/dev/null) || { echo 0; return; }
  fi
  echo $(( $(date +%s) - mtime ))
}

# JSON-safe string escaping using jq (RFC 8259 compliant)
remembrall_escape_json() {
  printf '%s' "$1" | jq -Rs . | sed 's/^"//;s/"$//'
}

# Validate that a value is a number (integer or decimal)
remembrall_validate_number() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# ─── Integer Comparison ──────────────────────────────────────────

# Compare a number (possibly decimal) against an integer threshold.
# Usage: remembrall_gt "$REMAINING" 60 → returns 0 (true) if REMAINING > 60
# Truncates decimals — "42.7" becomes 42. No bc dependency.
remembrall_gt() {
  local val="${1%%.*}"  # truncate decimal
  local threshold="$2"
  [ -z "$val" ] && return 1
  [ "$val" -gt "$threshold" ] 2>/dev/null
}

remembrall_le() {
  local val="${1%%.*}"
  local threshold="$2"
  [ -z "$val" ] && return 1
  [ "$val" -le "$threshold" ] 2>/dev/null
}

remembrall_ge() {
  local val="${1%%.*}"
  local threshold="$2"
  [ -z "$val" ] && return 1
  [ "$val" -ge "$threshold" ] 2>/dev/null
}

# ─── Config ────────────────────────────────────────────────────────

# Read a config value from ~/.remembrall/config.json
# Usage: remembrall_config "key" "default_value"
remembrall_config() {
  local key="$1"
  local default="$2"
  local config_file="$HOME/.remembrall/config.json"

  if [ ! -f "$config_file" ]; then
    echo "$default"
    return
  fi

  local value
  # Use raw jq to get the value; .[$k] // empty returns nothing for missing keys
  # Use tostring for scalars, raw output for arrays/objects
  value=$(jq -r --arg k "$key" 'if has($k) then (if (.[$k] | type) == "array" or (.[$k] | type) == "object" then .[$k] | tojson else .[$k] | tostring end) else empty end' "$config_file" 2>/dev/null)

  if [ -z "$value" ]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# Validate config values before writing
# Returns 0 if valid, 1 if invalid (prints error to stderr)
remembrall_config_validate() {
  local key="$1"
  local value="$2"
  case "$key" in
    retention_hours)
      if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -eq 0 ]; then
        echo "remembrall: invalid retention_hours '$value' — must be a positive integer" >&2
        return 1
      fi
      ;;
    max_transcript_kb|recency_window|pensieve_max_sessions|pensieve_inject_budget)
      if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -eq 0 ]; then
        echo "remembrall: invalid $key '$value' — must be a positive integer" >&2
        return 1
      fi
      ;;
    time_turner_max_budget_usd)
      if ! [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "remembrall: invalid $key '$value' — must be a positive number" >&2
        return 1
      fi
      ;;
    time_turner_model)
      case "$value" in
        sonnet|opus|haiku) ;;
        *) echo "remembrall: invalid $key '$value' — must be sonnet, opus, or haiku" >&2; return 1 ;;
      esac
      ;;
    autonomous_mode|git_integration|team_handoffs|easter_eggs|debug|pensieve|time_turner|phoenix_mode)
      if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        echo "remembrall: invalid $key '$value' — must be true or false" >&2
        return 1
      fi
      ;;
    threshold_journal|threshold_warning|threshold_urgent|threshold_timeturner|phoenix_max_cycles)
      if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -eq 0 ] || [ "$value" -ge 100 ]; then
        echo "remembrall: invalid $key '$value' — must be an integer between 1 and 99" >&2
        return 1
      fi
      ;;
    disabled_hooks)
      if ! echo "$value" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "remembrall: invalid disabled_hooks '$value' — must be a JSON array" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

# Write a config value to ~/.remembrall/config.json
# Creates the file and directory if they don't exist
remembrall_config_set() {
  local key="$1"
  local value="$2"
  local config_file="$HOME/.remembrall/config.json"

  # Validate before writing
  if ! remembrall_config_validate "$key" "$value"; then
    return 1
  fi

  mkdir -p "$(dirname "$config_file")"

  if [ ! -f "$config_file" ]; then
    echo '{}' > "$config_file"
  fi

  local tmp
  tmp=$(mktemp "${config_file}.XXXXXX")
  # Store booleans and numbers as native JSON types, strings as strings
  local jq_ok=false
  if [ "$value" = "true" ] || [ "$value" = "false" ] || [[ "$value" =~ ^[0-9]+$ ]]; then
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$config_file" > "$tmp" 2>/dev/null && jq_ok=true
  else
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$config_file" > "$tmp" 2>/dev/null && jq_ok=true
  fi

  if [ "$jq_ok" = true ]; then
    mv "$tmp" "$config_file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# ─── Hook Enable/Disable ─────────────────────────────────────

# Check if a hook is enabled (not in the disabled_hooks list).
# Returns 0 (enabled) or 1 (disabled).
remembrall_hook_enabled() {
  local hook_name="$1"
  local disabled
  disabled=$(remembrall_config "disabled_hooks" "[]")
  if echo "$disabled" | jq -e --arg h "$hook_name" 'index($h)' >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ─── Session ID Publishing ────────────────────────────────────────

# Publish session_id so skill bash commands can read it.
# Hooks have session_id from JSON input; Bash tool commands don't.
# Written on every prompt by context-monitor.sh — always current.
# ─── Plugin Root Discovery ────────────────────────────────────────
# Hooks get CLAUDE_PLUGIN_ROOT from Claude Code automatically.
# Skills/commands run in a bare shell where it's NOT set.
# Persist the root on every hook run so skills can find it.

remembrall_publish_plugin_root() {
  [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && return
  local dir="/tmp/remembrall-meta"
  mkdir -p "$dir" 2>/dev/null
  printf '%s' "$CLAUDE_PLUGIN_ROOT" > "$dir/plugin-root" 2>/dev/null
}

# Read the persisted plugin root. Falls back to CLAUDE_PLUGIN_ROOT env var.
remembrall_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
    return
  fi
  local f="/tmp/remembrall-meta/plugin-root"
  if [ -f "$f" ]; then
    cat "$f" 2>/dev/null
    return
  fi
  return 1
}

remembrall_publish_session_id() {
  local cwd="$1"
  local session_id="$2"
  [ -z "$session_id" ] && return
  local hash
  hash=$(remembrall_project_hash "$cwd") || return
  local dir="/tmp/remembrall-sessions"
  mkdir -p "$dir" 2>/dev/null
  printf '%s' "$session_id" > "$dir/$hash" 2>/dev/null
}

# Read the published session_id for a CWD.
# Used by handoff-create.sh when CLAUDE_SESSION_ID env var isn't available.
remembrall_read_session_id() {
  local cwd="$1"
  local hash
  hash=$(remembrall_project_hash "$cwd") || return 1
  local f="/tmp/remembrall-sessions/$hash"
  [ -f "$f" ] && cat "$f" 2>/dev/null
}

# ─── Hook Output Helper ──────────────────────────────────────────
# Emit canonical hookSpecificOutput JSON for UserPromptSubmit or SessionStart.
# Handles JSON escaping of the message automatically.
# Usage: remembrall_emit_hook "UserPromptSubmit" "message" ["system_message"]
remembrall_emit_hook() {
  local event="$1"
  local message="$2"
  local system_msg="${3:-}"

  # Escape message for JSON embedding
  local escaped_msg
  escaped_msg=$(printf '%s' "$message" | jq -Rs '.' 2>/dev/null) || escaped_msg="\"$message\""

  if [ -n "$system_msg" ]; then
    local escaped_sys
    escaped_sys=$(printf '%s' "$system_msg" | jq -Rs '.' 2>/dev/null) || escaped_sys="\"$system_msg\""
    cat <<EMIT_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "$event",
    "additionalContext": $escaped_msg
  },
  "systemMessage": $escaped_sys
}
EMIT_EOF
  else
    cat <<EMIT_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "$event",
    "additionalContext": $escaped_msg
  }
}
EMIT_EOF
  fi
}

# ─── Autonomous Mode Check ───────────────────────────────────────
# Check if current session is in autonomous mode (config or per-session flag)
# Usage: if remembrall_check_autonomous "$SESSION_ID"; then ...
remembrall_check_autonomous() {
  local session_id="${1:-}"
  if [ "$(remembrall_config "autonomous_mode" "true")" = "true" ]; then
    return 0
  fi
  if [ -n "$session_id" ]; then
    remembrall_is_autonomous "$session_id" >/dev/null 2>&1 && return 0
  fi
  return 1
}
