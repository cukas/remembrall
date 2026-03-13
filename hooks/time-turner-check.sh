#!/usr/bin/env bash
# time-turner-check.sh — Check Time-Turner status and format a report for injection.
#
# Usage: time-turner-check.sh <cwd>
# Output: Status text on stdout
# Exit 1 if no Time-Turner active

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="time-turner-check"
source "$SCRIPT_DIR/lib.sh"

CWD="${1:-}"

# ─── Scan for active Time-Turner state dirs ───────────────────────
TIMETURNER_BASE="/tmp/remembrall-timeturner"

if [ ! -d "$TIMETURNER_BASE" ]; then
  exit 1
fi

FOUND=0
NOW=$(date +%s)

for STATUS_FILE in "$TIMETURNER_BASE"/*/status; do
  [ -f "$STATUS_FILE" ] || continue

  STATE_DIR="$(dirname "$STATUS_FILE")"
  SESSION_ID="$(basename "$STATE_DIR")"

  STATUS=$(cat "$STATUS_FILE" 2>/dev/null) || STATUS="unknown"
  STARTED=$(cat "$STATE_DIR/started" 2>/dev/null) || STARTED=""
  FINISHED=$(cat "$STATE_DIR/finished" 2>/dev/null) || FINISHED=""
  PID=$(cat "$STATE_DIR/pid" 2>/dev/null) || PID=""
  FILES_CHANGED=$(cat "$STATE_DIR/files_changed" 2>/dev/null) || FILES_CHANGED="0"

  # ── Auto-cleanup: remove if started > 24h ago ─────────────────
  if [ -n "$STARTED" ] && [ "$STARTED" -gt 0 ] 2>/dev/null; then
    AGE=$(( NOW - STARTED ))
    if [ "$AGE" -gt 86400 ]; then
      remembrall_debug "time-turner-check: auto-cleaning stale session=$SESSION_ID (age=${AGE}s)"
      WORKTREE="$STATE_DIR/worktree"
      # Use stored project path to target the correct repo
      TT_PROJECT=$(cat "$STATE_DIR/project_path" 2>/dev/null) || TT_PROJECT="$CWD"
      if [ -d "$WORKTREE" ] && [ -n "$TT_PROJECT" ]; then
        git -C "$TT_PROJECT" worktree remove --force "$WORKTREE" 2>/dev/null || true
        git -C "$TT_PROJECT" branch -D "timeturner/${SESSION_ID}" 2>/dev/null || true
      fi
      rm -rf "$STATE_DIR" 2>/dev/null || true
      continue
    fi
  fi

  FOUND=$(( FOUND + 1 ))

  # ── Elapsed time ──────────────────────────────────────────────
  ELAPSED_MIN=0
  if [ -n "$STARTED" ] && [ "$STARTED" -gt 0 ] 2>/dev/null; then
    if [ -n "$FINISHED" ] && [ "$FINISHED" -gt 0 ] 2>/dev/null; then
      ELAPSED_SEC=$(( FINISHED - STARTED ))
    else
      ELAPSED_SEC=$(( NOW - STARTED ))
    fi
    ELAPSED_MIN=$(( ELAPSED_SEC / 60 ))
  fi

  # ── Validate running status against live PID ──────────────────
  if [ "$STATUS" = "running" ] && [ -n "$PID" ]; then
    if ! kill -0 "$PID" 2>/dev/null; then
      # PID is gone but status wasn't updated — mark failed
      STATUS="failed"
      echo "failed" > "$STATUS_FILE"
    fi
  fi

  # ── Format output by status ───────────────────────────────────
  case "$STATUS" in
    completed)
      printf 'Time-Turner finished! %s files changed in %s minutes. Run /timeturner diff to review, /timeturner merge to apply.\n' \
        "$FILES_CHANGED" "$ELAPSED_MIN"
      ;;
    running)
      printf 'Time-Turner still working (%sm elapsed)...\n' "$ELAPSED_MIN"
      ;;
    failed)
      FIRST_ERROR=""
      if [ -f "$STATE_DIR/error.log" ]; then
        FIRST_ERROR=$(head -1 "$STATE_DIR/error.log" 2>/dev/null) || FIRST_ERROR=""
      fi
      if [ -n "$FIRST_ERROR" ]; then
        printf 'Time-Turner failed: %s. Run /timeturner cancel to clean up.\n' "$FIRST_ERROR"
      else
        printf 'Time-Turner failed. Run /timeturner cancel to clean up.\n'
      fi
      ;;
    preparing)
      printf 'Time-Turner is setting up...\n'
      ;;
    *)
      printf 'Time-Turner status: %s\n' "$STATUS"
      ;;
  esac
done

if [ "$FOUND" -eq 0 ]; then
  exit 1
fi

exit 0
