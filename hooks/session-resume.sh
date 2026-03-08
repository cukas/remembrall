#!/usr/bin/env bash
# SessionStart hook: auto-configures bridge + injects handoff content on resume
# Only resumes own session's handoff — never picks up other sessions' handoffs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="session-resume"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq
remembrall_hook_enabled "session-resume" || exit 0

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

remembrall_debug "source=${SOURCE} session_id=${SESSION_ID} cwd=${CWD}"

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

  # Backup settings.json before mutation — safety net in case jq produces invalid output
  cp "$settings_file" "${settings_file}.remembrall-backup" 2>/dev/null || true

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
      remembrall_debug "bridge status line created in settings.json"
      echo "Remembrall: bridge status line created in settings.json" >&2
    else
      rm -f "$tmp"
    fi
    return 0
  fi

  # Defensive check: if another plugin owns the status line command and it
  # doesn't reference standard variables (remaining, context_remaining),
  # log a warning and skip — don't clobber another plugin's status line.
  if ! echo "$has_statusline" | grep -qE '(remaining|context_remaining)' 2>/dev/null; then
    remembrall_debug "WARNING: statusLine.command exists but doesn't reference context variables — another plugin may own it. Appending bridge with care."
    echo "Remembrall: existing statusLine detected — appending bridge (won't overwrite)" >&2
  fi

  # Check if session_id is already extracted in the status line
  local has_session_id=false
  if echo "$has_statusline" | grep -q 'session_id' 2>/dev/null; then
    has_session_id=true
  fi

  # Build the bridge snippet
  local bridge_snippet
  if [ "$has_session_id" = true ]; then
    bridge_snippet='CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null; printf "%s" "$remaining" > "$CTX_DIR/${session_id}" 2>/dev/null;'
  else
    bridge_snippet='session_id=$(echo "$input" | jq -r '"'"'.session_id // empty'"'"'); CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null; printf "%s" "$remaining" > "$CTX_DIR/${session_id}" 2>/dev/null;'
  fi

  # Append bridge snippet to existing command (simple, safe string concatenation)
  local new_command
  new_command=$(jq -r '.statusLine.command' "$settings_file" 2>/dev/null)
  new_command="${new_command}; ${bridge_snippet}"

  # Write back to settings.json atomically
  local tmp
  tmp=$(mktemp "${settings_file}.XXXXXX")
  jq --arg cmd "$new_command" '.statusLine.command = $cmd' "$settings_file" > "$tmp" 2>/dev/null
  if [ $? -eq 0 ] && [ -s "$tmp" ]; then
    mv "$tmp" "$settings_file"
    remembrall_debug "bridge auto-configured in settings.json"
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

# Clean up orphaned .claimed-PID and .consumed files
for f in "$HANDOFF_DIR"/handoff-*.md.claimed-* "$HANDOFF_DIR"/handoff-*.consumed.md; do
  [ -f "$f" ] || continue
  _age=$(remembrall_file_age "$f")
  # claimed files: 5 min; consumed files: 1 hour
  case "$f" in
    *.claimed-*) [ "$_age" -gt 300 ] && rm -f "$f" ;;
    *.consumed*) [ "$_age" -gt 3600 ] && rm -f "$f" ;;
  esac
done

# Only resume own session's handoff — use /replay for other sessions' handoffs
HANDOFF_FILE=""
if [ -n "$SESSION_ID" ] && [ -f "$HANDOFF_DIR/handoff-${SESSION_ID}.md" ]; then
  HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
fi

# Recency fallback: if own-session handoff not found, check for one created
# within the recency window. Handles /handoff with timestamp ID (CLAUDE_SESSION_ID unavailable).
# Verify frontmatter session_id matches to prevent claiming another session's handoff.
RECENCY_WINDOW=$(remembrall_config "recency_window" "60" 2>/dev/null)
[[ "$RECENCY_WINDOW" =~ ^[0-9]+$ ]] || RECENCY_WINDOW=60
if [ -z "$HANDOFF_FILE" ]; then
  for f in "$HANDOFF_DIR"/handoff-*.md; do
    [ -f "$f" ] || continue
    _age=$(remembrall_file_age "$f")
    if [ "$_age" -lt "$RECENCY_WINDOW" ]; then
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
remembrall_debug "claiming handoff: $(basename "$HANDOFF_FILE")"
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

# Rename consumed handoff (preserved for safety; cleaned up after 1 hour)
mv "$CLAIMED_FILE" "${HANDOFF_FILE%.md}.consumed.md" 2>/dev/null || rm -f "$CLAIMED_FILE"

# Clean up nudge temp files for this session
if [ -n "$SESSION_ID" ]; then
  rm -f "/tmp/remembrall-nudges/$SESSION_ID"
  rm -f "/tmp/remembrall-growth/$SESSION_ID"
fi

exit 0
