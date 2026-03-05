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

# Cross-platform file age in seconds
remembrall_file_age() {
  local file="$1"
  if [ "$(uname)" = "Darwin" ]; then
    echo $(( $(date +%s) - $(stat -f %m "$file") ))
  else
    echo $(( $(date +%s) - $(stat -c %Y "$file") ))
  fi
}

# JSON-safe string escaping using jq (RFC 8259 compliant)
remembrall_escape_json() {
  printf '%s' "$1" | jq -Rs . | sed 's/^"//;s/"$//'
}

# Validate that a value is a number (integer or decimal)
remembrall_validate_number() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}
