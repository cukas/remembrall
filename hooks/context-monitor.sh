#!/usr/bin/env bash
# UserPromptSubmit hook: monitors actual context % via status-line bridge
# Triggers structured /handoff at 30% remaining, urgent at 20%

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

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

# Read context % from bridge file (written by status line)
CTX_FILE="/tmp/claude-context-pct/$CWD_HASH"
if [ ! -f "$CTX_FILE" ]; then
  exit 0
fi

REMAINING=$(cat "$CTX_FILE" 2>/dev/null)
if [ -z "$REMAINING" ]; then
  exit 0
fi

# Nudge tracking — don't spam every prompt
NUDGE_DIR="/tmp/remembrall-nudges"
mkdir -p "$NUDGE_DIR"
NUDGE_FILE="$NUDGE_DIR/$SESSION_ID"

# Check if we already nudged at this level
LAST_NUDGE=""
if [ -f "$NUDGE_FILE" ]; then
  LAST_NUDGE=$(cat "$NUDGE_FILE")
fi

# Reset nudge state if context recovered (post-compaction: remaining > 80%)
if (( $(echo "$REMAINING > 80" | bc -l 2>/dev/null || echo 0) )); then
  rm -f "$NUDGE_FILE"
  exit 0
fi

# >30% remaining — do nothing
if (( $(echo "$REMAINING > 30" | bc -l 2>/dev/null || echo 0) )); then
  exit 0
fi

# Determine handoff directory for this project
HANDOFF_DIR="$HOME/.remembrall/handoffs/$CWD_HASH"

# <=20% — URGENT (only if we haven't already sent urgent)
if (( $(echo "$REMAINING <= 20" | bc -l 2>/dev/null || echo 0) )); then
  if [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "urgent" > "$NUDGE_FILE"
  cat << EOF
{
  "additionalContext": "CONTEXT MONITOR URGENT (${REMAINING}% remaining): STOP all work immediately. Auto-run /handoff NOW — write to handoff-${SESSION_ID}.md in ${HANDOFF_DIR}/. Then tell the user to /clear and /resume. Do NOT start any new tool calls."
}
EOF
  exit 0
fi

# <=30% — first nudge (only if we haven't already sent warning)
if [ "$LAST_NUDGE" = "warning" ] || [ "$LAST_NUDGE" = "urgent" ]; then
  exit 0
fi
echo "warning" > "$NUDGE_FILE"
cat << EOF
{
  "additionalContext": "CONTEXT MONITOR (${REMAINING}% remaining): Context is getting low. Auto-run /handoff NOW to preserve your work — write to handoff-${SESSION_ID}.md in ${HANDOFF_DIR}/. After writing the handoff, tell the user to /clear and /resume to continue with full context."
}
EOF
exit 0
