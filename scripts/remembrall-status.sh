#!/usr/bin/env bash
# Remembrall diagnostic script — checks bridge, handoffs, nudges, settings

CWD="${1:-$(pwd)}"

# Cross-platform md5
if command -v md5 >/dev/null 2>&1; then
  CWD_HASH=$(md5 -qs "$CWD")
elif command -v md5sum >/dev/null 2>&1; then
  CWD_HASH=$(printf '%s' "$CWD" | md5sum | cut -d' ' -f1)
else
  echo "Error: no md5 or md5sum found"
  exit 1
fi

echo "Remembrall Status"
echo "─────────────────"

# Bridge
CTX_FILE="/tmp/claude-context-pct/$CWD_HASH"
if [ -f "$CTX_FILE" ]; then
  echo "Bridge:    OK ($(cat "$CTX_FILE")% remaining)"
else
  echo "Bridge:    NOT FOUND — run /setup-remembrall"
fi

# Handoffs
HANDOFF_DIR="$HOME/.remembrall/handoffs/$CWD_HASH"
if [ -d "$HANDOFF_DIR" ]; then
  COUNT=$(ls "$HANDOFF_DIR"/handoff-*.md 2>/dev/null | wc -l | tr -d ' ')
  if [ "$COUNT" -gt 0 ]; then
    echo "Handoffs:  $COUNT file(s)"
    ls -lt "$HANDOFF_DIR"/handoff-*.md 2>/dev/null | while read -r line; do
      echo "           $line"
    done
  else
    echo "Handoffs:  None"
  fi
else
  echo "Handoffs:  None"
fi

# Nudges
NUDGE_DIR="/tmp/remembrall-nudges"
if [ -d "$NUDGE_DIR" ]; then
  found=0
  for f in "$NUDGE_DIR"/*; do
    if [ -f "$f" ]; then
      echo "Nudges:    $(basename "$f") = $(cat "$f")"
      found=1
    fi
  done
  [ "$found" -eq 0 ] && echo "Nudges:    None active"
else
  echo "Nudges:    None active"
fi

# Settings bridge
if grep -q "claude-context-pct" ~/.claude/settings.json 2>/dev/null; then
  echo "Settings:  Bridge installed"
else
  echo "Settings:  Bridge MISSING — run /setup-remembrall"
fi
