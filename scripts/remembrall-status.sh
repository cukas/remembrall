#!/usr/bin/env bash
# Remembrall diagnostic script — checks bridge, handoffs, nudges, settings

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib.sh"

remembrall_require_jq

CWD="${1:-$(pwd)}"

HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || { echo "Error: could not compute handoff directory"; exit 1; }

echo "Remembrall Status"
echo "─────────────────"

# Bridge — check CWD + parent dirs
CTX_FILE=$(remembrall_find_bridge "$CWD")
if [ -n "$CTX_FILE" ]; then
  echo "Bridge:   OK ($(cat "$CTX_FILE")% remaining)"
else
  echo "Bridge:   NOT FOUND — run /setup-remembrall"
fi

# Handoffs — use glob count instead of ls|wc
if [ -d "$HANDOFF_DIR" ]; then
  COUNT=0
  for f in "$HANDOFF_DIR"/handoff-*.md; do [ -f "$f" ] && COUNT=$((COUNT + 1)); done
  if [ "$COUNT" -gt 0 ]; then
    echo "Handoffs: $COUNT file(s)"
    for f in "$HANDOFF_DIR"/handoff-*.md; do
      [ -f "$f" ] && echo "          $f"
    done
  else
    echo "Handoffs: None"
  fi
else
  echo "Handoffs: None"
fi

