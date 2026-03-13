#!/usr/bin/env bash
# Renders formatted insights for a project
# Usage: bash scripts/remembrall-insights.sh [cwd]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib.sh"

remembrall_require_jq

CWD="${1:-$(pwd)}"

# ─── ANSI helpers ─────────────────────────────────────────────────
CYAN='\033[36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

EASTER_EGGS=$(remembrall_config "easter_eggs" "true")

if [ "$EASTER_EGGS" = "true" ]; then
  printf '%b\n' "${BOLD}The Pensieve Remembers${RESET}"
else
  printf '%b\n' "${BOLD}Project Insights${RESET}"
fi
echo "══════════════════════════"
echo ""

INSIGHTS_DIR=$(remembrall_insights_dir "$CWD")
INSIGHTS_FILE="$INSIGHTS_DIR/insights.json"

if [ ! -f "$INSIGHTS_FILE" ]; then
  MIN_SESSIONS=$(remembrall_config "insights_min_sessions" "3")
  echo "No insights yet. Need at least $MIN_SESSIONS sessions to generate insights."
  echo "Insights are aggregated automatically on session start."
  exit 0
fi

# ── Session Stats ────────────────────────────────────────────────
SESSIONS=$(jq -r '.sessions_analyzed // 0' "$INSIGHTS_FILE" 2>/dev/null)
AGG_AT=$(jq -r '.aggregated_at // "unknown"' "$INSIGHTS_FILE" 2>/dev/null)
printf 'Based on %b%d sessions%b (last aggregated: %s)\n' "$BOLD" "$SESSIONS" "$RESET" "$AGG_AT"
echo ""

STATS=$(jq -r '.session_stats // {}' "$INSIGHTS_FILE" 2>/dev/null)
if [ -n "$STATS" ] && [ "$STATS" != "{}" ]; then
  AVG_FILES=$(echo "$STATS" | jq -r '.avg_files_per_session // 0')
  AVG_CMDS=$(echo "$STATS" | jq -r '.avg_commands_per_session // 0')
  AVG_ERRORS=$(echo "$STATS" | jq -r '.avg_errors_per_session // 0')
  printf 'Averages: %b%d files%b, %b%d commands%b, %b%d errors%b per session\n' \
    "$CYAN" "$AVG_FILES" "$RESET" "$CYAN" "$AVG_CMDS" "$RESET" "$CYAN" "$AVG_ERRORS" "$RESET"
  echo ""
fi

# ── File Hotspots ────────────────────────────────────────────────
HOTSPOT_COUNT=$(jq '.file_hotspots | length' "$INSIGHTS_FILE" 2>/dev/null) || HOTSPOT_COUNT=0
if [ "$HOTSPOT_COUNT" -gt 0 ]; then
  if [ "$EASTER_EGGS" = "true" ]; then
    printf '%b\n' "${BOLD}File Hotspots${RESET} ${DIM}(These files keep appearing in the Pensieve's memories...)${RESET}"
  else
    printf '%b\n' "${BOLD}File Hotspots${RESET}"
  fi
  jq -r '.file_hotspots[:10][] | "  \(.file) (\(.sessions) sessions)"' "$INSIGHTS_FILE" 2>/dev/null
  echo ""
fi

# ── Workflow Patterns ────────────────────────────────────────────
PATTERN_COUNT=$(jq '.workflow_patterns | length' "$INSIGHTS_FILE" 2>/dev/null) || PATTERN_COUNT=0
if [ "$PATTERN_COUNT" -gt 0 ]; then
  printf '%b\n' "${BOLD}Workflow Patterns${RESET}"
  jq -r '.workflow_patterns[] | "  \(.pattern): \(.total) occurrences"' "$INSIGHTS_FILE" 2>/dev/null
  echo ""
fi

# ── Error Recurrence ─────────────────────────────────────────────
ERROR_COUNT=$(jq '.error_recurrence | length' "$INSIGHTS_FILE" 2>/dev/null) || ERROR_COUNT=0
if [ "$ERROR_COUNT" -gt 0 ]; then
  printf '%b%b\n' "${BOLD}" "Recurring Errors${RESET}"
  jq -r '.error_recurrence[:5][] | "  \(.error[:80]) (\(.sessions) sessions)"' "$INSIGHTS_FILE" 2>/dev/null
  echo ""
fi

if [ "$HOTSPOT_COUNT" -eq 0 ] && [ "$PATTERN_COUNT" -eq 0 ] && [ "$ERROR_COUNT" -eq 0 ]; then
  echo "No significant patterns detected yet. Keep working and insights will emerge."
fi
