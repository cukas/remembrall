#!/usr/bin/env bash
# UserPromptSubmit hook: monitors actual context % via status-line bridge
# Triggers journal checkpoint at configurable thresholds (default: 60%, 35%, 15%)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="context-monitor"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq
remembrall_hook_enabled "context-monitor" || exit 0

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

# Persist plugin root so skills/commands can find scripts without CLAUDE_PLUGIN_ROOT
remembrall_publish_plugin_root

# ── Pensieve: background incremental transcript tracking ──────────
if [ "$(remembrall_config "pensieve" "true")" = "true" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  (echo "$INPUT" | "$SCRIPT_DIR/pensieve-track.sh" >/dev/null 2>&1) &
fi

# ── Patrol: check for signal files before threshold logic ─────────
PATROL_SIGNAL=""
if [ "$(remembrall_config "patrol_integration" "true")" = "true" ] && [ -n "$SESSION_ID" ]; then
  PATROL_SIGNAL=$(remembrall_check_patrol_signal "$SESSION_ID" 2>/dev/null) || PATROL_SIGNAL=""
  if [ -n "$PATROL_SIGNAL" ]; then
    SIGNAL_PAYLOAD=$(remembrall_consume_signal "$SESSION_ID" "$PATROL_SIGNAL" 2>/dev/null) || SIGNAL_PAYLOAD=""
    if [ "$PATROL_SIGNAL" = "handoff_trigger" ]; then
      remembrall_debug "patrol signal: handoff_trigger"
      # Create preemptive handoff (same as warning threshold behavior)
      if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        (
          jq -n \
            --arg trigger "patrol_signal" \
            --arg session_id "$SESSION_ID" \
            --arg cwd "$CWD" \
            --arg transcript_path "$TRANSCRIPT_PATH" \
            '{trigger: $trigger, session_id: $session_id, cwd: $cwd, transcript_path: $transcript_path}' | \
            "$SCRIPT_DIR/precompact-handoff.sh" >/dev/null 2>&1
        ) &
      fi
      PATROL_REASON=$(echo "$SIGNAL_PAYLOAD" | jq -r '.reason // "Patrol requested handoff"' 2>/dev/null) || PATROL_REASON="Patrol requested handoff"
      cat << PATROL_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "REMEMBRALL: Owl Post from Patrol — ${PATROL_REASON}. Run /handoff to save progress."
  }
}
PATROL_EOF
      exit 0
    elif [ "$PATROL_SIGNAL" = "context_alert" ]; then
      remembrall_debug "patrol signal: context_alert"
      PATROL_MSG=$(echo "$SIGNAL_PAYLOAD" | jq -r '.message // ""' 2>/dev/null) || PATROL_MSG=""
      # Check skip_timeturner flag
      SKIP_TT=$(echo "$SIGNAL_PAYLOAD" | jq -r '.skip_timeturner // false' 2>/dev/null) || SKIP_TT="false"
      if [ "$SKIP_TT" = "true" ]; then
        # Write skip marker to suppress TT spawn
        mkdir -p "/tmp/remembrall-timeturner"
        echo "skip" > "/tmp/remembrall-timeturner/${SESSION_ID}-skip"
      fi
      if [ -n "$PATROL_MSG" ]; then
        cat << PATROL_ALERT_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "REMEMBRALL: Owl Post from Patrol — ${PATROL_MSG}"
  }
}
PATROL_ALERT_EOF
        exit 0
      fi
    fi
  fi
fi

# Find bridge file (checks CWD + parent dirs), fall back to transcript size
ESTIMATED=""
REMAINING=""
BRIDGE_ACTIVE=false
CTX_FILE=$(remembrall_find_bridge "$CWD" "$SESSION_ID" 2>/dev/null) || CTX_FILE=""
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
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Write your context remaining % as an integer to /tmp/claude-context-pct/${SESSION_ID}"
  }
}
BOOTSTRAP_EOF
      exit 0
    fi
  fi
fi

