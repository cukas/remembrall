#!/usr/bin/env bash
# Records a session in the lineage index
# Called by precompact-handoff.sh and handoff-create.sh after writing handoff
# Input: JSON on stdin with session_id, cwd, parent_session, type, status, goal, files_count

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="lineage-record"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq
[ "$(remembrall_config "lineage" "true")" = "true" ] || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PARENT_ID=$(echo "$INPUT" | jq -r '.parent_id // empty')
TYPE=$(echo "$INPUT" | jq -r '.type // "normal"')
STATUS=$(echo "$INPUT" | jq -r '.status // "active"')
GOAL=$(echo "$INPUT" | jq -r '.goal // empty')
FILES_COUNT=$(echo "$INPUT" | jq -r '.files_count // 0')

if [ -z "$SESSION_ID" ] || [ -z "$CWD" ]; then
  exit 0
fi

remembrall_lineage_record "$SESSION_ID" "$PARENT_ID" "$CWD" "$TYPE" "$STATUS" "$GOAL" "$FILES_COUNT"
remembrall_debug "lineage recorded: session=$SESSION_ID parent=$PARENT_ID type=$TYPE"
