#!/usr/bin/env bash
# SessionStart hook: auto-configures bridge + injects handoff content on resume
# Only resumes own session's handoff — never picks up other sessions' handoffs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Exit if CWD not available
if [ -z "$CWD" ]; then
  exit 0
fi

# ── Layer 1: Auto-inject bridge into settings.json ────────────────
# On every session start, check if the bridge snippet exists.
# If missing, inject it so the status line writes context % to /tmp.
# Self-healing: if user removes it, next session re-injects.
_remembrall_ensure_bridge() {
  local settings_file="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude" 2>/dev/null
  [ -f "$settings_file" ] || echo '{}' > "$settings_file"

  # Already has bridge? Skip.
  if grep -q "claude-context-pct" "$settings_file" 2>/dev/null; then
    return 0
  fi

  # Check if there's a statusLine command to inject into
  local has_statusline
  has_statusline=$(jq -r '.statusLine.command // empty' "$settings_file" 2>/dev/null)
  if [ -z "$has_statusline" ]; then
    # No status line — create one with bridge built in
    local bridge_cmd='input=$(cat); session_id=$(echo "$input" | jq -r '"'"'.session_id // empty'"'"'); remaining=$(echo "$input" | jq -r '"'"'.context_remaining // empty'"'"'); CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null; if [ -n "$remaining" ]; then printf "%s" "$remaining" > "$CTX_DIR/${session_id}" 2>/dev/null; fi; echo "ctx: ${remaining:-?}%"'
    local tmp
    tmp=$(mktemp "${settings_file}.XXXXXX")
    jq --arg cmd "$bridge_cmd" '.statusLine.command = $cmd' "$settings_file" > "$tmp" 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$tmp" ]; then
      mv "$tmp" "$settings_file"
      echo "Remembrall: bridge status line created in settings.json" >&2
    else
      rm -f "$tmp"
    fi
    return 0
  fi

  # Check if session_id is already extracted in the status line
  local has_session_id=false
  if echo "$has_statusline" | grep -q 'session_id' 2>/dev/null; then
    has_session_id=true
  fi

  # Build the bridge snippet
  local bridge_snippet
  if [ "$has_session_id" = true ]; then
    # session_id already extracted — just add bridge write
    bridge_snippet='CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null; printf "%s" "$remaining" > "$CTX_DIR/${session_id}" 2>/dev/null;'
  else
    # Need to also extract session_id
    bridge_snippet='session_id=$(echo "$input" | jq -r '"'"'.session_id // empty'"'"'); CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null; printf "%s" "$remaining" > "$CTX_DIR/${session_id}" 2>/dev/null;'
  fi

  # Find the insertion point: end of the 'if [ -n "$remaining" ]' block
  # Strategy: append bridge snippet before the final 'fi; echo' or before 'echo "$status"'
  local new_command
  new_command=$(jq -r '.statusLine.command' "$settings_file" 2>/dev/null)

  # Check if there's a remaining check block we can append to
  if echo "$new_command" | grep -q 'remaining' 2>/dev/null; then
    # Insert bridge before the last 'fi;' that closes the remaining block
    # Use the pattern: find the last 'fi; echo "$status"' and insert before it
    new_command=$(printf '%s' "$new_command" | sed "s|; echo \"\\\$status\"|; ${bridge_snippet} echo \"\\\$status\"|")
  else
    # No remaining block — append bridge at the end (before echo "$status")
    new_command="${new_command}; ${bridge_snippet}"
  fi

  # Write back to settings.json atomically
  local tmp
  tmp=$(mktemp "${settings_file}.XXXXXX")
  jq --arg cmd "$new_command" '.statusLine.command = $cmd' "$settings_file" > "$tmp" 2>/dev/null
  if [ $? -eq 0 ] && [ -s "$tmp" ]; then
    mv "$tmp" "$settings_file"
    echo "Remembrall: bridge auto-configured in settings.json" >&2
  else
    rm -f "$tmp"
  fi
}

_remembrall_ensure_bridge

# For fresh session starts (not compact/clear): just exit
if [ "$SOURCE" != "compact" ] && [ "$SOURCE" != "clear" ]; then
  exit 0
fi

# Invalidate bridge — context just reset, old value is wrong
if [ -n "$SESSION_ID" ]; then
  rm -f "/tmp/claude-context-pct/$SESSION_ID" 2>/dev/null
fi

HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || exit 0

# No handoff directory — nothing to resume
if [ ! -d "$HANDOFF_DIR" ]; then
  exit 0
fi

# Clean up orphaned .claimed-PID files older than 5 minutes
for f in "$HANDOFF_DIR"/handoff-*.md.claimed-*; do
  [ -f "$f" ] || continue
  local_age=$(remembrall_file_age "$f")
  [ "$local_age" -gt 300 ] && rm -f "$f"
