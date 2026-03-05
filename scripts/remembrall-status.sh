#!/usr/bin/env bash
# Remembrall diagnostic script — checks bridge, handoffs, nudges, settings

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib.sh"

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
