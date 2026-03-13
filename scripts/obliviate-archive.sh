#!/usr/bin/env bash
# Moves stale memories to .archive/ directory
# Usage: bash scripts/obliviate-archive.sh [--dry-run] [session_id]
# If session_id is given, uses the analysis report from obliviate-analyze.sh
# Otherwise, analyzes all memory dirs on the spot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib.sh"

remembrall_require_jq

DRY_RUN=false
SESSION_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) SESSION_ID="$1"; shift ;;
  esac
done

OBLIVIATE_DIR=$(remembrall_obliviate_dir)
REPORT_FILE=""

if [ -n "$SESSION_ID" ] && [ -f "$OBLIVIATE_DIR/${SESSION_ID}.json" ]; then
  REPORT_FILE="$OBLIVIATE_DIR/${SESSION_ID}.json"
fi

ARCHIVED=0

if [ -n "$REPORT_FILE" ]; then
  # Use pre-computed analysis
  STALE_FILES=$(jq -r '.memories[] | select(.stale == true) | .path' "$REPORT_FILE" 2>/dev/null) || STALE_FILES=""

  while IFS= read -r mem_path; do
    if [ -z "$mem_path" ] || [ ! -f "$mem_path" ]; then continue; fi
    ARCHIVE_DIR="$(dirname "$mem_path")/.archive"

    if [ "$DRY_RUN" = true ]; then
      echo "[dry-run] Would archive: $mem_path → $ARCHIVE_DIR/"
    else
      mkdir -p "$ARCHIVE_DIR"
      mv "$mem_path" "$ARCHIVE_DIR/"
      # Remove from MEMORY.md index
      _memory_md="$(dirname "$mem_path")/MEMORY.md"
      if [ -f "$_memory_md" ]; then
        _basename_f=$(basename "$mem_path")
        # Remove line referencing this file (fixed-string match, not regex)
        grep -vF "$_basename_f" "$_memory_md" > "${_memory_md}.tmp" 2>/dev/null && mv "${_memory_md}.tmp" "$_memory_md" || rm -f "${_memory_md}.tmp"
      fi
    fi
    ARCHIVED=$((ARCHIVED + 1))
  done <<< "$STALE_FILES"
else
  echo "No analysis report found. Run obliviate-analyze.sh first or provide a session_id."
  exit 1
fi

EASTER_EGGS=$(remembrall_config "easter_eggs" "true")
if [ "$EASTER_EGGS" = "true" ] && [ "$ARCHIVED" -gt 0 ] && [ "$DRY_RUN" = false ]; then
  echo "Obliviate! $ARCHIVED stale memories banished to the archive."
elif [ "$ARCHIVED" -gt 0 ]; then
  echo "Archived $ARCHIVED stale memories."
elif [ "$DRY_RUN" = true ]; then
  echo "[dry-run] No stale memories to archive."
else
  echo "No stale memories to archive."
fi
