#!/usr/bin/env bash
# Remembrall diagnostic script — checks bridge, handoffs, nudges, settings

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib.sh"

remembrall_require_jq

CWD="${1:-$(pwd)}"

HANDOFF_DIR=$(remembrall_handoff_dir "$CWD") || { echo "Error: no md5 or md5sum found"; exit 1; }

echo "Remembrall Status"
echo "─────────────────"

# Bridge — check CWD + parent dirs
CTX_FILE=$(remembrall_find_bridge "$CWD")
if [ -n "$CTX_FILE" ]; then
  echo "Bridge:   OK ($(cat "$CTX_FILE")% remaining)"
else
  echo "Bridge:   NOT FOUND — run /setup-remembrall"
fi

# Handoffs — use glob count instead of ls|wc
if [ -d "$HANDOFF_DIR" ]; then
  COUNT=0
  for f in "$HANDOFF_DIR"/handoff-*.md; do [ -f "$f" ] && COUNT=$((COUNT + 1)); done
  if [ "$COUNT" -gt 0 ]; then
    echo "Handoffs: $COUNT file(s)"
    for f in "$HANDOFF_DIR"/handoff-*.md; do
      [ -f "$f" ] && echo "          $f"
    done
  else
    echo "Handoffs: None"
  fi
else
  echo "Handoffs: None"
fi

# Nudges
NUDGE_DIR="/tmp/remembrall-nudges"
if [ -d "$NUDGE_DIR" ]; then
  found=0
  for f in "$NUDGE_DIR"/*; do
    if [ -f "$f" ]; then
      echo "Nudges:   $(basename "$f") = $(cat "$f")"
      found=1
    fi
  done
  [ "$found" -eq 0 ] && echo "Nudges:   None active"
else
  echo "Nudges:   None active"
fi

# Settings bridge
if grep -q "claude-context-pct" ~/.claude/settings.json 2>/dev/null; then
  echo "Settings: Bridge installed"
else
  echo "Settings: Bridge MISSING — run /setup-remembrall"
fi

# Config
CONFIG_FILE="$HOME/.remembrall/config.json"
if [ -f "$CONFIG_FILE" ]; then
  echo "Config:   $CONFIG_FILE"
  GIT_INT=$(jq -r '.git_integration // "false"' "$CONFIG_FILE" 2>/dev/null)
  TEAM=$(jq -r '.team_handoffs // "false"' "$CONFIG_FILE" 2>/dev/null)
  echo "          git_integration: $GIT_INT"
  echo "          team_handoffs: $TEAM"
else
  echo "Config:   Not configured (using defaults)"
fi

# Patches
PATCHES_DIR=$(remembrall_patches_dir "$CWD" 2>/dev/null)
if [ -n "$PATCHES_DIR" ] && [ -d "$PATCHES_DIR" ]; then
  PATCH_COUNT=0
  for f in "$PATCHES_DIR"/patch-*.diff; do [ -f "$f" ] && PATCH_COUNT=$((PATCH_COUNT + 1)); done
  if [ "$PATCH_COUNT" -gt 0 ]; then
    echo "Patches:  $PATCH_COUNT file(s)"
    for f in "$PATCHES_DIR"/patch-*.diff; do
      [ -f "$f" ] && echo "          $f"
    done
  else
    echo "Patches:  None"
  fi
else
  echo "Patches:  None"
fi

# Team handoffs
TEAM_DIR="$CWD/.remembrall/handoffs"
if [ -d "$TEAM_DIR" ]; then
  TEAM_COUNT=0
  for f in "$TEAM_DIR"/handoff-*.md; do [ -f "$f" ] && TEAM_COUNT=$((TEAM_COUNT + 1)); done
  if [ "$TEAM_COUNT" -gt 0 ]; then
    echo "Team:     $TEAM_COUNT handoff(s)"
    for f in "$TEAM_DIR"/handoff-*.md; do
      [ -f "$f" ] && echo "          $f"
    done
  else
    echo "Team:     No team handoffs"
  fi
else
  echo "Team:     No team handoffs directory"
fi
