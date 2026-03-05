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
  if ! grep -q "Type: Auto-generated" "$HANDOFF_FILE" 2>/dev/null; then
    echo "Handoff exists and was skill-generated. Preserving." >&2
    exit 0
  fi
fi

# Extract structured info from JSONL transcript
# Claude Code transcripts nest tool uses inside content arrays:
#   {"type":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"..."}}]}
FILE_PATHS=$(jq -r '
  select(.type == "assistant" and .content != null) |
  .content[]? |
  select(.type == "tool_use") |
  select(.name == "Read" or .name == "Write" or .name == "Edit" or .name == "MultiEdit") |
  .input.file_path // .input.path // empty
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
cat > "$HANDOFF_FILE" << 'REMEMBRALL_HANDOFF_END'
# Session Handoff

REMEMBRALL_HANDOFF_END

cat >> "$HANDOFF_FILE" << REMEMBRALL_HANDOFF_META
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
REMEMBRALL_HANDOFF_META

# Clean up stale handoffs (older than 24h) for this project
find "$HANDOFF_DIR" -name "handoff-*.md" -mmin +1440 -delete 2>/dev/null || true

# Signal to Claude that handoff was created
echo "Context is being compacted. Handoff saved to $HANDOFF_FILE — it will be loaded automatically on next session start." >&2
exit 0