# Nudges
NUDGE_DIR="/tmp/remembrall-nudges"
if [ -d "$NUDGE_DIR" ]; then
  found=0
  for f in "$NUDGE_DIR"/*; do
    if [ -f "$f" ]; then
      echo "Nudges:   $(basename "$f") = $(cat "$f")"
      found=1
    fi
  done
  [ "$found" -eq 0 ] && echo "Nudges:   None active"
else
  echo "Nudges:   None active"
fi

# Settings bridge
if grep -q "claude-context-pct" ~/.claude/settings.json 2>/dev/null; then
  echo "Settings: Bridge installed (session_id keyed)"
else
  echo "Settings: Bridge MISSING — run /setup-remembrall"
fi

# Config
CONFIG_FILE="$HOME/.remembrall/config.json"
if [ -f "$CONFIG_FILE" ]; then
  echo "Config:   $CONFIG_FILE"
  GIT_INT=$(jq -r '.git_integration // "false"' "$CONFIG_FILE" 2>/dev/null)
  TEAM=$(jq -r '.team_handoffs // "false"' "$CONFIG_FILE" 2>/dev/null)
  echo "          git_integration: $GIT_INT"
  echo "          team_handoffs: $TEAM"
else
  echo "Config:   Not configured (using defaults)"
fi

# Patches
PATCHES_DIR=$(remembrall_patches_dir "$CWD" 2>/dev/null)
if [ -n "$PATCHES_DIR" ] && [ -d "$PATCHES_DIR" ]; then
  PATCH_COUNT=0
  for f in "$PATCHES_DIR"/patch-*.diff; do [ -f "$f" ] && PATCH_COUNT=$((PATCH_COUNT + 1)); done
  if [ "$PATCH_COUNT" -gt 0 ]; then
    echo "Patches:  $PATCH_COUNT file(s)"
    for f in "$PATCHES_DIR"/patch-*.diff; do
      [ -f "$f" ] && echo "          $f"
    done
  else
    echo "Patches:  None"
  fi
else
  echo "Patches:  None"
fi

# Session handoff count
COUNTER_DIR="/tmp/remembrall-handoff-count"
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -n "$SESSION_ID" ] && [ -f "$COUNTER_DIR/$SESSION_ID" ]; then
  HCOUNT=$(cat "$COUNTER_DIR/$SESSION_ID" 2>/dev/null || echo 0)
  echo "Saves:    $HCOUNT handoff(s) this session"
else
  echo "Saves:    0 handoffs this session"
fi

# Autonomous mode
AUTO_MODE=$(remembrall_config "autonomous_mode" "true")
echo "Auto:     $AUTO_MODE"

# Calibration
CAL_FILE="$HOME/.remembrall/calibration.json"
if [ -f "$CAL_FILE" ]; then
  CAL_MAX=$(remembrall_calibrated_max)
  CAL_SAMPLES=$(jq '.samples | length' "$CAL_FILE" 2>/dev/null || echo 0)
  if [ -n "$CAL_MAX" ] && [ "$CAL_MAX" -gt 0 ] 2>/dev/null; then
    echo "Calibr:   ${CAL_MAX} bytes (~$((CAL_MAX / 1024))KB) from $CAL_SAMPLES sample(s)"
  else
    echo "Calibr:   No data yet"
  fi
else
  echo "Calibr:   Not calibrated (using default 256KB)"
fi

# Pensieve
PENSIEVE_DIR=$(remembrall_pensieve_dir "$CWD" 2>/dev/null) || PENSIEVE_DIR=""
if [ -n "$PENSIEVE_DIR" ] && [ -d "$PENSIEVE_DIR" ]; then
  P_COUNT=0
  for f in "$PENSIEVE_DIR"/session-*.json; do [ -f "$f" ] && P_COUNT=$((P_COUNT + 1)); done
  echo "Pensieve: $P_COUNT saved session(s)"
else
  echo "Pensieve: No saved sessions"
fi

# Pensieve tracking (current session)
PENSIEVE_TMP=$(remembrall_pensieve_tmp)
if [ -n "$SESSION_ID" ] && [ -f "$PENSIEVE_TMP/${SESSION_ID}.jsonl" ]; then
  ENTRY_COUNT=$(wc -l < "$PENSIEVE_TMP/${SESSION_ID}.jsonl" 2>/dev/null | tr -d ' ')
  echo "Tracking: $ENTRY_COUNT entries this session"
else
  echo "Tracking: No entries yet"
fi

# Time-Turner
TT_STATUS=$("$SCRIPT_DIR/../hooks/time-turner-check.sh" "$CWD" 2>/dev/null) || TT_STATUS=""
if [ -n "$TT_STATUS" ]; then
  echo "Turner:   $TT_STATUS"
else
  echo "Turner:   Not active"
fi

# Lineage
LINEAGE_DIR=$(remembrall_lineage_dir "$CWD" 2>/dev/null) || LINEAGE_DIR=""
if [ -n "$LINEAGE_DIR" ] && [ -f "$LINEAGE_DIR/index.json" ]; then
  L_COUNT=$(jq '.sessions | length' "$LINEAGE_DIR/index.json" 2>/dev/null) || L_COUNT=0
  L_BRANCHES=$(remembrall_lineage_branches "$CWD" 2>/dev/null) || L_BRANCHES=0
  echo "Lineage:  $L_COUNT session(s), $L_BRANCHES branch point(s)"
else
  echo "Lineage:  No data yet"
fi

# Statistics
STATISTICS_DIR=$(remembrall_statistics_dir "$CWD" 2>/dev/null) || STATISTICS_DIR=""
if [ -n "$STATISTICS_DIR" ] && [ -f "$STATISTICS_DIR/statistics.json" ]; then
  I_SESSIONS=$(jq -r '.sessions_analyzed // 0' "$STATISTICS_DIR/statistics.json" 2>/dev/null)
  I_HOTSPOTS=$(jq '.file_hotspots | length' "$STATISTICS_DIR/statistics.json" 2>/dev/null) || I_HOTSPOTS=0
  echo "Statistics: $I_SESSIONS sessions analyzed, $I_HOTSPOTS hotspot(s)"
else
  echo "Statistics: Not yet aggregated"
fi

# Obliviate
OBLIVIATE_DIR=$(remembrall_obliviate_dir)
if [ -n "$SESSION_ID" ] && [ -f "$OBLIVIATE_DIR/${SESSION_ID}.json" ]; then
  O_STALE=$(jq -r '.stale_count // 0' "$OBLIVIATE_DIR/${SESSION_ID}.json" 2>/dev/null) || O_STALE=0
  echo "Obliviate: $O_STALE stale memory/ies detected"
else
  echo "Obliviate: Not analyzed yet"
fi

# Budget
BUDGET_DIR=$(remembrall_budget_dir)
if [ -n "$SESSION_ID" ] && [ -f "$BUDGET_DIR/${SESSION_ID}.json" ]; then
  B_CODE=$(jq -r '.code_pct // 0' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null)
  B_CONV=$(jq -r '.conversation_pct // 0' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null)
  B_MEM=$(jq -r '.memory_pct // 0' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null)
  echo "Budget:   code=${B_CODE}% conv=${B_CONV}% mem=${B_MEM}%"
else
  BUDGET_ENABLED=$(remembrall_config "budget_enabled" "false")
  if [ "$BUDGET_ENABLED" = "true" ]; then
    echo "Budget:   Not analyzed yet"
  else
    echo "Budget:   Disabled (opt-in: budget_enabled=true)"
  fi
fi

# Patrol
PATROL_STATUS="not detected"
if remembrall_patrol_detected 2>/dev/null; then
  PATROL_STATUS="connected"
fi
PATROL_ENABLED=$(remembrall_config "patrol_integration" "true")
if [ "$PATROL_ENABLED" = "true" ]; then
  EASTER_EGGS=$(remembrall_config "easter_eggs" "true")
  if [ "$EASTER_EGGS" = "true" ]; then
    echo "Patrol:   Ministry of Magic: Patrol ($PATROL_STATUS)"
  else
    echo "Patrol:   $PATROL_STATUS (integration enabled)"
  fi
else
  echo "Patrol:   Integration disabled"
fi

# Team handoffs (centralized — same dir as personal, distinguished by metadata)
TEAM_DIR=$(remembrall_team_handoff_dir "$CWD")
if [ -d "$TEAM_DIR" ]; then
  TEAM_COUNT=0
  for f in "$TEAM_DIR"/handoff-*.md; do
    [ -f "$f" ] || continue
    # Count only team-flagged handoffs
    _team_flag=$(remembrall_frontmatter_get "$f" "team" 2>/dev/null)
    [ "$_team_flag" = "true" ] && TEAM_COUNT=$((TEAM_COUNT + 1))
  done
  if [ "$TEAM_COUNT" -gt 0 ]; then
    echo "Team:     $TEAM_COUNT handoff(s)"
  else
    echo "Team:     No team handoffs"
  fi
else
  echo "Team:     No team handoffs"
fi
