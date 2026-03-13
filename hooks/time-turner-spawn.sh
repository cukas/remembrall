#!/usr/bin/env bash
# time-turner-spawn.sh — Spawn a parallel claude -p agent in a git worktree
# when context is low. Called by context-monitor.sh.
#
# Usage: echo "$INPUT" | time-turner-spawn.sh
# Input JSON on stdin: {session_id, cwd, transcript_path}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="time-turner-spawn"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

# ─── Read stdin JSON ───────────────────────────────────────────────
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
# shellcheck disable=SC2034  # parsed from input contract; may be used by future callers
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

# ─── Precondition: session and cwd must be present ────────────────
if [ -z "$SESSION_ID" ] || [ -z "$CWD" ]; then
  remembrall_debug "time-turner-spawn: missing session_id or cwd — skipping"
  exit 0
fi

# ─── Precondition: time_turner config must be enabled ─────────────
if [ "$(remembrall_config "time_turner" "false")" != "true" ]; then
  remembrall_debug "time-turner-spawn: time_turner config is false — skipping"
  exit 0
fi

# ─── Precondition: CWD must be a git repo ─────────────────────────
if ! git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  remembrall_debug "time-turner-spawn: $CWD is not a git repo — skipping"
  exit 0
fi

# ─── Precondition: not already spawned (atomic mkdir as lock) ─────
STATE_DIR="/tmp/remembrall-timeturner/${SESSION_ID}"
STATUS_FILE="$STATE_DIR/status"

mkdir -p "/tmp/remembrall-timeturner" 2>/dev/null
if ! mkdir "$STATE_DIR" 2>/dev/null; then
  remembrall_debug "time-turner-spawn: already spawned for session=$SESSION_ID — skipping"
  exit 0
fi

remembrall_debug "time-turner-spawn: spawning for session=$SESSION_ID cwd=$CWD"
echo "preparing" > "$STATUS_FILE"

# ─── Get config ───────────────────────────────────────────────────
MODEL=$(remembrall_config "time_turner_model" "sonnet")
MAX_BUDGET=$(remembrall_config "time_turner_max_budget_usd" "1.00")

# Store project path so cleanup can target the right repo
printf '%s\n' "$CWD" > "$STATE_DIR/project_path"

# ─── Create git worktree ──────────────────────────────────────────
WORKTREE="$STATE_DIR/worktree"
BRANCH="timeturner/${SESSION_ID}"

if ! git -C "$CWD" worktree add "$WORKTREE" -b "$BRANCH" HEAD 2>/dev/null; then
  remembrall_debug "time-turner-spawn: git worktree add failed"
  echo "failed" > "$STATUS_FILE"
  exit 0
fi

# ─── Build prompt ─────────────────────────────────────────────────
PENSIEVE_SECTION=""
PENSIEVE_OUT=$("$SCRIPT_DIR/pensieve-distill.sh" "$SESSION_ID" "$CWD" 2>/dev/null) || PENSIEVE_OUT=""
if [ -n "$PENSIEVE_OUT" ]; then
  PENSIEVE_SECTION="## Session Activity (Pensieve distillation)

\`\`\`json
${PENSIEVE_OUT}
\`\`\`

"
fi

HANDOFF_SECTION=""
HANDOFF_DIR=$(remembrall_handoff_dir "$CWD" 2>/dev/null) || HANDOFF_DIR=""
if [ -n "$HANDOFF_DIR" ]; then
  # Find the latest handoff file for this session or the most recent one
  HANDOFF_FILE=""
  if [ -f "$HANDOFF_DIR/handoff-${SESSION_ID}.md" ]; then
    HANDOFF_FILE="$HANDOFF_DIR/handoff-${SESSION_ID}.md"
  else
    # Fall back to most recently modified handoff file (safe with spaces in paths)
    HANDOFF_FILE=$(
      for f in "$HANDOFF_DIR"/handoff-*.md; do
        [ -f "$f" ] || continue
        printf '%s\t%s\n' "$(remembrall_file_age "$f")" "$f"
      done | sort -n | head -1 | cut -f2
    ) || HANDOFF_FILE=""
  fi

  if [ -n "$HANDOFF_FILE" ] && [ -f "$HANDOFF_FILE" ]; then
    HANDOFF_CONTENT=$(cat "$HANDOFF_FILE" 2>/dev/null) || HANDOFF_CONTENT=""
    if [ -n "$HANDOFF_CONTENT" ]; then
      HANDOFF_SECTION="## Latest Handoff

${HANDOFF_CONTENT}

"
    fi
  fi
fi

SCOPE_INSTRUCTION="You are a Time-Turner agent. ONLY work on the remaining tasks listed below. Do NOT modify files outside the task scope. Do NOT install new dependencies. Do NOT run destructive git commands."

PROMPT="${SCOPE_INSTRUCTION}

${PENSIEVE_SECTION}${HANDOFF_SECTION}Please review the above context and continue working on the remaining tasks. Commit your progress when done."

# ─── Spawn claude in background ───────────────────────────────────
(
  cd "$WORKTREE"
  unset CLAUDECODE 2>/dev/null || true

  if claude -p "$PROMPT" \
    --output-format json \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    --max-budget-usd "$MAX_BUDGET" \
    > "$STATE_DIR/result.json" 2>"$STATE_DIR/error.log"; then

    # Post-run: capture diff stats
    git diff --stat HEAD > "$STATE_DIR/diff-summary.txt" 2>/dev/null || true
    FILES_CHANGED=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')
    printf '%s\n' "$FILES_CHANGED" > "$STATE_DIR/files_changed"
    printf 'completed\n' > "$STATE_DIR/status"
  else
    EXIT_CODE=$?
    remembrall_debug "time-turner-spawn: claude exited with code $EXIT_CODE"
    printf 'failed\n' > "$STATE_DIR/status"
  fi

  printf '%s\n' "$(date +%s)" > "$STATE_DIR/finished"
) &

CHILD_PID=$!

# ─── Write PID and timestamps ─────────────────────────────────────
printf '%s\n' "$CHILD_PID" > "$STATE_DIR/pid"
printf '%s\n' "$(date +%s)" > "$STATE_DIR/started"
printf 'running\n' > "$STATE_DIR/status"

remembrall_debug "time-turner-spawn: spawned pid=$CHILD_PID session=$SESSION_ID worktree=$WORKTREE"

exit 0
