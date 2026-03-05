#!/usr/bin/env bash
# PreCompact hook: safety-net handoff before context compaction
# Extracts structured info from transcript, writes per-session handoff file

set -e

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
HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
mkdir -p "$HANDOFF_DIR"

# Skip if a handoff for this session already exists and is < 5 min old
if [ -f "$HANDOFF_FILE" ]; then
  if [ "$(uname)" = "Darwin" ]; then
    FILE_AGE=$(( $(date +%s) - $(stat -f %m "$HANDOFF_FILE") ))
  else
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$HANDOFF_FILE") ))
  fi
  if [ "$FILE_AGE" -lt 300 ]; then
    echo "Handoff already exists and is recent (${FILE_AGE}s old). Skipping." >&2
    exit 0
  fi
fi

# Extract structured info from JSONL transcript
# File paths from tool uses
FILE_PATHS=$(jq -r '
  select(.tool_use != null) |
  .tool_use |
  if .name == "Read" or .name == "Write" or .name == "Edit" then
    .input.file_path // .input.path // empty
  else empty end
' "$TRANSCRIPT_PATH" 2>/dev/null | sort -u | head -50)

# Last ~80 conversation exchanges (user + assistant messages)
RECENT_EXCHANGES=$(jq -r '
  select(.type == "human" or .type == "assistant") |
  if .type == "human" then
    "USER: " + (.content // "[tool result]" | tostring | .[0:500])
  else
    "ASSISTANT: " + (.content // "[tool use]" | tostring | .[0:500])
  end
' "$TRANSCRIPT_PATH" 2>/dev/null | tail -160)

# Build handoff document
cat > "$HANDOFF_FILE" << HANDOFF_EOF
# Session Handoff

**Created:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Session ID:** $SESSION_ID
**Project:** $CWD
**Reason:** Auto-compaction (context window pressure)
**Type:** Auto-generated — verify before continuing

---

## IMPORTANT — Read This First

This handoff was auto-generated because the previous session ran out of context.
Resume the work described below. Check the task list (/tasks) for pending items.

---

## Files Touched This Session

\`\`\`
$FILE_PATHS
\`\`\`

## Recent Conversation (last ~80 exchanges)

\`\`\`
$RECENT_EXCHANGES
\`\`\`
HANDOFF_EOF

# Clean up stale handoffs (older than 24h) for this project
find "$HANDOFF_DIR" -name "handoff-*.md" -mmin +1440 -delete 2>/dev/null || true

# Signal to Claude that handoff was created
echo "Context is being compacted. Handoff saved to $HANDOFF_FILE — it will be loaded automatically on next session start." >&2
exit 0
