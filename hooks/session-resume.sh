#!/usr/bin/env bash
# SessionStart hook: injects handoff content directly on resume
# Only resumes own session's handoff — never picks up other sessions' handoffs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Exit if CWD not available
if [ -z "$CWD" ]; then
  exit 0
fi

# For fresh session starts (not compact/clear): just exit (bridge is optional now)
if [ "$SOURCE" != "compact" ] && [ "$SOURCE" != "clear" ]; then
  exit 0
fi

HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || exit 0

# No handoff directory — nothing to resume
if [ ! -d "$HANDOFF_DIR" ]; then
  exit 0
fi

# Only resume own session's handoff — use /replay for other sessions' handoffs
HANDOFF_FILE=""
if [ -n "$SESSION_ID" ] && [ -f "$HANDOFF_DIR/handoff-${SESSION_ID}.md" ]; then
  HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
fi

# Recency fallback: if own-session handoff not found, check for one created
# in the last 60s. Handles /handoff with timestamp ID (CLAUDE_SESSION_ID unavailable).
if [ -z "$HANDOFF_FILE" ]; then
  for f in "$HANDOFF_DIR"/handoff-*.md; do
    [ -f "$f" ] || continue
    local_age=$(remembrall_file_age "$f")
    if [ "$local_age" -lt 60 ]; then
      HANDOFF_FILE="$f"
      break
    fi
  done
fi

# No handoff found
if [ -z "$HANDOFF_FILE" ] || [ ! -f "$HANDOFF_FILE" ]; then
  exit 0
fi

# Check age — skip stale handoffs (older than configured retention)
RETENTION_HOURS=$(remembrall_retention_hours)
RETENTION_SECS=$((RETENTION_HOURS * 3600))
FILE_AGE=$(remembrall_file_age "$HANDOFF_FILE")
if [ "$FILE_AGE" -gt "$RETENTION_SECS" ]; then
  rm -f "$HANDOFF_FILE"
  exit 0
fi

# Atomic claim: move before read to prevent TOCTOU race with concurrent sessions
CLAIMED_FILE="${HANDOFF_FILE}.claimed-$$"
mv "$HANDOFF_FILE" "$CLAIMED_FILE" 2>/dev/null || exit 0

# Read handoff content
CONTENT=$(cat "$CLAIMED_FILE")

# Extract frontmatter metadata if present
PATCH_PATH=$(remembrall_frontmatter_get "$CLAIMED_FILE" "patch")
FM_BRANCH=$(remembrall_frontmatter_get "$CLAIMED_FILE" "branch")
FM_COMMIT=$(remembrall_frontmatter_get "$CLAIMED_FILE" "commit")

GIT_CONTEXT=""
if [ -n "$PATCH_PATH" ] && [ -f "$PATCH_PATH" ]; then
  PATCH_LINES=$(wc -l < "$PATCH_PATH" | tr -d ' ')
  GIT_RAW="GIT STATE: Branch was '${FM_BRANCH}', commit was '${FM_COMMIT}'. A patch file exists at ${PATCH_PATH} (${PATCH_LINES} lines) with the session's uncommitted changes. Use /replay to verify and restore."
  GIT_CONTEXT="\\n\\n$(remembrall_escape_json "$GIT_RAW")"
fi

# Count other handoff files (for awareness) — using glob, not ls
OTHER_COUNT=0
OTHER_FILES=""
for f in "$HANDOFF_DIR"/handoff-*.md; do
  [ -f "$f" ] || continue
  OTHER_COUNT=$((OTHER_COUNT + 1))
  OTHER_FILES="$OTHER_FILES $f"
done

OTHER_NOTE=""
if [ "$OTHER_COUNT" -gt 0 ]; then
  OTHER_NOTE=" NOTE: There are $OTHER_COUNT other handoff file(s) from other sessions:$OTHER_FILES"
fi

# Escape content for JSON embedding using jq (RFC 8259 compliant)
ESCAPED_CONTENT=$(remembrall_escape_json "$CONTENT")
ESCAPED_NOTE=$(remembrall_escape_json "$OTHER_NOTE")

# Output using canonical hookSpecificOutput format
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "SESSION HANDOFF LOADED — Resume the work described below. Summarize to the user what was being worked on, what was completed, and what remains. Ask if they want to continue.\n\n${ESCAPED_CONTENT}${GIT_CONTEXT}${ESCAPED_NOTE}"
  }
}
EOF

# Delete consumed handoff
rm -f "$CLAIMED_FILE"

# Clean up nudge temp files for this session
if [ -n "$SESSION_ID" ]; then
  rm -f "/tmp/remembrall-nudges/$SESSION_ID"
fi

exit 0
