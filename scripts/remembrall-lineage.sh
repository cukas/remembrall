#!/usr/bin/env bash
# Renders a text DAG of session lineage for a project
# Usage: bash scripts/remembrall-lineage.sh [cwd]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib.sh"

remembrall_require_jq

CWD="${1:-$(pwd)}"

LINEAGE_DIR=$(remembrall_lineage_dir "$CWD")
INDEX="$LINEAGE_DIR/index.json"

# ─── ANSI helpers ─────────────────────────────────────────────────
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

EASTER_EGGS=$(remembrall_config "easter_eggs" "true")

if [ "$EASTER_EGGS" = "true" ]; then
  printf '%b\n' "${BOLD}Marauder's Map — Session Ancestry${RESET}"
else
  printf '%b\n' "${BOLD}Session Lineage${RESET}"
fi
echo "══════════════════════════════════"
echo ""

if [ ! -f "$INDEX" ]; then
  echo "No lineage data yet. Sessions will be recorded as you work."
  exit 0
fi

SESSION_COUNT=$(jq '.sessions | length' "$INDEX" 2>/dev/null) || SESSION_COUNT=0
if [ "$SESSION_COUNT" -eq 0 ]; then
  echo "No sessions recorded yet."
  exit 0
fi

BRANCH_COUNT=$(remembrall_lineage_branches "$CWD")

printf 'Sessions: %d' "$SESSION_COUNT"
if [ "$BRANCH_COUNT" -gt 0 ] && [ "$EASTER_EGGS" = "true" ]; then
  printf '  (%b%d Horcrux detected%b — sessions sharing parents)' "$YELLOW" "$BRANCH_COUNT" "$RESET"
elif [ "$BRANCH_COUNT" -gt 0 ]; then
  printf '  (%d branching points)' "$BRANCH_COUNT"
fi
echo ""
echo ""

# Render DAG: root sessions first, then children indented
# Find root sessions (no parent_id or parent_id is empty)
ROOTS=$(jq -r '.sessions[] | select(.parent_id == "" or .parent_id == null) | .session_id' "$INDEX" 2>/dev/null) || ROOTS=""

_render_session() {
  local sid="$1"
  local indent="$2"
  local depth="${3:-0}"

  # Depth guard: prevent infinite recursion on corrupt/cyclic data
  [ "$depth" -gt 50 ] && return

  local entry
  entry=$(jq --arg sid "$sid" '.sessions[] | select(.session_id == $sid)' "$INDEX" 2>/dev/null) || return

  local type status goal ts files_touched
  type=$(echo "$entry" | jq -r '.type // "normal"')
  status=$(echo "$entry" | jq -r '.status // "unknown"')
  goal=$(echo "$entry" | jq -r '.goal // ""' | cut -c1-60)
  ts=$(echo "$entry" | jq -r '.timestamp // ""')
  files_touched=$(echo "$entry" | jq -r '.files_touched // 0')

  # Format status with color
  local status_color="$RESET"
  case "$status" in
    active|completed|merged) status_color="$GREEN" ;;
    interrupted) status_color="$YELLOW" ;;
  esac

  # Type icon
  local type_icon=""
  case "$type" in
    time-turner) type_icon="[TT] " ;;
    normal) type_icon="" ;;
    *) type_icon="[$type] " ;;
  esac

  # Short session ID
  local short_sid="${sid:0:12}"
  [ "${#sid}" -gt 12 ] && short_sid="${short_sid}..."

  printf '%s' "$indent"
  if [ -n "$indent" ]; then
    printf '%b|-%b ' "$DIM" "$RESET"
  fi
  printf '%b%s%s%b %b[%s]%b' "$CYAN" "$type_icon" "$short_sid" "$RESET" "$status_color" "$status" "$RESET"
  if [ -n "$goal" ]; then
    printf ' %b%s%b' "$DIM" "$goal" "$RESET"
  fi
  printf ' (%d files)' "$files_touched"
  echo ""

  # Render children
  local children
  children=$(jq -r --arg sid "$sid" '.sessions[] | select(.parent_id == $sid) | .session_id' "$INDEX" 2>/dev/null) || children=""
  while IFS= read -r child_sid; do
    [ -z "$child_sid" ] && continue
    _render_session "$child_sid" "${indent}  " "$((depth + 1))"
  done <<< "$children"
}

# Render from roots
while IFS= read -r root_sid; do
  [ -z "$root_sid" ] && continue
  _render_session "$root_sid" "" 0
done <<< "$ROOTS"

# Render orphans (sessions with parent_id that doesn't exist in the index)
ORPHANS=$(jq -r '
  (.sessions | map(.session_id)) as $all_ids |
  .sessions[] |
  select(.parent_id != "" and .parent_id != null) |
  select([.parent_id] - $all_ids | length > 0) |
  .session_id
' "$INDEX" 2>/dev/null) || ORPHANS=""

if [ -n "$ORPHANS" ]; then
  echo ""
  printf '%b(orphaned sessions — parent not in index)%b\n' "$DIM" "$RESET"
  while IFS= read -r orphan_sid; do
    [ -z "$orphan_sid" ] && continue
    _render_session "$orphan_sid" ""
  done <<< "$ORPHANS"
fi