done

# Only resume own session's handoff — use /replay for other sessions' handoffs
HANDOFF_FILE=""
if [ -n "$SESSION_ID" ] && [ -f "$HANDOFF_DIR/handoff-${SESSION_ID}.md" ]; then
  HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
fi

# Recency fallback: if own-session handoff not found, check for one created
# in the last 60s. Handles /handoff with timestamp ID (CLAUDE_SESSION_ID unavailable).
# Verify frontmatter session_id matches to prevent claiming another session's handoff.
if [ -z "$HANDOFF_FILE" ]; then
  for f in "$HANDOFF_DIR"/handoff-*.md; do
    [ -f "$f" ] || continue
    local_age=$(remembrall_file_age "$f")
    if [ "$local_age" -lt 60 ]; then
      # If we have a session ID, verify the handoff's frontmatter matches
      if [ -n "$SESSION_ID" ]; then
        fm_sid=$(remembrall_frontmatter_get "$f" "session_id" 2>/dev/null)
        if [ -n "$fm_sid" ] && [ "$fm_sid" != "$SESSION_ID" ]; then
          continue  # belongs to another session
        fi
      fi
      HANDOFF_FILE="$f"
      break
    fi
  done
fi

# No handoff found
if [ -z "$HANDOFF_FILE" ] || [ ! -f "$HANDOFF_FILE" ]; then
  exit 0
fi

# Check age — skip stale handoffs (older than configured retention)
RETENTION_HOURS=$(remembrall_retention_hours)
RETENTION_SECS=$((RETENTION_HOURS * 3600))
FILE_AGE=$(remembrall_file_age "$HANDOFF_FILE")
if [ "$FILE_AGE" -gt "$RETENTION_SECS" ]; then
  rm -f "$HANDOFF_FILE"
  exit 0
fi

# Atomic claim: move before read to prevent TOCTOU race with concurrent sessions
CLAIMED_FILE="${HANDOFF_FILE}.claimed-$$"
mv "$HANDOFF_FILE" "$CLAIMED_FILE" 2>/dev/null || exit 0

# Read handoff content
CONTENT=$(cat "$CLAIMED_FILE")

# Extract frontmatter metadata if present
PATCH_PATH=$(remembrall_frontmatter_get "$CLAIMED_FILE" "patch")
FM_BRANCH=$(remembrall_frontmatter_get "$CLAIMED_FILE" "branch")
FM_COMMIT=$(remembrall_frontmatter_get "$CLAIMED_FILE" "commit")

GIT_CONTEXT=""
if [ -n "$PATCH_PATH" ] && [ -f "$PATCH_PATH" ]; then
  PATCH_LINES=$(wc -l < "$PATCH_PATH" | tr -d ' ')
  GIT_RAW="GIT STATE: Branch was '${FM_BRANCH}', commit was '${FM_COMMIT}'. A patch file exists at ${PATCH_PATH} (${PATCH_LINES} lines) with the session's uncommitted changes. Use /replay to verify and restore."
  GIT_CONTEXT="\\n\\n$(remembrall_escape_json "$GIT_RAW")"
fi

# Count other handoff files (for awareness) — using glob, not ls
OTHER_COUNT=0
OTHER_FILES=""
for f in "$HANDOFF_DIR"/handoff-*.md; do
  [ -f "$f" ] || continue
  OTHER_COUNT=$((OTHER_COUNT + 1))
  OTHER_FILES="$OTHER_FILES $f"
done

OTHER_NOTE=""
if [ "$OTHER_COUNT" -gt 0 ]; then
  OTHER_NOTE=" NOTE: There are $OTHER_COUNT other handoff file(s) from other sessions:$OTHER_FILES"
fi

# Escape content for JSON embedding using jq (RFC 8259 compliant)
ESCAPED_CONTENT=$(remembrall_escape_json "$CONTENT")
ESCAPED_NOTE=$(remembrall_escape_json "$OTHER_NOTE")

# Output using canonical hookSpecificOutput format
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "SESSION HANDOFF LOADED — Resume the work described below.\n\nRULES:\n1. Summarize briefly what was being worked on and what the NEXT STEP is.\n2. If a 'Next Step' or 'Remaining' section exists, follow it exactly.\n3. If a 'Do NOT Do' section exists, respect it strictly.\n4. Do NOT re-read or re-analyze files just because they appear in a file list — they are there for reference only.\n5. Ask the user if they want to continue before starting work.\n\n${ESCAPED_CONTENT}${GIT_CONTEXT}${ESCAPED_NOTE}"
  }
}
EOF

# Delete consumed handoff
rm -f "$CLAIMED_FILE"

# Clean up nudge temp files for this session
if [ -n "$SESSION_ID" ]; then
  rm -f "/tmp/remembrall-nudges/$SESSION_ID"
fi

exit 0
