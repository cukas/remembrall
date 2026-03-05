#!/usr/bin/env bash
# Stop hook: if context is low, suggest /clear + /resume before starting new work.
# This catches the case where Claude finishes a task but context is nearly full.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

INPUT=$(cat)
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
CTX_FILE=$(remembrall_find_bridge "$CWD") 2>/dev/null
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

# Only suggest if below 40%
if (( $(echo "$REMAINING >= 40" | bc -l 2>/dev/null || echo 0) )); then
  exit 0
fi

# Output to stderr — shown to user in terminal without risking Claude re-engagement
echo "Remembrall: Context is at ${REMAINING}%${ESTIMATED} remaining. Consider /clear + /resume before starting new work." >&2
exit 0
