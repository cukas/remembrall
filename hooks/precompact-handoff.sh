#!/usr/bin/env bash
# PreCompact hook: safety-net handoff before context compaction
# Extracts structured info from transcript, writes per-session handoff file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Only act on automatic compaction (context pressure)
if [ "$TRIGGER" != "precompact_auto" ]; then
  exit 0
fi

# Ensure transcript exists
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Calibrate: record transcript size for future context estimation
remembrall_calibrate "$TRANSCRIPT_PATH"

# Exit if CWD not available
if [ -z "$CWD" ]; then
  exit 0
fi

HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || exit 0
HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
mkdir -p "$HANDOFF_DIR"

# Skip if a handoff for this session already exists and is < 5 min old
# Also skip if the existing handoff was skill-generated (higher quality than auto)
if [ -f "$HANDOFF_FILE" ]; then
  FILE_AGE=$(remembrall_file_age "$HANDOFF_FILE")
  if [ "$FILE_AGE" -lt 300 ]; then
    echo "Handoff already exists and is recent (${FILE_AGE}s old). Skipping." >&2
    exit 0
  fi
  # Never overwrite a skill-generated handoff — it is higher quality
  if ! grep -q '"type".*"auto-generated"' "$HANDOFF_FILE" 2>/dev/null && \
     ! grep -q "type: auto-generated" "$HANDOFF_FILE" 2>/dev/null && \
     ! grep -q "Type: Auto-generated" "$HANDOFF_FILE" 2>/dev/null; then
    echo "Handoff exists and was skill-generated. Preserving." >&2
    exit 0
  fi
fi

# Extract all structured info from JSONL transcript in a SINGLE jq pass.
# Claude Code transcripts nest tool uses inside content arrays:
#   {"type":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"..."}}]}
#
# Output: 5 sections separated by a NUL-delimited marker line.
EXTRACTED=$(jq -r '
  # file paths from Read/Write/Edit/MultiEdit tool uses
  (
    select(.type == "assistant" and .content != null) |
    .content[]? |
    select(.type == "tool_use") |
    select(.name == "Read" or .name == "Write" or .name == "Edit" or .name == "MultiEdit") |
    .input.file_path // .input.path // empty |
    "FILE:" + .
  ),
  # errors from tool results
  (
    select(.type == "user") |
    .content[]? |
    select(.type == "tool_result") |
    .content // empty | tostring |
    select(test("error|Error|fail|FAIL|exception|Exception|panic")) |
    "ERROR:" + .[0:300]
  ),
  # git operations from Bash tool calls
  (
    select(.type == "assistant" and .content != null) |
    .content[]? |
    select(.type == "tool_use" and .name == "Bash") |
    .input.command // empty |
    select(startswith("git ") or contains(" git ")) |
    "GIT:" + .
  ),
  # task state from TaskCreate/TaskUpdate
  (
    select(.type == "assistant" and .content != null) |
    .content[]? |
    select(.type == "tool_use") |
    select(.name == "TaskCreate" or .name == "TaskUpdate") |
    "TASK:" + (.input | tostring)
  ),
  empty
' "$TRANSCRIPT_PATH" 2>/dev/null)

# Split extracted data by prefix
FILE_PATHS=$(echo "$EXTRACTED" | grep '^FILE:' | sed 's/^FILE://' | sort -u | head -50)
ERRORS_FOUND=$(echo "$EXTRACTED" | grep '^ERROR:' | sed 's/^ERROR://' | tail -10 | sort -u | tail -5)
GIT_OPS=$(echo "$EXTRACTED" | grep '^GIT:' | sed 's/^GIT://' | tail -20)
TASK_STATE=$(echo "$EXTRACTED" | grep '^TASK:' | sed 's/^TASK://' | tail -30)

# Extract the user's first substantive message as the session goal
USER_GOAL=$(jq -r '
  select(.type == "human") |
  .content // "" |
  if type == "array" then
    map(select(.type == "text") | .text) | join(" ")
  else
    tostring
  end |
  select(length > 10) |
  .[0:500]
' "$TRANSCRIPT_PATH" 2>/dev/null | head -1)

# ─── Git state capture ────────────────────────────────────────────
BRANCH=""
COMMIT=""
PATCH_FILE=""
if remembrall_git_enabled "$CWD"; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")
  COMMIT=$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "")

  # Build file list for targeted git diff (only session-touched files)
  DIFF_FILES=()
  while IFS= read -r fp; do
    [ -z "$fp" ] && continue
    if [ -f "$fp" ] || git -C "$CWD" ls-files --error-unmatch "$fp" >/dev/null 2>&1; then
      DIFF_FILES+=("$fp")
    fi
  done <<< "$FILE_PATHS"

  if [ "${#DIFF_FILES[@]}" -gt 0 ]; then
    PATCHES_DIR=$(remembrall_patches_dir "$CWD") || true
    if [ -n "$PATCHES_DIR" ]; then
      mkdir -p "$PATCHES_DIR"
      PATCH_FILE="$PATCHES_DIR/patch-${SESSION_ID}.diff"
      git -C "$CWD" diff HEAD -- "${DIFF_FILES[@]}" 2>/dev/null > "$PATCH_FILE"
      [ ! -s "$PATCH_FILE" ] && { rm -f "$PATCH_FILE"; PATCH_FILE=""; }
    fi
  fi
fi

# Build JSON files array
FILES_JSON=$(printf '%s\n' "$FILE_PATHS" | grep -v '^$' | head -50 | jq -R . | jq -s '.')

# Determine team mode
TEAM_MODE=$(remembrall_config "team_handoffs" "false")

# Find previous session for chain linking
PREV_SESSION=$(remembrall_previous_session "$CWD" "$SESSION_ID" 2>/dev/null || echo "")

# Capture timestamp once for consistency
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Write JSON frontmatter + header
{
  echo '---'
  jq -n \
    --arg created "$NOW" \
    --arg session_id "$SESSION_ID" \
    --arg previous_session "${PREV_SESSION:-}" \
    --arg project "$CWD" \
    --arg status "interrupted" \
    --arg type "auto-generated" \
    --arg branch "$BRANCH" \
    --arg commit "$COMMIT" \
    --arg patch "$PATCH_FILE" \
    --argjson files "$FILES_JSON" \
    --argjson team "${TEAM_MODE}" \
    '{
      created: $created,
      session_id: $session_id,
      previous_session: $previous_session,
      project: $project,
      status: $status,
      type: $type,
      branch: $branch,
      commit: $commit,
      patch: $patch,
      files: $files,
      team: $team
    }'
  echo '---'
} > "$HANDOFF_FILE"

