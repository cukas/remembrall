#!/usr/bin/env bash
# Stop hook: enforce handoff save when context is low, suggest /clear + /replay otherwise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# Prevent infinite loop — don't fire if we're already in a stop-hook continuation
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

if [ -z "$CWD" ]; then
  exit 0
fi

# Try bridge first, then transcript fallback
REMAINING=""
ESTIMATED=""
CTX_FILE=$(remembrall_find_bridge "$CWD" "$SESSION_ID") 2>/dev/null
if [ -n "$CTX_FILE" ]; then
  REMAINING=$(cat "$CTX_FILE" 2>/dev/null)
  if ! remembrall_validate_number "$REMAINING"; then
    REMAINING=""
  fi
fi

if [ -z "$REMAINING" ]; then
  REMAINING=$(remembrall_estimate_context "$TRANSCRIPT_PATH") || exit 0
  ESTIMATED=" (estimated)"
fi

# Only act if below 40%
if remembrall_ge "$REMAINING" 40; then
  exit 0
fi

# Check if a handoff already exists for this session
HANDOFF_EXISTS=false
if [ -n "$SESSION_ID" ] && [ -n "$CWD" ]; then
  HASH=$(remembrall_md5 "$CWD")
  HANDOFF_FILE="$HOME/.remembrall/handoffs/$HASH/handoff-${SESSION_ID}.md"
  if [ -f "$HANDOFF_FILE" ]; then
    HANDOFF_EXISTS=true
  fi
fi

if [ "$HANDOFF_EXISTS" = true ]; then
  # Handoff exists — just suggest /clear + /replay via stderr (ANSI OK here)
  GAUGE=$(remembrall_gauge "$REMAINING")
  echo "Remembrall: ${GAUGE} Context at ${REMAINING}%${ESTIMATED}. Handoff saved. Consider /clear + /replay before new work." >&2
else
  # No handoff — enforce handoff creation via additionalContext (plain text for JSON)
  GAUGE=$(remembrall_gauge_plain "$REMAINING")
  cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}. You MUST run /handoff before completing this task. Do not stop without saving state."
}
EOF
fi
exit 0
