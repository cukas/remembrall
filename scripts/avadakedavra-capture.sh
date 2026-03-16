#!/usr/bin/env bash
# avadakedavra-capture.sh — Fast session state capture for Avada Kedavra
# Captures full context so SessionResume can inject it into the new session.
# Must complete in <2 seconds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="avadakedavra"
source "$SCRIPT_DIR/../hooks/lib.sh"

remembrall_require_jq

# ─── Parse arguments ─────────────────────────────────────────────
CWD=""
SESSION_ID_ARG=""
TRIGGER="avadakedavra"
CYCLE=""
CHAIN_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)        CWD="$2"; shift 2 ;;
    --session-id) SESSION_ID_ARG="$2"; shift 2 ;;
    --trigger)    TRIGGER="$2"; shift 2 ;;
    --cycle)      CYCLE="$2"; shift 2 ;;
    --chain-id)   CHAIN_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CWD="${CWD:-$(pwd)}"
PUBLISHED_SESSION=$(remembrall_read_session_id "$CWD" 2>/dev/null || echo "")
SESSION_ID="${SESSION_ID_ARG:-${CLAUDE_SESSION_ID:-${PUBLISHED_SESSION:-$(date +%s)}}}"

# ─── Create AK marker (tells SessionResume to use AK flow) ───────
AK_DIR="/tmp/remembrall-avadakedavra"
mkdir -p "$AK_DIR"
AK_FILE="$AK_DIR/$SESSION_ID"

# ─── Gather state fast ───────────────────────────────────────────

# Git state
BRANCH=""
COMMIT=""
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")
  COMMIT=$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "")
fi

# Pensieve distillation (fast summary of session activity)
PENSIEVE=""
if [ -f "$SCRIPT_DIR/../hooks/pensieve-distill.sh" ]; then
  PENSIEVE=$("$SCRIPT_DIR/../hooks/pensieve-distill.sh" "$SESSION_ID" "$CWD" 2>/dev/null) || PENSIEVE=""
fi

# Latest handoff if exists (reuse existing state)
HANDOFF_CONTENT=""
HANDOFF_DIR=$(remembrall_handoff_dir "$CWD" 2>/dev/null) || HANDOFF_DIR=""
if [ -n "$HANDOFF_DIR" ]; then
  LATEST=$(remembrall_latest_handoff_file "$HANDOFF_DIR" 2>/dev/null) || LATEST=""
  if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then
    HANDOFF_CONTENT=$(cat "$LATEST" 2>/dev/null) || HANDOFF_CONTENT=""
  fi
fi

# ─── Write AK briefing ──────────────────────────────────────────
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
  echo "---"
  jq -n \
    --arg created "$NOW" \
    --arg session_id "$SESSION_ID" \
    --arg project "$CWD" \
    --arg branch "$BRANCH" \
    --arg commit "$COMMIT" \
    --arg trigger "$TRIGGER" \
    --arg cycle "${CYCLE:-}" \
    --arg chain_id "${CHAIN_ID:-}" \
    '{
      created: $created,
      session_id: $session_id,
      project: $project,
      branch: $branch,
      commit: $commit,
      trigger: $trigger
    }
    | if $cycle != "" then . + {cycle: ($cycle | tonumber)} else . end
    | if $chain_id != "" then . + {chain_id: $chain_id} else . end'
  echo "---"
  echo ""

  if [ -n "$HANDOFF_CONTENT" ]; then
    echo "## Previous Handoff State"
    echo ""
    printf '%s\n' "$HANDOFF_CONTENT"
    echo ""
  fi

  if [ -n "$PENSIEVE" ]; then
    echo "## Session Intelligence (Pensieve)"
    echo ""
    echo '```json'
    printf '%s\n' "$PENSIEVE"
    echo '```'
  fi
} > "$AK_FILE"

remembrall_debug "avadakedavra: captured state for session=$SESSION_ID → $AK_FILE"

# Also create a handoff so session-resume's normal flow can find it
echo "$HANDOFF_CONTENT" | bash "$SCRIPT_DIR/handoff-create.sh" \
  --cwd "$CWD" \
  --session-id "$SESSION_ID" \
  --status "avadakedavra" 2>/dev/null || true

echo "$AK_FILE"
