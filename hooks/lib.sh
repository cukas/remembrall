#!/usr/bin/env bash
# Shared helpers for remembrall hooks

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
