#!/usr/bin/env bash
# UserPromptSubmit hook: monitors actual context % via status-line bridge
# Triggers journal checkpoint at 60%, plan mode at 30%, urgent plan mode at 20%

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

# Publish session_id so skill commands (handoff-create.sh) can read it
remembrall_publish_session_id "$CWD" "$SESSION_ID"

# Find bridge file (checks CWD + parent dirs), fall back to transcript size
ESTIMATED=""
REMAINING=""
CTX_FILE=$(remembrall_find_bridge "$CWD" "$SESSION_ID") 2>/dev/null
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

# <=20% — URGENT: enter plan mode immediately
if remembrall_le "$REMAINING" 20; then
  if [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "urgent" > "$NUDGE_FILE"
  GAUGE=$(remembrall_gauge "$REMAINING")
  cat << EOF
{
  "additionalContext": "${GAUGE} Context critically low (${REMAINING}% remaining${ESTIMATED}). IMMEDIATELY write a continuation plan and call EnterPlanMode. The plan MUST include:\n- **Task:** what was requested\n- **Completed:** what is done (with file paths)\n- **Remaining:** what still needs to happen (priority-ordered)\n- **Key Decisions:** choices made and why\n- **Files Modified:** list of changed files\n- **Git Branch:** current branch and commit\n- **Resume With:** (PRESCRIPTIVE — the next session MUST invoke this) which methodology to continue with and how to start it. Examples: 'Invoke /ralph-loop and resume iteration N', 'Invoke /test-driven-development — next test to write: [X]', 'Dispatch 3 parallel agents for tasks [A, B, C]', 'Invoke /systematic-debugging — current hypothesis: [X]', 'Standard sequential — just continue the task list'. If agents were running, list their tasks and whether results are pending.\n- **Tools/Agents:** MCP servers in use, active skills invoked this session, any agent-specific config or state that must carry over. List skill names with / prefix so they can be re-invoked.\n- **Blockers/Context:** errors, gotchas, user preferences\n\nOnce in plan mode the user can pick 'Yes, clear context' to get a fresh start with the plan preserved. This is faster and smoother than /handoff + /clear + /replay."
}
EOF
  exit 0
fi

# <=30% — WARNING: suggest plan mode for seamless context refresh
if [ "$LAST_NUDGE" = "warning" ]; then
  exit 0
fi
echo "warning" > "$NUDGE_FILE"
GAUGE=$(remembrall_gauge "$REMAINING")
cat << EOF
{
  "additionalContext": "${GAUGE} Context getting low (${REMAINING}% remaining${ESTIMATED}). Write a detailed continuation plan capturing: task overview, completed work, remaining tasks (priority-ordered), key decisions, modified files with paths, current git branch, a prescriptive 'Resume With' section (the next session MUST invoke this — e.g. 'invoke /ralph-loop resume iteration N', 'invoke /test-driven-development next test: X', 'dispatch 3 parallel agents for A,B,C', 'invoke /systematic-debugging hypothesis: X', or 'standard sequential'), tools/agents in use (MCP servers, active skills with / prefix so they can be re-invoked, agent-specific state), and any blockers. Then call EnterPlanMode so the user sees the 'Yes, clear context' option for a fresh start with the plan preserved. This replaces the old /handoff + /clear + /replay workflow — one step instead of three."
}
EOF
exit 0
