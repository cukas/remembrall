#!/usr/bin/env bash
# Memory staleness analyzer — runs in background at journal threshold
# Analyzes memory files and cross-references with Pensieve data
# Output: JSON report to /tmp/remembrall-obliviate/{session_id}.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="obliviate-analyze"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq
[ "$(remembrall_config "obliviate" "true")" = "true" ] || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -n "$SESSION_ID" ] || exit 0
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 0
[ -n "$CWD" ] || exit 0

PENSIEVE_DIR=$(remembrall_pensieve_dir "$CWD" 2>/dev/null) || PENSIEVE_DIR=""

# Analyze memory staleness
ANALYSIS=$(remembrall_analyze_memory_staleness "$CWD" "$PENSIEVE_DIR")

# Count stale memories
STALE_COUNT=$(echo "$ANALYSIS" | jq '[.[] | select(.stale == true)] | length' 2>/dev/null) || STALE_COUNT=0

if [ "$STALE_COUNT" -eq 0 ]; then
  remembrall_debug "obliviate: no stale memories found"
  exit 0
fi

# Write analysis to temp dir
OBLIVIATE_DIR=$(remembrall_obliviate_dir)
mkdir -p "$OBLIVIATE_DIR"
REPORT_FILE="$OBLIVIATE_DIR/${SESSION_ID}.json"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TMP_REPORT=$(mktemp "${REPORT_FILE}.XXXXXX")
jq -n \
  --arg ts "$NOW" \
  --arg sid "$SESSION_ID" \
  --argjson stale "$STALE_COUNT" \
  --argjson analysis "$ANALYSIS" \
  '{
    analyzed_at: $ts,
    session_id: $sid,
    stale_count: $stale,
    memories: $analysis
  }' > "$TMP_REPORT" 2>/dev/null
if [ -s "$TMP_REPORT" ]; then
  mv "$TMP_REPORT" "$REPORT_FILE"
else
  rm -f "$TMP_REPORT"
fi

remembrall_debug "obliviate: found $STALE_COUNT stale memories"