# Fallback: estimate from transcript size when bridge is missing or empty.
# BUT: if the bridge is configured in settings.json, it will write a value on
# the next response cycle. Don't fall back to the inaccurate estimator — the
# bridge value will appear shortly. This prevents showing wildly wrong estimates
# (e.g., 5%) when the bridge file is temporarily missing after compaction.
if [ -z "$REMAINING" ]; then
  if grep -q "claude-context-pct" "$HOME/.claude/settings.json" 2>/dev/null; then
    # Bridge is configured but file not written yet — skip silently
    exit 0
  fi
  REMAINING=$(remembrall_estimate_context "$TRANSCRIPT_PATH") || exit 0
  # shellcheck disable=SC2034
  ESTIMATED=" (estimated)"
fi

# ── Configurable thresholds ───────────────────────────────────────
THRESHOLD_JOURNAL=$(remembrall_threshold "journal" 65)
THRESHOLD_WARNING=$(remembrall_threshold "warning" 35)
THRESHOLD_URGENT=$(remembrall_threshold "urgent" 25)
THRESHOLD_TIMETURNER=$(remembrall_threshold "timeturner" 30)

# Nudge tracking — don't spam every prompt
NUDGE_DIR="/tmp/remembrall-nudges"
mkdir -p "$NUDGE_DIR"
NUDGE_FILE="$NUDGE_DIR/$SESSION_ID"

LAST_NUDGE=""
if [ -f "$NUDGE_FILE" ]; then
  LAST_NUDGE=$(cat "$NUDGE_FILE")
fi

remembrall_debug "session=${SESSION_ID} remaining=${REMAINING} bridge=${BRIDGE_ACTIVE} nudge=${LAST_NUDGE}"

# Reset nudge state if context recovered (post-compaction: remaining > journal threshold + 20%)
RESET_THRESHOLD=$((THRESHOLD_JOURNAL + 20))
if remembrall_gt "$REMAINING" "$RESET_THRESHOLD"; then
  rm -f "$NUDGE_FILE"
  exit 0
fi

# Above journal threshold — do nothing
if remembrall_gt "$REMAINING" "$THRESHOLD_JOURNAL"; then
  exit 0
fi

# ── Extract shared values for calibration + growth (runs once at <=60%) ──
CONTENT_BYTES=""
MODEL_NAME=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  CONTENT_BYTES=$(remembrall_extract_content_bytes "$TRANSCRIPT_PATH" 2>/dev/null)
  _model_info=$(remembrall_detect_model "$TRANSCRIPT_PATH")
  MODEL_NAME=$(printf '%s' "$_model_info" | cut -f1)
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
      _content_max=$(remembrall_calibrated_content_max "$TRANSCRIPT_PATH" 2>/dev/null)
      if [ -z "$_content_max" ] || [ "$_content_max" -eq 0 ] 2>/dev/null; then
        _content_max=$(remembrall_default_content_max "$MODEL_NAME")
      fi
      PROMPTS_LEFT=$(remembrall_prompts_until_threshold "$CONTENT_BYTES" "$AVG_GROWTH" "$_content_max" "$THRESHOLD_URGENT" 2>/dev/null)
      if [ -n "$PROMPTS_LEFT" ] && [ "$PROMPTS_LEFT" -gt 0 ] 2>/dev/null; then
        PROMPTS_MSG=" (~${PROMPTS_LEFT} prompts to ${THRESHOLD_URGENT}%)"
      fi
      if [ "$IS_VOLATILE" = "1" ]; then
        PROMPTS_MSG="${PROMPTS_MSG} [volatile session]"
      fi
    fi
  fi
fi

# ── Obliviate: spawn analyzer at journal threshold (background) ───
if [ "$(remembrall_config "obliviate" "true")" = "true" ] && [ -n "$CWD" ]; then
  _obliviate_dir=$(remembrall_obliviate_dir)
  _obliviate_file="$_obliviate_dir/${SESSION_ID}.json"
  if [ ! -f "$_obliviate_file" ]; then
    (echo "$INPUT" | "$SCRIPT_DIR/obliviate-analyze.sh" >/dev/null 2>&1) &
  fi
fi

