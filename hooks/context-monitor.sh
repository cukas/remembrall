#!/usr/bin/env bash
# UserPromptSubmit hook: monitors actual context % via status-line bridge
# Triggers journal checkpoint at 60%, warning at 30%, urgent at 20%

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# Exit if CWD not available
if [ -z "$CWD" ]; then
  exit 0
fi

# Find bridge file (checks CWD + parent dirs), fall back to transcript size
ESTIMATED=""
REMAINING=""
CTX_FILE=$(remembrall_find_bridge "$CWD") 2>/dev/null
if [ -n "$CTX_FILE" ]; then
  REMAINING=$(cat "$CTX_FILE" 2>/dev/null)
  if ! remembrall_validate_number "$REMAINING"; then
    REMAINING=""
  fi
fi

# Fallback: estimate from transcript size when bridge is missing or empty
if [ -z "$REMAINING" ]; then
  REMAINING=$(remembrall_estimate_context "$TRANSCRIPT_PATH") || exit 0
  ESTIMATED=" (estimated from transcript size)"
fi

# Nudge tracking — don't spam every prompt
NUDGE_DIR="/tmp/remembrall-nudges"
mkdir -p "$NUDGE_DIR"
NUDGE_FILE="$NUDGE_DIR/$SESSION_ID"

LAST_NUDGE=""
if [ -f "$NUDGE_FILE" ]; then
  LAST_NUDGE=$(cat "$NUDGE_FILE")
fi

# Reset nudge state if context recovered (post-compaction: remaining > 80%)
if remembrall_gt "$REMAINING" 80; then
  rm -f "$NUDGE_FILE"
  exit 0
fi

# >60% remaining — do nothing
if remembrall_gt "$REMAINING" 60; then
  exit 0
fi

# <=60% and >30% — JOURNAL CHECKPOINT (nudge once to update running handoff)
if remembrall_gt "$REMAINING" 30; then
  if [ "$LAST_NUDGE" = "journal" ] || [ "$LAST_NUDGE" = "warning" ] || [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "journal" > "$NUDGE_FILE"
  GAUGE=$(remembrall_gauge "$REMAINING")
  cat << EOF
{
  "additionalContext": "${GAUGE} Context checkpoint (${REMAINING}% remaining${ESTIMATED}): Good time to run /handoff and save a progress snapshot. This is informational — continue working after saving."
}
EOF
  exit 0
fi

# Handoff directory (escaped for safe JSON embedding)
HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || exit 0
ESCAPED_DIR=$(remembrall_escape_json "$HANDOFF_DIR")

# <=20% — URGENT (only suppress if urgent already sent; allows escalation from warning)
if remembrall_le "$REMAINING" 20; then
  if [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "urgent" > "$NUDGE_FILE"
  GAUGE=$(remembrall_gauge "$REMAINING")
  cat << EOF
{
  "additionalContext": "${GAUGE} Context critically low (${REMAINING}% remaining${ESTIMATED}): Please run /handoff to save progress to handoff-${SESSION_ID}.md in ${ESCAPED_DIR}/, then suggest the user /clear and /replay to continue with full context."
}
EOF
  exit 0
fi

# <=30% — WARNING (only suppress if warning already sent)
if [ "$LAST_NUDGE" = "warning" ]; then
  exit 0
fi
echo "warning" > "$NUDGE_FILE"
GAUGE=$(remembrall_gauge "$REMAINING")
cat << EOF
{
  "additionalContext": "${GAUGE} Context getting low (${REMAINING}% remaining${ESTIMATED}): Please run /handoff to preserve progress to handoff-${SESSION_ID}.md in ${ESCAPED_DIR}/. After saving, suggest the user /clear and /replay to continue with full context."
}
EOF
exit 0
