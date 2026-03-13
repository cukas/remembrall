#!/usr/bin/env bash
# Transcript category breakdown — analyzes context budget allocation
# Runs in background below journal threshold when budget_enabled=true
# Output: JSON report to /tmp/remembrall-budget/{session_id}.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="budget-analyze"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq
[ "$(remembrall_config "budget_enabled" "false")" = "true" ] || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

[ -n "$SESSION_ID" ] || exit 0
[ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || exit 0

# Extract category bytes
CATEGORIES=$(remembrall_extract_category_bytes "$TRANSCRIPT_PATH")
CODE_BYTES=$(printf '%s' "$CATEGORIES" | cut -f1)
CONV_BYTES=$(printf '%s' "$CATEGORIES" | cut -f2)
MEM_BYTES=$(printf '%s' "$CATEGORIES" | cut -f3)

TOTAL=$((CODE_BYTES + CONV_BYTES + MEM_BYTES))
[ "$TOTAL" -gt 0 ] || exit 0

# Compute percentages
CODE_PCT=$((CODE_BYTES * 100 / TOTAL))
CONV_PCT=$((CONV_BYTES * 100 / TOTAL))
MEM_PCT=$((MEM_BYTES * 100 / TOTAL))

# Write budget report
BUDGET_DIR=$(remembrall_budget_dir)
mkdir -p "$BUDGET_DIR"
REPORT_FILE="$BUDGET_DIR/${SESSION_ID}.json"

# Get configured budgets
CFG_CODE=$(remembrall_config "budget_code" "50")
CFG_CONV=$(remembrall_config "budget_conversation" "30")
CFG_MEM=$(remembrall_config "budget_memory" "20")

# Detect warnings
WARNINGS="[]"
OVER_THRESHOLD=10
if [ $((CODE_PCT - CFG_CODE)) -gt "$OVER_THRESHOLD" ]; then
  WARNINGS=$(echo "$WARNINGS" | jq --arg cat "code" --argjson actual "$CODE_PCT" --argjson budget "$CFG_CODE" \
    '. += [{"category": $cat, "actual": $actual, "budget": $budget}]')
fi
if [ $((CONV_PCT - CFG_CONV)) -gt "$OVER_THRESHOLD" ]; then
  WARNINGS=$(echo "$WARNINGS" | jq --arg cat "conversation" --argjson actual "$CONV_PCT" --argjson budget "$CFG_CONV" \
    '. += [{"category": $cat, "actual": $actual, "budget": $budget}]')
fi
if [ $((MEM_PCT - CFG_MEM)) -gt "$OVER_THRESHOLD" ]; then
  WARNINGS=$(echo "$WARNINGS" | jq --arg cat "memory" --argjson actual "$MEM_PCT" --argjson budget "$CFG_MEM" \
    '. += [{"category": $cat, "actual": $actual, "budget": $budget}]')
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --arg ts "$NOW" \
  --arg sid "$SESSION_ID" \
  --argjson code_bytes "$CODE_BYTES" \
  --argjson conv_bytes "$CONV_BYTES" \
  --argjson mem_bytes "$MEM_BYTES" \
  --argjson total "$TOTAL" \
  --argjson code_pct "$CODE_PCT" \
  --argjson conversation_pct "$CONV_PCT" \
  --argjson memory_pct "$MEM_PCT" \
  --argjson cfg_code "$CFG_CODE" \
  --argjson cfg_conv "$CFG_CONV" \
  --argjson cfg_mem "$CFG_MEM" \
  --argjson warnings "$WARNINGS" \
  '{
    analyzed_at: $ts,
    session_id: $sid,
    bytes: {code: $code_bytes, conversation: $conv_bytes, memory: $mem_bytes, total: $total},
    code_pct: $code_pct,
    conversation_pct: $conversation_pct,
    memory_pct: $memory_pct,
    budget: {code: $cfg_code, conversation: $cfg_conv, memory: $cfg_mem},
    warnings: $warnings
  }' > "$REPORT_FILE" 2>/dev/null

_warn_count=$(echo "$WARNINGS" | jq 'length' 2>/dev/null || echo 0)
remembrall_debug "budget: code=${CODE_PCT}% conv=${CONV_PCT}% mem=${MEM_PCT}% (${_warn_count} warnings)"
