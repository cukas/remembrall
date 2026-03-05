#!/usr/bin/env bash
# SessionStart hook: injects handoff content directly on resume
# Session-aware: finds own session's handoff first, falls back to most recent

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

# For fresh session starts (not compact/clear): check bridge and nudge if missing
if [ "$SOURCE" != "compact" ] && [ "$SOURCE" != "clear" ]; then
  if ! remembrall_find_bridge "$CWD" >/dev/null 2>&1; then
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Remembrall: The context-monitor bridge is not set up. Run /setup-remembrall to enable real-time context tracking. Without it, Remembrall falls back to transcript-size estimation (less accurate). The safety net and auto-resume layers still work."
  }
}
EOF
  fi
  exit 0
fi

HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || exit 0

# No handoff directory — nothing to resume
if [ ! -d "$HANDOFF_DIR" ]; then
  exit 0
fi

HANDOFF_FILE=""

# Look for own session's handoff first, then fall back to most recent
if [ -n "$SESSION_ID" ] && [ -f "$HANDOFF_DIR/handoff-${SESSION_ID}.md" ]; then
  HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
else
  # Find most recent handoff-*.md using glob (no ls parsing)
  for f in "$HANDOFF_DIR"/handoff-*.md; do
    [ -f "$f" ] || continue
    if [ -z "$HANDOFF_FILE" ] || [ "$f" -nt "$HANDOFF_FILE" ]; then
      HANDOFF_FILE="$f"
    fi
  done
fi

# No handoff found
if [ -z "$HANDOFF_FILE" ] || [ ! -f "$HANDOFF_FILE" ]; then
  exit 0
fi

# Check age — skip stale handoffs (older than 24h)
FILE_AGE=$(remembrall_file_age "$HANDOFF_FILE")
if [ "$FILE_AGE" -gt 86400 ]; then
  rm -f "$HANDOFF_FILE"
  exit 0
fi

# Atomic claim: move before read to prevent TOCTOU race with concurrent sessions
CLAIMED_FILE="${HANDOFF_FILE}.claimed-$$"
mv "$HANDOFF_FILE" "$CLAIMED_FILE" 2>/dev/null || exit 0

# Read handoff content
CONTENT=$(cat "$CLAIMED_FILE")

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
    "additionalContext": "SESSION HANDOFF LOADED — Resume the work described below. Summarize to the user what was being worked on, what was completed, and what remains. Ask if they want to continue.\n\n${ESCAPED_CONTENT}${ESCAPED_NOTE}"
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
