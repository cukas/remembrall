#!/usr/bin/env bash
# UserPromptSubmit hook: monitors actual context % via status-line bridge
# Triggers structured /handoff at 30% remaining, urgent at 20%

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
if (( $(echo "$REMAINING > 80" | bc -l 2>/dev/null || echo 0) )); then
  rm -f "$NUDGE_FILE"
  exit 0
fi

# >30% remaining — do nothing
if (( $(echo "$REMAINING > 30" | bc -l 2>/dev/null || echo 0) )); then
  exit 0
fi

# Handoff directory (escaped for safe JSON embedding)
HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || exit 0
ESCAPED_DIR=$(remembrall_escape_json "$HANDOFF_DIR")

# <=20% — URGENT (only suppress if urgent already sent; allows escalation from warning)
if (( $(echo "$REMAINING <= 20" | bc -l 2>/dev/null || echo 0) )); then
  if [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "urgent" > "$NUDGE_FILE"
  cat << EOF
{
  "additionalContext": "CONTEXT MONITOR URGENT (${REMAINING}% remaining${ESTIMATED}): STOP all work immediately. Auto-run /handoff NOW — write to handoff-${SESSION_ID}.md in ${ESCAPED_DIR}/. Then tell the user to /clear and /resume. Do NOT start any new tool calls."
}
EOF
  exit 0
fi

# <=30% — WARNING (only suppress if warning already sent)
if [ "$LAST_NUDGE" = "warning" ]; then
  exit 0
fi
echo "warning" > "$NUDGE_FILE"
cat << EOF
{
  "additionalContext": "CONTEXT MONITOR (${REMAINING}% remaining${ESTIMATED}): Context is getting low. Auto-run /handoff NOW to preserve your work — write to handoff-${SESSION_ID}.md in ${ESCAPED_DIR}/. After writing the handoff, tell the user to /clear and /resume to continue with full context."
}
EOF
exit 0
