#!/usr/bin/env bash
# Shared helpers for remembrall hooks

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

# Find bridge file by checking CWD and all parent directories.
# The status line may report a parent dir (e.g. ~) while hooks see the
# full project path. Walking up ensures we find the match.
remembrall_find_bridge() {
  local dir="$1"
  local ctx_dir="/tmp/claude-context-pct"

  while [ "$dir" != "/" ]; do
    local hash
    hash=$(remembrall_md5 "$dir") || return 1
    if [ -f "$ctx_dir/$hash" ]; then
      echo "$ctx_dir/$hash"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# Compute handoff directory for a given CWD
remembrall_handoff_dir() {
  local cwd="$1"
  local hash
  hash=$(remembrall_md5 "$cwd") || return 1
  echo "$HOME/.remembrall/handoffs/$hash"
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

# Estimate context remaining from transcript file size.
# Used as a fallback when the status-line bridge is not configured.
# Returns estimated remaining % on stdout, or exits 1 if no estimate possible.
#
# Uses configurable max_transcript_kb (default: 256) to scale thresholds.
# The default assumes ~256KB of JSONL transcript ≈ a full context window.
# Adjust via: remembrall_config_set "max_transcript_kb" "512"
# Conservative: triggers earlier rather than later.
remembrall_estimate_context() {
  local transcript_path="$1"
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 1
  fi

  local size
  size=$(wc -c < "$transcript_path" 2>/dev/null) || return 1
  size=$(echo "$size" | tr -d ' ')

  local max_kb
  max_kb=$(remembrall_config "max_transcript_kb" "256")
  if ! [[ "$max_kb" =~ ^[0-9]+$ ]]; then
    max_kb=256
  fi
  local max_bytes=$((max_kb * 1024))

  # Estimate remaining % as inverse of transcript fill ratio
  # size/max_bytes = used fraction → remaining = 100 - used%
  if [ "$size" -lt $((max_bytes * 40 / 100)) ]; then
    return 1  # Too small to estimate reliably (<40% of expected max)
  fi

  local used_pct=$((size * 100 / max_bytes))
  if [ "$used_pct" -gt 100 ]; then
    used_pct=100
  fi
  local remaining=$((100 - used_pct))

  # Floor at 5% — never report 0
  if [ "$remaining" -lt 5 ]; then
    remaining=5
  fi

  echo "$remaining"
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
  value=$(jq -r --arg k "$key" 'if has($k) then .[$k] | tostring else empty end' "$config_file" 2>/dev/null)

  if [ -z "$value" ]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# Write a config value to ~/.remembrall/config.json
# Creates the file and directory if they don't exist
remembrall_config_set() {
  local key="$1"
  local value="$2"
  local config_file="$HOME/.remembrall/config.json"

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

# ─── Git Integration ──────────────────────────────────────────────

# Check if git integration is enabled AND cwd is a git repo
# Supports both boolean true and string "true" for backwards compatibility
remembrall_git_enabled() {
  local cwd="$1"
  local val
  val=$(remembrall_config "git_integration" "false")
  [ "$val" = "true" ] || return 1
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
}

# Compute patches directory for a project
remembrall_patches_dir() {
  local cwd="$1"
  local hash
  hash=$(remembrall_md5 "$cwd") || return 1
  echo "$HOME/.remembrall/patches/$hash"
}

# ─── Team Handoffs ────────────────────────────────────────────────

# Check if team handoffs are enabled
# Supports both boolean true and string "true" for backwards compatibility
remembrall_team_enabled() {
  local val
  val=$(remembrall_config "team_handoffs" "false")
  [ "$val" = "true" ]
}

# Get handoff retention in hours (default: 72)
remembrall_retention_hours() {
  local val
  val=$(remembrall_config "retention_hours" "72")
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "$val"
  else
    echo "72"
  fi
}

# Compute team handoff directory (project-local)
remembrall_team_handoff_dir() {
  local cwd="$1"
  echo "$cwd/.remembrall/handoffs"
}

# ─── Handoff Chains ──────────────────────────────────────────────

# Find the most recent handoff session_id for chaining.
# Returns the session_id from the newest handoff file, or empty if none.
remembrall_previous_session() {
  local cwd="$1"
  local current_session="$2"
  local handoff_dir
  handoff_dir=$(remembrall_handoff_dir "$cwd") || return 1

  [ -d "$handoff_dir" ] || return 1

  local newest="" newest_file=""
  for f in "$handoff_dir"/handoff-*.md; do
    [ -f "$f" ] || continue
    # Skip our own session's handoff
    local basename
    basename=$(basename "$f" .md)
    local sid="${basename#handoff-}"
    [ "$sid" = "$current_session" ] && continue
    if [ -z "$newest_file" ] || [ "$f" -nt "$newest_file" ]; then
      newest_file="$f"
      newest="$sid"
    fi
  done

  # Also check claimed files (in-progress resumes)
  for f in "$handoff_dir"/handoff-*.md.claimed-*; do
    [ -f "$f" ] || continue
    local basename
    basename=$(basename "$f")
    # Extract session id: handoff-SESSID.md.claimed-PID
    local sid="${basename#handoff-}"
    sid="${sid%.md.claimed-*}"
    [ "$sid" = "$current_session" ] && continue
    if [ -z "$newest_file" ] || [ "$f" -nt "$newest_file" ]; then
      newest_file="$f"
      newest="$sid"
    fi
  done

  echo "$newest"
}

# ─── Frontmatter ──────────────────────────────────────────────────

# Parse YAML frontmatter value from a handoff file (scalar values only).
# Does NOT work for multi-line YAML values like lists (files:, tasks:).
# Usage: remembrall_frontmatter_get "file.md" "key"
remembrall_frontmatter_get() {
  local file="$1"
  local key="$2"
  sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | grep "^${key}:" | sed "s/^${key}: *//"
}
