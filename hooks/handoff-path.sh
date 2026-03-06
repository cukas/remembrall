#!/usr/bin/env bash
# Helper: outputs the full handoff file path for the current session.
# Used by the /handoff skill to reduce fragile multi-step bash in instructions.
# Usage: HANDOFF_PATH=$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/handoff-path.sh")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CWD="${1:-$(pwd)}"

# Session ID priority: env var > published by hook > timestamp fallback
PUBLISHED_SESSION=$(remembrall_read_session_id "$CWD" 2>/dev/null || echo "")
SESSION_ID="${CLAUDE_SESSION_ID:-${PUBLISHED_SESSION:-}}"

if [ -z "$SESSION_ID" ]; then
  SESSION_ID="$(date +%s)"
  echo "Warning: Could not determine session ID. Auto-resume after /clear will NOT find this handoff — use /replay manually." >&2
fi

HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || { echo "Error: could not compute handoff directory" >&2; exit 1; }
mkdir -p "$HANDOFF_DIR"

echo "$HANDOFF_DIR/handoff-${SESSION_ID}.md"

# If team handoffs enabled, also create team directory and report path
if remembrall_team_enabled; then
  TEAM_DIR=$(remembrall_team_handoff_dir "$CWD")
  mkdir -p "$TEAM_DIR"
  echo "team:$TEAM_DIR/handoff-${SESSION_ID}.md" >&2
fi
