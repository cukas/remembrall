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
BRIDGE_ACTIVE=false
CTX_FILE=$(remembrall_find_bridge "$CWD" "$SESSION_ID") 2>/dev/null
if [ -n "$CTX_FILE" ]; then
  REMAINING=$(cat "$CTX_FILE" 2>/dev/null)
  if remembrall_validate_number "$REMAINING"; then
    BRIDGE_ACTIVE=true
  else
    REMAINING=""
  fi
fi

# ── Layer 2: Bootstrap bridge for current session ──────────────────
# If no bridge file exists and we haven't bootstrapped yet, fire a one-time
# additionalContext asking Claude to write the bridge file. ~20 tokens, fires once.
if [ "$BRIDGE_ACTIVE" = false ]; then
  BOOTSTRAP_DIR="/tmp/remembrall-bootstrap"
  mkdir -p "$BOOTSTRAP_DIR"
  BOOTSTRAP_FILE="$BOOTSTRAP_DIR/$SESSION_ID"

  if [ ! -f "$BOOTSTRAP_FILE" ]; then
    # Mark as bootstrapped (don't repeat)
    echo "1" > "$BOOTSTRAP_FILE"
    # Ask Claude to write bridge file — only if settings.json has the bridge
    if grep -q "claude-context-pct" "$HOME/.claude/settings.json" 2>/dev/null; then
      # Bridge is in settings but file doesn't exist yet — it'll appear on next response cycle
      true  # No action needed — settings.json bridge will activate naturally
    else
      # No bridge in settings — request Claude to write it manually (one-time, ~20 tokens)
      cat << BOOTSTRAP_EOF
{
  "additionalContext": "Write your context remaining % as an integer to /tmp/claude-context-pct/${SESSION_ID}"
}
BOOTSTRAP_EOF
      exit 0
    fi
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

# ── Extract shared values for calibration + growth (runs once at <=60%) ──
CONTENT_BYTES=""
MODEL_NAME=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  CONTENT_BYTES=$(remembrall_extract_content_bytes "$TRANSCRIPT_PATH" 2>/dev/null)
  local_model_info=$(remembrall_detect_model "$TRANSCRIPT_PATH")
  MODEL_NAME=$(printf '%s' "$local_model_info" | cut -f1)
fi

# ── Bridge-derived content_max: auto-calibrate per user ──────────
# When bridge is active, derive the real content_max for this user's setup.
# This replaces hardcoded defaults with measured values.
if [ "$BRIDGE_ACTIVE" = true ] && [ -n "$CONTENT_BYTES" ] && [ "$CONTENT_BYTES" -gt 0 ] 2>/dev/null; then
  remembrall_store_derived_content_max "$CONTENT_BYTES" "$REMAINING" "$MODEL_NAME" 2>/dev/null
fi

# ── Bridge-paired calibration: log pair when both sources available ──
if [ "$BRIDGE_ACTIVE" = true ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  STRUCTURAL_EST=$(remembrall_estimate_context_structural "$TRANSCRIPT_PATH" "$CONTENT_BYTES" "$MODEL_NAME" 2>/dev/null)
  if [ -n "$STRUCTURAL_EST" ] && [ -n "$REMAINING" ]; then
    remembrall_log_calibration_pair "$TRANSCRIPT_PATH" "$REMAINING" "$STRUCTURAL_EST" "$CONTENT_BYTES" "$MODEL_NAME" 2>/dev/null
  fi
fi

# ── Growth tracking (runs at <=60% to keep >60% path fast) ──────
PROMPTS_MSG=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  GROWTH_RESULT=$(remembrall_track_growth "$SESSION_ID" "$TRANSCRIPT_PATH" 2>/dev/null)
  if [ -n "$GROWTH_RESULT" ]; then
    AVG_GROWTH=$(printf '%s' "$GROWTH_RESULT" | cut -f1)
    IS_VOLATILE=$(printf '%s' "$GROWTH_RESULT" | cut -f2)
    if [ "$AVG_GROWTH" -gt 0 ] 2>/dev/null; then
      # Get content_max for prompts-until-threshold calculation
      local_content_max=$(remembrall_calibrated_content_max "$TRANSCRIPT_PATH" 2>/dev/null)
      if [ -z "$local_content_max" ] || [ "$local_content_max" -eq 0 ] 2>/dev/null; then
        case "$MODEL_NAME" in
          claude-opus-4-6*|claude-opus-4*)   local_content_max=358400 ;;
          claude-sonnet-4-6*|claude-sonnet-4*) local_content_max=337920 ;;
          claude-haiku-4-5*|claude-haiku-4*)  local_content_max=317440 ;;
          *)                                   local_content_max=337920 ;;
        esac
      fi
      PROMPTS_LEFT=$(remembrall_prompts_until_threshold "$CONTENT_BYTES" "$AVG_GROWTH" "$local_content_max" 20 2>/dev/null)
      if [ -n "$PROMPTS_LEFT" ] && [ "$PROMPTS_LEFT" -gt 0 ] 2>/dev/null; then
        PROMPTS_MSG=" (~${PROMPTS_LEFT} prompts to 20%)"
      fi
      if [ "$IS_VOLATILE" = "1" ]; then
        PROMPTS_MSG="${PROMPTS_MSG} [volatile session]"
      fi
    fi
  fi
fi

# <=60% and >30% — JOURNAL CHECKPOINT
if remembrall_gt "$REMAINING" 30; then
  if [ "$LAST_NUDGE" = "journal" ] || [ "$LAST_NUDGE" = "warning" ] || [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "journal" > "$NUDGE_FILE"
  GAUGE=$(remembrall_gauge_plain "$REMAINING")
  SPELL="Spells: Expecto Patronum=/handoff, Lumos=/status, Accio=/replay, Prior Incantato=handoff count this session (only if user speaks HP)"
  cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}${PROMPTS_MSG}. Run /handoff to save progress. ${SPELL}"
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
# Escape for safe JSON interpolation
AUTONOMOUS_SKILL=$(remembrall_escape_json "$AUTONOMOUS_SKILL")

# <=20% — URGENT
if remembrall_le "$REMAINING" 20; then
  if [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "urgent" > "$NUDGE_FILE"
  GAUGE=$(remembrall_gauge_plain "$REMAINING")
  if [ "$IS_AUTONOMOUS" = true ]; then
    cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}${PROMPTS_MSG}. AUTONOMOUS MODE (${AUTONOMOUS_SKILL}) — IMMEDIATELY run /handoff, continue working."
}
EOF
  else
    _create_preemptive_handoff
    cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}${PROMPTS_MSG}. IMMEDIATELY run /handoff then EnterPlanMode."
}
EOF
  fi
  exit 0
fi

# <=30% — WARNING
if [ "$LAST_NUDGE" = "warning" ] || [ "$LAST_NUDGE" = "urgent" ]; then
  exit 0
fi
echo "warning" > "$NUDGE_FILE"
GAUGE=$(remembrall_gauge_plain "$REMAINING")
if [ "$IS_AUTONOMOUS" = true ]; then
  cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}${PROMPTS_MSG}. AUTONOMOUS MODE (${AUTONOMOUS_SKILL}) — run /handoff, continue working."
}
EOF
else
  _create_preemptive_handoff
  SPELL="Spells: Expecto Patronum=/handoff, Lumos=/status, Accio=/replay, Prior Incantato=handoff count this session (only if user speaks HP)"
  cat << EOF
{
  "additionalContext": "${GAUGE} ${REMAINING}% remaining${ESTIMATED}${PROMPTS_MSG}. Run /handoff then EnterPlanMode. ${SPELL}"
}
EOF
fi
exit 0
