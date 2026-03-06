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

# ── Preemptive safety-net handoff ──────────────────────────────────
# When plan mode is about to trigger, write a handoff BEFORE telling Claude
# to enter plan mode. If the user clicks "Yes, clear context", PreCompact
# does NOT fire — so without this, session-resume.sh has nothing to inject.
# Only runs once per threshold (nudge state prevents re-triggering).
_create_preemptive_handoff() {
  [ -z "$CWD" ] || [ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT_PATH" ] && return
  [ ! -f "$TRANSCRIPT_PATH" ] && return
  jq -n \
    --arg trigger "precompact_auto" \
    --arg session_id "$SESSION_ID" \
    --arg cwd "$CWD" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    '{trigger: $trigger, session_id: $session_id, cwd: $cwd, transcript_path: $transcript_path}' | \
    "$SCRIPT_DIR/precompact-handoff.sh" >/dev/null 2>&1
}

# ── Detect autonomous mode (ralph loop, swarms, etc.) ──
# Two triggers: config setting (global) or marker file (per-session from skill)
IS_AUTONOMOUS=false
AUTONOMOUS_SKILL=""
if [ "$(remembrall_config "autonomous_mode" "false")" = "true" ]; then
  IS_AUTONOMOUS=true
  AUTONOMOUS_SKILL="config"
fi
if [ "$IS_AUTONOMOUS" = false ]; then
  AUTONOMOUS_SKILL=$(remembrall_is_autonomous "$SESSION_ID" 2>/dev/null) && IS_AUTONOMOUS=true || true
fi

# ── Plan content template (shared between warning and urgent) ──
PLAN_ITEMS="task overview, completed work, a 'Next Step — Do This First' section (the EXACT single next action — not a list), remaining tasks after that (priority-ordered), a 'Do NOT Do' section (files to leave alone, approaches ruled out, completed work not to re-analyze), key decisions made and why, modified files with paths (for reference only — not to re-read), current git branch, a prescriptive 'Resume With' section (the next session MUST invoke this — e.g. 'invoke /ralph-loop resume iteration N', 'invoke /test-driven-development next test: X', 'dispatch 3 parallel agents for A,B,C', 'invoke /systematic-debugging hypothesis: X', or 'standard sequential'), tools/agents in use (MCP servers, active skills with / prefix so they can be re-invoked, agent-specific state), and any blockers"

# <=20% — URGENT
if remembrall_le "$REMAINING" 20; then
  if [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "urgent" > "$NUDGE_FILE"
  GAUGE=$(remembrall_gauge "$REMAINING")
  if [ "$IS_AUTONOMOUS" = true ]; then
    cat << EOF
{
  "additionalContext": "${GAUGE} Context critically low (${REMAINING}% remaining${ESTIMATED}). AUTONOMOUS MODE (${AUTONOMOUS_SKILL}) — No human present — skip plan mode. Instead: IMMEDIATELY run /handoff to save full state. Include ${PLAN_ITEMS}. After handoff completes, continue working — auto-compaction will handle context recycling and session-resume will reload the handoff automatically. Do NOT stop or ask the user."
}
EOF
  else
    _create_preemptive_handoff
    cat << EOF
{
  "additionalContext": "${GAUGE} Context critically low (${REMAINING}% remaining${ESTIMATED}). IMMEDIATELY do these two steps IN ORDER:\n\n1. Run /handoff to save a structured handoff document. The handoff MUST include:\n- **Task:** what was requested\n- **Completed:** what is done (with file paths)\n- **Next Step — Do This First:** the EXACT single next action (not a vague list — one specific thing)\n- **Remaining:** other tasks after the next step (priority-ordered)\n- **Do NOT Do:** files to leave alone, approaches already tried and ruled out, completed work that must NOT be re-analyzed\n- **Key Decisions:** choices made and why\n- **Files Modified:** for reference only — the next session must NOT re-read these unless needed for the Next Step\n- **Git Branch:** current branch and commit\n- **Resume With:** (PRESCRIPTIVE) which methodology to invoke and how. Examples: 'Invoke /ralph-loop resume iteration N', '/test-driven-development next test: X', '/systematic-debugging hypothesis: X', 'Standard sequential'\n- **Tools/Agents:** MCP servers, active skills (with / prefix), agent-specific state\n- **Blockers/Context:** errors, gotchas, user preferences\n\n2. AFTER the handoff is saved, call EnterPlanMode. The user can then pick 'Yes, clear context' for a fresh start — the handoff will be injected automatically on resume."
}
EOF
  fi
  exit 0
fi

# <=30% — WARNING
if [ "$LAST_NUDGE" = "warning" ]; then
  exit 0
fi
echo "warning" > "$NUDGE_FILE"
GAUGE=$(remembrall_gauge "$REMAINING")
if [ "$IS_AUTONOMOUS" = true ]; then
  cat << EOF
{
  "additionalContext": "${GAUGE} Context getting low (${REMAINING}% remaining${ESTIMATED}). AUTONOMOUS MODE (${AUTONOMOUS_SKILL}) — No human present — skip plan mode. Instead: run /handoff now to save a progress snapshot with ${PLAN_ITEMS}. Then continue working normally — auto-compaction and session-resume will handle context recycling automatically. Do NOT stop or ask the user."
}
EOF
else
  _create_preemptive_handoff
  cat << EOF
{
  "additionalContext": "${GAUGE} Context getting low (${REMAINING}% remaining${ESTIMATED}). Do these two steps IN ORDER:\n\n1. Run /handoff to save a structured handoff document capturing: ${PLAN_ITEMS}.\n\n2. AFTER the handoff is saved, call EnterPlanMode so the user sees the 'Yes, clear context' option. The handoff will be injected automatically on resume — no manual /replay needed."
}
EOF
fi
exit 0