# ── Budget: spawn analyzer below journal threshold (background) ──
if [ "$(remembrall_config "budget_enabled" "false")" = "true" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  (echo "$INPUT" | "$SCRIPT_DIR/budget-analyze.sh" >/dev/null 2>&1) &
fi

# Between journal and warning thresholds — JOURNAL CHECKPOINT
if remembrall_gt "$REMAINING" "$THRESHOLD_WARNING"; then
  if [ "$LAST_NUDGE" = "journal" ] || [ "$LAST_NUDGE" = "warning" ] || [ "$LAST_NUDGE" = "urgent" ]; then
    exit 0
  fi
  echo "journal" > "$NUDGE_FILE"
  SPELL_LINE=""
  if [ "$(remembrall_config "easter_eggs" "true")" = "true" ]; then
    SPELL_LINE=" Spells: Expecto Patronum=/handoff, Lumos=/status, Accio=/replay, Pensieve=/pensieve, Marauder's Map=/map, Time-Turner=/timeturner, Lineage=/lineage, Insights=/insights, Obliviate=/obliviate, Budget=/budget, Prior Incantato=handoff count this session (only if user speaks HP)"
  fi
  # Obliviate: include stale memory warning if analysis is ready
  OBLIVIATE_MSG=""
  _obliviate_dir=$(remembrall_obliviate_dir)
  if [ -f "$_obliviate_dir/${SESSION_ID}.json" ]; then
    _stale_count=$(jq -r '.stale_count // 0' "$_obliviate_dir/${SESSION_ID}.json" 2>/dev/null) || _stale_count=0
    if [ "$_stale_count" -gt 0 ]; then
      if [ "$(remembrall_config "easter_eggs" "true")" = "true" ]; then
        OBLIVIATE_MSG=" Obliviate! ${_stale_count} stale memories detected — run /obliviate to review."
      else
        OBLIVIATE_MSG=" ${_stale_count} stale memories detected — run /obliviate to review."
      fi
    fi
  fi
  # Budget: include imbalance warning if analysis is ready
  BUDGET_MSG=""
  _budget_dir=$(remembrall_budget_dir)
  if [ -f "$_budget_dir/${SESSION_ID}.json" ]; then
    _warning_count=$(jq '.warnings | length' "$_budget_dir/${SESSION_ID}.json" 2>/dev/null) || _warning_count=0
    if [ "$_warning_count" -gt 0 ]; then
      _top_cat=$(jq -r '.warnings[0].category // "unknown"' "$_budget_dir/${SESSION_ID}.json" 2>/dev/null) || _top_cat="unknown"
      _top_pct=$(jq -r '.warnings[0].actual // 0' "$_budget_dir/${SESSION_ID}.json" 2>/dev/null) || _top_pct=0
      if [ "$(remembrall_config "easter_eggs" "true")" = "true" ]; then
        _house="Ravenclaw"
        case "$_top_cat" in
          conversation) _house="Gryffindor" ;;
          memory) _house="Hufflepuff" ;;
        esac
        BUDGET_MSG=" The Sorting Hat detects an imbalance! ${_house} has claimed ${_top_pct}% of the common room."
      else
        BUDGET_MSG=" Budget warning: ${_top_cat} at ${_top_pct}% (over budget)."
      fi
    fi
  fi
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "REMEMBRALL: Context at ${REMAINING}%.${PROMPTS_MSG} Run /handoff when ready to save progress.${OBLIVIATE_MSG}${BUDGET_MSG}${SPELL_LINE}"
  }
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
  # Run in background to avoid eating into context-monitor's 15s timeout.
  # The handoff is a safety net — we don't need it to complete before emitting the nudge.
  (
    jq -n \
      --arg trigger "precompact_auto" \
      --arg session_id "$SESSION_ID" \
      --arg cwd "$CWD" \
      --arg transcript_path "$TRANSCRIPT_PATH" \
      '{trigger: $trigger, session_id: $session_id, cwd: $cwd, transcript_path: $transcript_path}' | \
      "$SCRIPT_DIR/precompact-handoff.sh" >/dev/null 2>&1
  ) &
}

# ── Time-Turner: spawn parallel agent at threshold ──────────────
# Fires once when context drops to time-turner threshold (default 30%).
# Must run BEFORE the urgent exit — if context drops from 35% to 20% in
# one turn, the urgent block would exit before reaching this check.
# Patrol can suppress TT spawn via skip_timeturner signal.
if remembrall_le "$REMAINING" "$THRESHOLD_TIMETURNER"; then
  TT_STATE_DIR="/tmp/remembrall-timeturner/${SESSION_ID}"
  TT_SKIP_FILE="/tmp/remembrall-timeturner/${SESSION_ID}-skip"
  if [ ! -d "$TT_STATE_DIR" ] && [ ! -f "$TT_SKIP_FILE" ] && [ "$(remembrall_config "time_turner" "false")" = "true" ]; then
    remembrall_debug "spawning Time-Turner at ${REMAINING}%"
    (echo "$INPUT" | "$SCRIPT_DIR/time-turner-spawn.sh" >/dev/null 2>&1) &
  fi
