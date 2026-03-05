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
# Self-calibrating: after the first compaction, remembrall records the actual
# transcript size at which context ran out. Subsequent sessions use the
# calibrated value instead of the default, improving accuracy over time.
#
# Uses configurable max_transcript_kb (default: 256) as initial seed.
# After 1-2 compaction events the calibrated value takes over automatically.
remembrall_estimate_context() {
  local transcript_path="$1"
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 1
  fi

  local size
  size=$(wc -c < "$transcript_path" 2>/dev/null) || return 1
  size=$(echo "$size" | tr -d ' ')

  # Use calibrated max if available, otherwise fall back to config/default
  local max_bytes
  max_bytes=$(remembrall_calibrated_max)
  if [ -z "$max_bytes" ] || [ "$max_bytes" -eq 0 ] 2>/dev/null; then
    local max_kb
    max_kb=$(remembrall_config "max_transcript_kb" "256")
    if ! [[ "$max_kb" =~ ^[0-9]+$ ]]; then
      max_kb=256
    fi
    max_bytes=$((max_kb * 1024))
  fi

  # Too small to estimate reliably (<40% of expected max)
  if [ "$size" -lt $((max_bytes * 40 / 100)) ]; then
    return 1
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

# ─── Calibration ──────────────────────────────────────────────────

# Record transcript size at compaction for future estimation.
# Called by precompact-handoff.sh when context pressure triggers compaction.
# Stores last 5 measurements and uses the average as the calibrated max.
remembrall_calibrate() {
  local transcript_path="$1"
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 1
  fi

  local size
  size=$(wc -c < "$transcript_path" 2>/dev/null) || return 1
  size=$(echo "$size" | tr -d ' ')

  # Ignore tiny transcripts (likely not real compaction)
  if [ "$size" -lt 50000 ]; then
    return 0
  fi

  local cal_file="$HOME/.remembrall/calibration.json"
  mkdir -p "$HOME/.remembrall"

  if [ ! -f "$cal_file" ]; then
    echo '{"samples":[]}' > "$cal_file"
  fi

  # Append sample (keep last 5)
  local tmp
  tmp=$(mktemp "${cal_file}.XXXXXX")
  jq --argjson s "$size" '
    .samples += [$s] |
    .samples = .samples[-5:] |
    .updated = now
  ' "$cal_file" > "$tmp" 2>/dev/null && mv "$tmp" "$cal_file" || rm -f "$tmp"
}

# Get calibrated max transcript size in bytes (average of stored samples).
# Returns empty string if no calibration data exists.
remembrall_calibrated_max() {
  local cal_file="$HOME/.remembrall/calibration.json"
  if [ ! -f "$cal_file" ]; then
    echo ""
    return
  fi

  local avg
  avg=$(jq -r '
    if (.samples | length) > 0 then
      ((.samples | add) / (.samples | length)) | floor
    else
      empty
    end
  ' "$cal_file" 2>/dev/null)

  echo "$avg"
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

# Parse frontmatter value from a handoff file.
# Supports both JSON frontmatter (new format) and YAML frontmatter (legacy).
# Usage: remembrall_frontmatter_get "file.md" "key"
remembrall_frontmatter_get() {
  local file="$1"
  local key="$2"

  # Extract content between the first pair of --- markers only
  local block
  block=$(awk '/^---$/ { if (++c == 2) exit; next } c == 1 { print }' "$file" 2>/dev/null) || return

  # Try JSON parse first (new format)
  local val
  val=$(printf '%s' "$block" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    echo "$val"
    return
  fi

  # Legacy YAML fallback — simple key: value lines only
  printf '%s\n' "$block" | grep "^${key}:" | sed "s/^${key}: *//" | head -1
}
