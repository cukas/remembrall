#!/usr/bin/env bash
# sourced by lib.sh
# lib-handoff.sh — Handoff, patches, frontmatter, session state, Pensieve dirs

# Find bridge file for a session.
# Bridge is keyed by session_id only (not CWD) because the status line's
# workspace.current_dir can differ from the hook's CWD.
# Without session_id: reads the published session_id for the CWD (diagnostics).
# Bridge is invalidated on compact/clear by session-resume.sh.
remembrall_find_bridge() {
  local cwd="$1"
  local session_id="$2"
  local ctx_dir="/tmp/claude-context-pct"

  # Without session_id: try published session_id for this CWD (diagnostic use)
  if [ -z "$session_id" ]; then
    session_id=$(remembrall_read_session_id "$cwd" 2>/dev/null)
  fi

  [ -z "$session_id" ] && return 1

  local f="$ctx_dir/$session_id"
  if [ -f "$f" ]; then
    echo "$f"
    return 0
  fi

  return 1
}

# Compute handoff directory for a given CWD
# Uses project basename + short hash suffix for readability + collision safety
# e.g., ~/.remembrall/handoffs/ai-buddies-8f9a0596/
# Falls back to legacy full-hash format (~/.remembrall/handoffs/{md5}) for v2.x compat
remembrall_handoff_dir() {
  local cwd="$1"
  remembrall_project_storage_dir "$HOME/.remembrall/handoffs" "$cwd"
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
# Falls back to legacy full-hash format for v2.x compat
remembrall_patches_dir() {
  local cwd="$1"
  remembrall_project_storage_dir "$HOME/.remembrall/patches" "$cwd"
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

# Compute team handoff directory — same as personal (all centralized)
# Team handoffs are distinguished by metadata, not location
remembrall_team_handoff_dir() {
  local cwd="$1"
  remembrall_handoff_dir "$cwd"
}

# ─── Autonomous Mode ─────────────────────────────────────────────

# Autonomous mode marker — set by skills that run unattended (ralph loop,
# swarm agents, etc.) so Remembrall uses the automatic path (handoff +
# compaction) instead of plan mode (which needs a human click).
#
# Any skill can signal autonomous mode:
#   remembrall_set_autonomous "$SESSION_ID" "ralph-loop"
#
# The marker is checked by context-monitor.sh at <=30% to decide:
#   autonomous → write /handoff (automatic, no human needed)
#   attended   → EnterPlanMode (human clicks "clear context")

REMEMBRALL_AUTONOMOUS_DIR="/tmp/remembrall-autonomous"

remembrall_set_autonomous() {
  local session_id="$1"
  local skill_name="${2:-unknown}"
  [ -z "$session_id" ] && return
  mkdir -p "$REMEMBRALL_AUTONOMOUS_DIR" 2>/dev/null
  printf '%s' "$skill_name" > "$REMEMBRALL_AUTONOMOUS_DIR/$session_id" 2>/dev/null
}

remembrall_clear_autonomous() {
  local session_id="$1"
  [ -z "$session_id" ] && return
  rm -f "$REMEMBRALL_AUTONOMOUS_DIR/$session_id" 2>/dev/null
}

# Returns 0 (true) if autonomous, 1 (false) if attended.
# Outputs the skill name on stdout if autonomous.
remembrall_is_autonomous() {
  local session_id="$1"
  [ -z "$session_id" ] && return 1
  local f="$REMEMBRALL_AUTONOMOUS_DIR/$session_id"
  if [ -f "$f" ]; then
    cat "$f" 2>/dev/null
    return 0
  fi
  return 1
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

# ─── Pensieve Directory ──────────────────────────────────────────

# Compute Pensieve persistence directory for a given CWD
# Mirrors remembrall_handoff_dir() pattern for consistency
# e.g., ~/.remembrall/pensieve/ai-buddies-8f9a0596/
remembrall_pensieve_dir() {
  local cwd="$1"
  remembrall_project_storage_dir "$HOME/.remembrall/pensieve" "$cwd"
}

# Pensieve temp directory for raw JSONL tracking data
# e.g., /tmp/remembrall-pensieve/
remembrall_pensieve_tmp() {
  echo "/tmp/remembrall-pensieve"
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
  # Use `|| true` to ensure non-zero exit from grep (no match) doesn't propagate
  # when caller has set -euo pipefail
  printf '%s\n' "$block" | grep "^${key}:" | sed "s/^${key}: *//" | head -1 || true
}

remembrall_frontmatter_get_head() {
  local file="$1"
  local key="$2"
  local max_lines="${3:-40}"

  local block
  block=$(head -n "$max_lines" "$file" 2>/dev/null | awk '/^---$/ { if (++c == 2) exit; next } c == 1 { print }') || return 1
  [ -n "$block" ] || return 1

  printf '%s' "$block" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
}

remembrall_latest_handoff_file() {
  local dir="$1"
  [ -d "$dir" ] || return 1

  local newest=""
  local f
  for f in "$dir"/handoff-*.md; do
    [ -f "$f" ] || continue
    case "$f" in
      *.consumed.md) continue ;;
    esac
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
      newest="$f"
    fi
  done

  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

remembrall_paths_related() {
  local left right
  left=$(remembrall_normalize_dir "$1") || return 1
  right=$(remembrall_normalize_dir "$2") || return 1

  [ "$left" = "$right" ] && return 0
  case "$right" in
    "$left"/*) return 0 ;;
  esac
  case "$left" in
    "$right"/*) return 0 ;;
  esac
  return 1
}

# Replay fallback: when the hashed directory lookup misses, scan handoff
# directories by reading only the newest handoff header in each directory.
# Outputs matching handoff directories, newest first.
remembrall_replay_fallback_dirs() {
  local cwd="$1"
  local search_root
  search_root=$(remembrall_normalize_dir "$cwd") || return 1
  local base="$HOME/.remembrall/handoffs"
  [ -d "$base" ] || return 1

  local dir newest project normalized_project mtime
  for dir in "$base"/*; do
    [ -d "$dir" ] || continue

    newest=$(remembrall_latest_handoff_file "$dir" 2>/dev/null) || continue
    project=$(remembrall_frontmatter_get_head "$newest" "project" 40 2>/dev/null) || continue
    [ -n "$project" ] || continue
    normalized_project=$(remembrall_normalize_dir "$project" 2>/dev/null || printf '%s' "$project")

    remembrall_paths_related "$search_root" "$normalized_project" || continue

    if [ "$(uname)" = "Darwin" ]; then
      mtime=$(stat -f %m "$newest" 2>/dev/null || echo 0)
    else
      mtime=$(stat -c %Y "$newest" 2>/dev/null || echo 0)
    fi
    printf '%s\t%s\n' "$mtime" "$dir"
  done | sort -rn | cut -f2
}
