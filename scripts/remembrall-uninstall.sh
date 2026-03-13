#!/usr/bin/env bash
# Remembrall uninstall script — removes bridge, cleans data, reports status.
# Usage: bash scripts/remembrall-uninstall.sh [--dry-run]
#
# --dry-run: show what would be removed without actually removing anything.
set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  echo "DRY RUN — no changes will be made"
  echo ""
fi

ERRORS=0

# ── 1. Remove bridge from settings.json ───────────────────────────
echo "=== Step 1: Remove bridge from settings.json ==="
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q "claude-context-pct" "$SETTINGS" 2>/dev/null; then
  if command -v jq >/dev/null 2>&1; then
    CURRENT=$(jq -r '.statusLine.command // empty' "$SETTINGS")
    if [ -n "$CURRENT" ]; then
      # Remove bridge-related snippets from the command
      CLEANED=$(printf '%s' "$CURRENT" | \
        sed 's/;* *CTX_DIR="\/tmp\/claude-context-pct"[^;]*;//g' | \
        sed 's/;* *printf "%s" "\$remaining" > "\$CTX_DIR\/[^;]*;//g' | \
        sed 's/;* *mkdir -p "\$CTX_DIR"[^;]*;//g')
      # If the entire command was the bridge (nothing left after cleaning), remove statusLine
      CLEANED_TRIMMED=$(printf '%s' "$CLEANED" | sed 's/^[; ]*//;s/[; ]*$//')
      if [ -z "$CLEANED_TRIMMED" ]; then
        if [ "$DRY_RUN" = true ]; then
          echo "  Would remove statusLine entirely from settings.json"
        else
          TMP=$(mktemp "${SETTINGS}.XXXXXX")
          jq 'del(.statusLine)' "$SETTINGS" > "$TMP" 2>/dev/null && mv "$TMP" "$SETTINGS"
          echo "  Bridge status line removed entirely from settings.json"
        fi
      elif [ "$CLEANED" != "$CURRENT" ]; then
        if [ "$DRY_RUN" = true ]; then
          echo "  Would remove bridge snippet from statusLine.command"
        else
          TMP=$(mktemp "${SETTINGS}.XXXXXX")
          jq --arg cmd "$CLEANED" '.statusLine.command = $cmd' "$SETTINGS" > "$TMP" 2>/dev/null && mv "$TMP" "$SETTINGS"
          echo "  Bridge snippet removed from statusLine.command"
        fi
      else
        echo "  WARNING: Could not cleanly remove bridge — edit ~/.claude/settings.json manually"
        echo "  Look for 'claude-context-pct' in the statusLine.command"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  else
    echo "  WARNING: jq not found — cannot modify settings.json automatically"
    echo "  Manually remove the 'claude-context-pct' snippet from ~/.claude/settings.json"
    ERRORS=$((ERRORS + 1))
  fi
  # Clean up backup file
  if [ -f "${SETTINGS}.remembrall-backup" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "  Would remove ${SETTINGS}.remembrall-backup"
    else
      rm -f "${SETTINGS}.remembrall-backup"
      echo "  Removed settings.json backup"
    fi
  fi
else
  echo "  No bridge found in settings.json — nothing to remove"
fi

echo ""

# ── 2. Clean up persistent data ──────────────────────────────────
echo "=== Step 2: Clean up persistent data ==="
if [ -d "$HOME/.remembrall" ]; then
  # Show what's there
  HANDOFF_COUNT=$({ find "$HOME/.remembrall/handoffs" -name "handoff-*.md" 2>/dev/null || true; } | wc -l | tr -d ' ')
  PATCH_COUNT=$({ find "$HOME/.remembrall/patches" -name "patch-*.diff" 2>/dev/null || true; } | wc -l | tr -d ' ')
  echo "  Found: ${HANDOFF_COUNT} handoff(s), ${PATCH_COUNT} patch(es)"

  if [ -f "$HOME/.remembrall/calibration.json" ]; then
    echo "  Found: calibration data"
  fi
  if [ -f "$HOME/.remembrall/config.json" ]; then
    echo "  Found: config.json"
  fi
  if [ -f "$HOME/.remembrall/debug.log" ]; then
    echo "  Found: debug log"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  Would remove ~/.remembrall/"
  else
    rm -rf "$HOME/.remembrall"
    echo "  Removed ~/.remembrall/"
  fi
else
  echo "  No ~/.remembrall/ directory found"
fi

echo ""

# ── 3. Clean up temp files ────────────────────────────────────────
echo "=== Step 3: Clean up temp files ==="
TEMP_DIRS=(
  "/tmp/remembrall-nudges"
  "/tmp/remembrall-sessions"
  "/tmp/remembrall-growth"
  "/tmp/remembrall-bootstrap"
  "/tmp/remembrall-handoff-count"
  "/tmp/remembrall-autonomous"
  "/tmp/remembrall-pensieve"
  "/tmp/remembrall-timeturner"
  "/tmp/remembrall-meta"
  "/tmp/claude-context-pct"
)

# Clean up Time-Turner git worktrees before removing state dirs
if [ -d "/tmp/remembrall-timeturner" ]; then
  for tt_dir in /tmp/remembrall-timeturner/*/; do
    [ -d "$tt_dir" ] || continue
    tt_sid=$(basename "$tt_dir")
    if [ -d "${tt_dir}worktree" ]; then
      if [ "$DRY_RUN" = true ]; then
        echo "  Would remove git worktree ${tt_dir}worktree"
      else
        # Try to find the main repo to properly remove worktree
        git worktree remove --force "${tt_dir}worktree" 2>/dev/null || rm -rf "${tt_dir}worktree" 2>/dev/null || true
        git branch -D "timeturner/${tt_sid}" 2>/dev/null || true
        echo "  Removed Time-Turner worktree for session $tt_sid"
      fi
    fi
  done
fi

for dir in "${TEMP_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "  Would remove $dir"
    else
      rm -rf "$dir"
      echo "  Removed $dir"
    fi
  fi
done

echo ""

# ── 4. Summary ────────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
  echo "=== Dry run complete — no changes made ==="
  echo "Run without --dry-run to actually uninstall."
else
  if [ "$ERRORS" -gt 0 ]; then
    echo "=== Uninstall completed with $ERRORS warning(s) ==="
    echo "Check the warnings above and fix manually if needed."
  else
    echo "=== Uninstall complete ==="
  fi
  echo ""
  echo "To also uninstall the plugin itself, run:"
  echo "  claude plugin uninstall remembrall@cukas"
fi
