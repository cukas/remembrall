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
  ESTIMATED=" (estimated)"
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

# <=60% and >30% — JOURNAL CHECKPOINT
if remembrall_gt "$REMAINING" 30; then
  if [ "$LAST_NUDGE" = "journal" ] || [ "$LAST_NUDGE" = "warning" ] || [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "journal" > "$NUDGE_FILE"
  GAUGE=$(remembrall_gauge "$REMAINING")
  SPELL="Spells: Expecto Patronum=/handoff, Lumos=/status, Accio=/replay, Prior Incantato=handoff count this session (only if user speaks HP)"
  cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}. Run /handoff to save progress. ${SPELL}"
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
IS_AUTONOMOUS=false
AUTONOMOUS_SKILL=""
if [ "$(remembrall_config "autonomous_mode" "false")" = "true" ]; then
  IS_AUTONOMOUS=true
  AUTONOMOUS_SKILL="config"
fi
if [ "$IS_AUTONOMOUS" = false ]; then
  AUTONOMOUS_SKILL=$(remembrall_is_autonomous "$SESSION_ID" 2>/dev/null) && IS_AUTONOMOUS=true || true
fi

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
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}. AUTONOMOUS MODE (${AUTONOMOUS_SKILL}) — IMMEDIATELY run /handoff, continue working."
}
EOF
  else
    _create_preemptive_handoff
    cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}. IMMEDIATELY run /handoff then EnterPlanMode."
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
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}. AUTONOMOUS MODE (${AUTONOMOUS_SKILL}) — run /handoff, continue working."
}
EOF
else
  _create_preemptive_handoff
  SPELL="Spells: Expecto Patronum=/handoff, Lumos=/status, Accio=/replay, Prior Incantato=handoff count this session (only if user speaks HP)"
  cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}. Run /handoff then EnterPlanMode. ${SPELL}"
}
EOF
fi
exit 0
