#!/usr/bin/env bash
# SessionStart hook: injects handoff content directly on resume
# Session-aware: finds own session's handoff first, falls back to most recent

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Only inject on compaction resume or clear (not fresh startup)
if [ "$SOURCE" != "compact" ] && [ "$SOURCE" != "clear" ]; then
  exit 0
fi

# Exit if CWD not available
if [ -z "$CWD" ]; then
  exit 0
fi

# Cross-platform md5 hash of CWD
if command -v md5 >/dev/null 2>&1; then
  CWD_HASH=$(md5 -qs "$CWD")
elif command -v md5sum >/dev/null 2>&1; then
  CWD_HASH=$(printf '%s' "$CWD" | md5sum | cut -d' ' -f1)
else
  exit 0
fi

HANDOFF_DIR="$HOME/.remembrall/handoffs/$CWD_HASH"

# No handoff directory — nothing to resume
if [ ! -d "$HANDOFF_DIR" ]; then
  exit 0
fi

HANDOFF_FILE=""

# On compact: look for own session's handoff first
if [ "$SOURCE" = "compact" ] && [ -n "$SESSION_ID" ]; then
  if [ -f "$HANDOFF_DIR/handoff-${SESSION_ID}.md" ]; then
    HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
  fi
fi

# On clear (or if compact didn't find own file): look for own session first, then most recent
if [ -z "$HANDOFF_FILE" ]; then
  if [ -n "$SESSION_ID" ] && [ -f "$HANDOFF_DIR/handoff-${SESSION_ID}.md" ]; then
    HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
  else
    # Find most recent handoff-*.md
    HANDOFF_FILE=$(ls -t "$HANDOFF_DIR"/handoff-*.md 2>/dev/null | head -1)
  fi
fi

# No handoff found
if [ -z "$HANDOFF_FILE" ] || [ ! -f "$HANDOFF_FILE" ]; then
  exit 0
fi

# Check age — skip stale handoffs (older than 24h)
if [ "$(uname)" = "Darwin" ]; then
  FILE_AGE=$(( $(date +%s) - $(stat -f %m "$HANDOFF_FILE") ))
else
  FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$HANDOFF_FILE") ))
fi

if [ "$FILE_AGE" -gt 86400 ]; then
  rm -f "$HANDOFF_FILE"
  exit 0
fi

# Read handoff content
CONTENT=$(cat "$HANDOFF_FILE")

# Count other handoff files (for awareness)
OTHER_COUNT=$(ls "$HANDOFF_DIR"/handoff-*.md 2>/dev/null | grep -v "$(basename "$HANDOFF_FILE")" | wc -l | tr -d ' ')

OTHER_NOTE=""
if [ "$OTHER_COUNT" -gt 0 ]; then
  OTHER_FILES=$(ls -t "$HANDOFF_DIR"/handoff-*.md 2>/dev/null | grep -v "$(basename "$HANDOFF_FILE")")
  OTHER_NOTE=" NOTE: There are $OTHER_COUNT other handoff file(s) from other sessions: $OTHER_FILES"
fi

# Escape content for JSON embedding
escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

ESCAPED_CONTENT=$(escape_for_json "$CONTENT")
ESCAPED_NOTE=$(escape_for_json "$OTHER_NOTE")

# Output using canonical hookSpecificOutput format
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "SESSION HANDOFF LOADED — Resume the work described below. Summarize to the user what was being worked on, what was completed, and what remains. Ask if they want to continue.\n\n${ESCAPED_CONTENT}${ESCAPED_NOTE}"
  }
}
EOF

# Delete consumed handoff (single-use baton)
rm -f "$HANDOFF_FILE"

# Clean up nudge temp files for this session
if [ -n "$SESSION_ID" ]; then
  rm -f "/tmp/remembrall-nudges/$SESSION_ID"
fi

exit 0
