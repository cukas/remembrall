#!/usr/bin/env bash
# Stop hook: enforce handoff save when context is low, suggest /clear + /replay otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="stop-check"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq
remembrall_hook_enabled "stop-check" || exit 0

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
CTX_FILE=$(remembrall_find_bridge "$CWD" "$SESSION_ID" 2>/dev/null) || CTX_FILE=""
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
  HOFF_DIR=$(remembrall_handoff_dir "$CWD") || true
  if [ -n "$HOFF_DIR" ]; then
    HANDOFF_FILE="$HOFF_DIR/handoff-${SESSION_ID}.md"
    if [ -f "$HANDOFF_FILE" ]; then
      HANDOFF_EXISTS=true
    fi
  fi
fi

if [ "$HANDOFF_EXISTS" = true ]; then
  # Handoff exists — just suggest /clear + /replay via stderr (ANSI OK here)
  GAUGE=$(remembrall_gauge "$REMAINING")
  echo "Remembrall: ${GAUGE} remaining${ESTIMATED}. Handoff saved. Session will auto-resume after context clears." >&2
else
  # No handoff — block stop and ask user to save handoff first
  cat << EOF
{
  "decision": "block",
  "reason": "REMEMBRALL_WARN: Context at ${REMAINING}%${ESTIMATED}. You MUST run /handoff before completing this task. Do not stop without saving state."
}
EOF
fi
exit 0
