#!/usr/bin/env bash
# Single-script handoff creator for remembrall.
# Handles: path computation, git state, patches, team copy, YAML frontmatter.
#
# Usage:
#   echo "MARKDOWN_CONTENT" | bash handoff-create.sh [OPTIONS]
#
# Options:
#   --cwd PATH          Working directory (default: pwd)
#   --session-id ID     Session ID (default: $CLAUDE_SESSION_ID or timestamp)
#   --status STATUS     Handoff status: in_progress|blocked|paused (default: in_progress)
#   --files FILE,...    Comma-separated list of files modified this session
#   --tasks "T1" "T2"  Remaining tasks (passed as separate args after --tasks)
#
# The markdown content is read from stdin.
# Outputs the handoff file path on stdout.
# Team copy path (if enabled) is printed to stderr prefixed with "team:".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib.sh"

remembrall_require_jq

# ─── Parse arguments ─────────────────────────────────────────────

CWD=""
SESSION_ID_ARG=""
STATUS="in_progress"
FILES_CSV=""
TASKS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)        CWD="$2"; shift 2 ;;
    --session-id) SESSION_ID_ARG="$2"; shift 2 ;;
    --status)     STATUS="$2"; shift 2 ;;
    --files)      FILES_CSV="$2"; shift 2 ;;
    --tasks)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        TASKS+=("$1")
        shift
      done
      ;;
    *) shift ;;
  esac
done

CWD="${CWD:-$(pwd)}"

# Session ID priority: explicit arg > env var > published by hook > timestamp fallback
PUBLISHED_SESSION=$(remembrall_read_session_id "$CWD" 2>/dev/null || echo "")
SESSION_ID="${SESSION_ID_ARG:-${CLAUDE_SESSION_ID:-${PUBLISHED_SESSION:-$(date +%s)}}}"

# ─── Read markdown content from stdin ────────────────────────────

CONTENT=""
if [ ! -t 0 ]; then
  CONTENT=$(cat)
fi

if [ -z "$CONTENT" ]; then
  echo "Error: no handoff content provided on stdin" >&2
  exit 1
fi

# ─── Compute handoff path ────────────────────────────────────────

HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || { echo "Error: could not compute handoff directory" >&2; exit 1; }
mkdir -p "$HANDOFF_DIR"
HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"

# ─── Git state ───────────────────────────────────────────────────

BRANCH=""
COMMIT=""
PATCH_FILE=""

if remembrall_git_enabled "$CWD"; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")
  COMMIT=$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "")

  # Build file list for targeted git diff (only session-touched files)
  IFS=',' read -ra FILE_ARRAY <<< "$FILES_CSV"
  DIFF_FILES=()
  for fp in "${FILE_ARRAY[@]}"; do
    fp="${fp#"${fp%%[![:space:]]*}"}"   # trim leading whitespace
    fp="${fp%"${fp##*[![:space:]]}"}"  # trim trailing whitespace
    [ -z "$fp" ] && continue
    if [ -f "$fp" ] || git -C "$CWD" ls-files --error-unmatch "$fp" >/dev/null 2>&1; then
      DIFF_FILES+=("$fp")
    fi
  done

  if [ "${#DIFF_FILES[@]}" -gt 0 ]; then
    PATCHES_DIR=$(remembrall_patches_dir "$CWD") || true
    if [ -n "$PATCHES_DIR" ]; then
      mkdir -p "$PATCHES_DIR"
      PATCH_FILE="$PATCHES_DIR/patch-${SESSION_ID}.diff"
      {
        git -C "$CWD" diff HEAD -- "${DIFF_FILES[@]}" 2>/dev/null
        git -C "$CWD" diff --staged -- "${DIFF_FILES[@]}" 2>/dev/null
      } > "$PATCH_FILE"
      if [ ! -s "$PATCH_FILE" ]; then
        rm -f "$PATCH_FILE"
        PATCH_FILE=""
      fi
    fi
  fi
fi

# ─── Build JSON frontmatter ────────────────────────────────────

# Files array
FILES_JSON="[]"
if [ -n "$FILES_CSV" ]; then
  FILES_JSON=$(printf '%s' "$FILES_CSV" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | jq -R . | jq -s '.')
fi

# Tasks array
TASKS_JSON="[]"
if [ "${#TASKS[@]}" -gt 0 ]; then
  TASKS_JSON=$(printf '%s\n' "${TASKS[@]}" | jq -R . | jq -s '.')
fi

# Previous session for chain linking
PREV_SESSION=$(remembrall_previous_session "$CWD" "$SESSION_ID" 2>/dev/null || echo "")

# Team mode
TEAM_MODE=$(remembrall_config "team_handoffs" "false")

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ─── Write handoff file ─────────────────────────────────────────

{
  echo '---'
  jq -n \
    --argjson format_version 2 \
    --arg created "$NOW" \
    --arg session_id "$SESSION_ID" \
    --arg previous_session "${PREV_SESSION:-}" \
    --arg project "$CWD" \
    --arg status "$STATUS" \
    --arg branch "$BRANCH" \
    --arg commit "$COMMIT" \
    --arg patch "$PATCH_FILE" \
    --argjson files "$FILES_JSON" \
    --argjson tasks "$TASKS_JSON" \
    --argjson team "${TEAM_MODE}" \
    '{
      format_version: $format_version,
      created: $created,
      session_id: $session_id,
      previous_session: $previous_session,
      project: $project,
      status: $status,
      branch: $branch,
      commit: $commit,
      patch: $patch,
      files: $files,
      tasks: $tasks,
      team: $team
    }'
  echo '---'
  echo ''
} > "$HANDOFF_FILE"

# Append the markdown content (via printf to prevent shell expansion)
printf '%s\n' "$CONTENT" >> "$HANDOFF_FILE"

# ─── Team copy ───────────────────────────────────────────────────

if remembrall_team_enabled; then
  TEAM_DIR=$(remembrall_team_handoff_dir "$CWD")
  mkdir -p "$TEAM_DIR"
  cp "$HANDOFF_FILE" "$TEAM_DIR/"
  echo "team:$TEAM_DIR/handoff-${SESSION_ID}.md" >&2
fi

# ─── Clean up nudge state + track handoff count ─────────────────

rm -f "/tmp/remembrall-nudges/$SESSION_ID"

# Increment session handoff counter
COUNTER_DIR="/tmp/remembrall-handoff-count"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="$COUNTER_DIR/$SESSION_ID"
PREV_COUNT=0
if [ -f "$COUNTER_FILE" ]; then
  PREV_COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  # Guard against non-numeric content
  [[ "$PREV_COUNT" =~ ^[0-9]+$ ]] || PREV_COUNT=0
fi
echo $((PREV_COUNT + 1)) > "$COUNTER_FILE"

# ─── Output ──────────────────────────────────────────────────────

echo "$HANDOFF_FILE"
