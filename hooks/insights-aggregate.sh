#!/usr/bin/env bash
# Aggregates Pensieve sessions into patterns (file hotspots, workflow patterns, error recurrence)
# Runs in background on SessionStart when insights are enabled
# Usage: bash hooks/insights-aggregate.sh CWD

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="insights-aggregate"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq
[ "$(remembrall_config "insights" "true")" = "true" ] || exit 0

CWD="${1:-.}"

# Skip if insights are fresh (< 1 hour old)
if remembrall_insights_fresh "$CWD" 2>/dev/null; then
  remembrall_debug "insights fresh, skipping aggregation"
  exit 0
fi

PENSIEVE_DIR=$(remembrall_pensieve_dir "$CWD" 2>/dev/null) || exit 0
[ -d "$PENSIEVE_DIR" ] || exit 0

# Count available sessions
SESSION_COUNT=0
for f in "$PENSIEVE_DIR"/session-*.json; do
  [ -f "$f" ] && SESSION_COUNT=$((SESSION_COUNT + 1))
done

MIN_SESSIONS=$(remembrall_config "insights_min_sessions" "3")
if [ "$SESSION_COUNT" -lt "$MIN_SESSIONS" ]; then
  remembrall_debug "insights: only $SESSION_COUNT sessions (need $MIN_SESSIONS)"
  exit 0
fi

INSIGHTS_DIR=$(remembrall_insights_dir "$CWD")
mkdir -p "$INSIGHTS_DIR"
INSIGHTS_FILE="$INSIGHTS_DIR/insights.json"

# ── Aggregate file hotspots ──────────────────────────────────────
# Files that appear in multiple sessions = hotspots
FILE_HOTSPOTS=$(jq -s '
  [.[] | .files // {} | keys[]] |
  group_by(.) |
  map({file: .[0], sessions: length}) |
  sort_by(-.sessions) |
  .[0:20]
' "$PENSIEVE_DIR"/session-*.json 2>/dev/null) || FILE_HOTSPOTS="[]"

# ── Aggregate workflow patterns ──────────────────────────────────
# Detect test-before-commit, error-fix cycles, etc.
WORKFLOW_PATTERNS=$(jq -s '
  [.[] | .patterns // {} |
    if .test_fix_cycles and (.test_fix_cycles | length) > 0 then
      {pattern: "test-fix-cycle", count: (.test_fix_cycles | length)}
    else empty end
  ] |
  group_by(.pattern) |
  map({pattern: .[0].pattern, total: (map(.count) | add)}) |
  sort_by(-.total)
' "$PENSIEVE_DIR"/session-*.json 2>/dev/null) || WORKFLOW_PATTERNS="[]"

# ── Aggregate error recurrence ───────────────────────────────────
# Errors that appear in multiple sessions
ERROR_RECURRENCE=$(jq -s '
  [.[] | .errors // [] | .[]] |
  map(.[0:100]) |
  group_by(.) |
  map({error: .[0], sessions: length}) |
  sort_by(-.sessions) |
  map(select(.sessions > 1)) |
  .[0:10]
' "$PENSIEVE_DIR"/session-*.json 2>/dev/null) || ERROR_RECURRENCE="[]"

# ── Session stats ────────────────────────────────────────────────
SESSION_STATS=$(jq -s '
  {
    total_sessions: length,
    avg_files_per_session: ([.[] | (.files // {} | keys | length)] | if length > 0 then (add / length | floor) else 0 end),
    avg_commands_per_session: ([.[] | (.commands // [] | length)] | if length > 0 then (add / length | floor) else 0 end),
    avg_errors_per_session: ([.[] | (.errors // [] | length)] | if length > 0 then (add / length | floor) else 0 end)
  }
' "$PENSIEVE_DIR"/session-*.json 2>/dev/null) || SESSION_STATS='{}'

# ── Write insights ───────────────────────────────────────────────
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TMP=$(mktemp "${INSIGHTS_FILE}.XXXXXX")
jq -n \
  --arg ts "$NOW" \
  --argjson sessions "$SESSION_COUNT" \
  --argjson hotspots "$FILE_HOTSPOTS" \
  --argjson patterns "$WORKFLOW_PATTERNS" \
  --argjson errors "$ERROR_RECURRENCE" \
  --argjson stats "$SESSION_STATS" \
  '{
    version: 1,
    aggregated_at: $ts,
    sessions_analyzed: $sessions,
    file_hotspots: $hotspots,
    workflow_patterns: $patterns,
    error_recurrence: $errors,
    session_stats: $stats
  }' > "$TMP" 2>/dev/null

if [ -s "$TMP" ]; then
  mv "$TMP" "$INSIGHTS_FILE"
  remembrall_debug "insights aggregated: $SESSION_COUNT sessions → $INSIGHTS_FILE"
else
  rm -f "$TMP"
fi
