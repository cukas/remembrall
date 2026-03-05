#!/usr/bin/env bash
# Single-script handoff creator for remembrall.
# Handles: path computation, git state, patches, team copy, YAML frontmatter.
#
# Usage:
#   echo "MARKDOWN_CONTENT" | bash handoff-create.sh [OPTIONS]
#
# Options:
#   --cwd PATH          Working directory (default: pwd)
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
STATUS="in_progress"
FILES_CSV=""
TASKS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)    CWD="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --files)  FILES_CSV="$2"; shift 2 ;;
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
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"

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
    fp=$(echo "$fp" | xargs)  # trim whitespace
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

# ─── Build YAML frontmatter ─────────────────────────────────────

# Files list
FILES_YAML=""
IFS=',' read -ra FILE_ARRAY <<< "$FILES_CSV"
for fp in "${FILE_ARRAY[@]}"; do
  fp=$(echo "$fp" | xargs)
  [ -z "$fp" ] && continue
  FILES_YAML="${FILES_YAML}
  - ${fp}"
done

# Tasks list
TASKS_YAML=""
for task in "${TASKS[@]}"; do
  TASKS_YAML="${TASKS_YAML}
  - \"${task}\""
done

# Previous session for chain linking
PREV_SESSION=$(remembrall_previous_session "$CWD" "$SESSION_ID" 2>/dev/null || echo "")

# Team mode
TEAM_MODE=$(remembrall_config "team_handoffs" "false")

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ─── Write handoff file ─────────────────────────────────────────

cat > "$HANDOFF_FILE" << REMEMBRALL_EOF
---
created: "${NOW}"
session_id: "${SESSION_ID}"
previous_session: ${PREV_SESSION:-}
project: "${CWD}"
status: ${STATUS}
branch: "${BRANCH}"
commit: "${COMMIT}"
patch: "${PATCH_FILE}"
files:${FILES_YAML}
tasks:${TASKS_YAML}
team: ${TEAM_MODE}
---

REMEMBRALL_EOF

# Append the markdown content (via printf to prevent shell expansion)
printf '%s\n' "$CONTENT" >> "$HANDOFF_FILE"

# ─── Team copy ───────────────────────────────────────────────────

if remembrall_team_enabled; then
  TEAM_DIR=$(remembrall_team_handoff_dir "$CWD")
  mkdir -p "$TEAM_DIR"
  cp "$HANDOFF_FILE" "$TEAM_DIR/"
  echo "team:$TEAM_DIR/handoff-${SESSION_ID}.md" >&2
fi

# ─── Clean up nudge state ───────────────────────────────────────

rm -f "/tmp/remembrall-nudges/$SESSION_ID"

# ─── Output ──────────────────────────────────────────────────────

echo "$HANDOFF_FILE"