# Append header
cat >> "$HANDOFF_FILE" << REMEMBRALL_HEADER

# Session Handoff

**Created:** ${NOW}
**Session ID:** ${SESSION_ID}
**Project:** ${CWD}
**Reason:** Auto-compaction (context window pressure)
**Type:** Auto-generated — verify before continuing

---

## IMPORTANT — Read This First

This handoff was auto-generated because the previous session ran out of context.
Resume the work described below. Check the task list (/tasks) for pending items.

---

REMEMBRALL_HEADER

# Write content sections safely — untrusted content via printf to prevent shell expansion
{
  if [ -n "$USER_GOAL" ]; then
    echo '## Session Goal'
    echo ''
    printf '%s\n' "$USER_GOAL"
    echo ''
  fi
  echo '## Files Touched This Session'
  echo ''
  echo '```'
  printf '%s\n' "$FILE_PATHS"
  echo '```'
  echo ''
  echo '## Errors Encountered'
  echo ''
  echo '```'
  printf '%s\n' "$ERRORS_FOUND"
  echo '```'
  echo ''
  echo '## Git Operations'
  echo ''
  echo '```'
  printf '%s\n' "$GIT_OPS"
  echo '```'
  echo ''
  echo '## Task State'
  echo ''
  echo '```'
  printf '%s\n' "$TASK_STATE"
  echo '```'
} >> "$HANDOFF_FILE"

# Copy to team directory if enabled
if remembrall_team_enabled; then
  TEAM_DIR=$(remembrall_team_handoff_dir "$CWD")
  mkdir -p "$TEAM_DIR"
  cp "$HANDOFF_FILE" "$TEAM_DIR/"
fi

# Clean up stale handoffs based on configurable retention (default: 72h)
RETENTION_HOURS=$(remembrall_retention_hours)
RETENTION_MINS=$((RETENTION_HOURS * 60))
if [ "$RETENTION_MINS" -gt 0 ] 2>/dev/null; then
  find "$HANDOFF_DIR" -name "handoff-*.md" -mmin +"$RETENTION_MINS" -delete 2>/dev/null || true
fi

# Signal to Claude that handoff was created
echo "Context is being compacted. Handoff saved to $HANDOFF_FILE — it will be loaded automatically on next session start." >&2
exit 0