fi

# ── Detect autonomous mode ──────────────────────────────────────
IS_AUTONOMOUS=false
if [ "$(remembrall_config "autonomous_mode" "true")" = "true" ]; then
  IS_AUTONOMOUS=true
fi
if [ "$IS_AUTONOMOUS" = false ] && [ -n "$SESSION_ID" ]; then
  remembrall_is_autonomous "$SESSION_ID" >/dev/null 2>&1 && IS_AUTONOMOUS=true || true
fi

# At or below urgent threshold — URGENT (safety net if warning was ignored)
if remembrall_le "$REMAINING" "$THRESHOLD_URGENT"; then
  echo "urgent" > "$NUDGE_FILE"
  _create_preemptive_handoff

  if [ "$IS_AUTONOMOUS" = true ]; then
    # Autonomous: handoff + keep working — auto-compaction handles the rest
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "REMEMBRALL_URGENT: Context critical (${REMAINING}%). AUTONOMOUS MODE — run /handoff NOW, continue working. Auto-compaction will reset context and auto-resume."
  }
}
EOF
  else
    # Normal: handoff + EnterPlanMode — user clicks "Yes, clear context"
    HANDOFF_DIR=$(remembrall_handoff_dir "$CWD" 2>/dev/null) || HANDOFF_DIR=""
    HAS_HANDOFF=false
    if [ -n "$HANDOFF_DIR" ] && [ -n "$SESSION_ID" ]; then
      [ -f "$HANDOFF_DIR/handoff-${SESSION_ID}.md" ] && HAS_HANDOFF=true
    fi
    if [ "$HAS_HANDOFF" = true ]; then
      cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "REMEMBRALL_URGENT: Context critical (${REMAINING}%). Handoff already saved. BLOCKING REQUIREMENT: Call EnterPlanMode NOW. Tell the user: Click 'Yes, clear context' — work auto-resumes. Do NOT instruct user to type /clear or /replay."
  },
  "systemMessage": "BLOCKING REQUIREMENT: Context CRITICAL (${REMAINING}%). Handoff saved. Call EnterPlanMode immediately. Do NOT proceed with other tasks."
}
EOF
    else
      cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "REMEMBRALL_URGENT: Context critical (${REMAINING}%). BLOCKING REQUIREMENT: Run /handoff NOW, then call EnterPlanMode. Tell the user: Click 'Yes, clear context' — work auto-resumes. Do NOT instruct user to type /clear or /replay."
  },
  "systemMessage": "BLOCKING REQUIREMENT: Context CRITICAL (${REMAINING}%). Run /handoff NOW, then call EnterPlanMode. Do NOT proceed with other tasks."
}
EOF
    fi
  fi
  exit 0
fi

# At or below warning threshold — WARNING
echo "warning" > "$NUDGE_FILE"
if [ "$LAST_NUDGE" != "warning" ] && [ "$LAST_NUDGE" != "urgent" ]; then
  _create_preemptive_handoff
fi
if [ "$IS_AUTONOMOUS" = true ]; then
  # Autonomous: handoff + keep working — auto-compaction handles the rest
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "REMEMBRALL_WARN: Context at ${REMAINING}%.${PROMPTS_MSG} AUTONOMOUS MODE — run /handoff NOW, continue working. Auto-compaction will reset context and auto-resume."
  }
}
EOF
else
  # Normal: handoff + EnterPlanMode — user clicks "Yes, clear context"
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "REMEMBRALL_WARN: Context at ${REMAINING}%.${PROMPTS_MSG} BLOCKING REQUIREMENT: Run /handoff NOW, then call EnterPlanMode. Tell the user: Handoff saved — click 'Yes, clear context' to continue with fresh context. Work auto-resumes after clear."
  },
  "systemMessage": "BLOCKING REQUIREMENT: Context at ${REMAINING}%. Run /handoff, then call EnterPlanMode immediately. Do NOT instruct the user to type /clear or /replay."
}
EOF
fi
exit 0
