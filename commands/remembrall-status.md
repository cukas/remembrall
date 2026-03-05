---
name: remembrall-status
description: Diagnostic command — check context %, bridge status, handoff files, and nudge state
---

# Remembrall Status

Run diagnostics to check the health of the remembrall system.

## Steps

1. **Check bridge status** — Run:
   ```bash
   CWD=$(pwd)
   if command -v md5 >/dev/null 2>&1; then
     CWD_HASH=$(md5 -qs "$CWD")
   elif command -v md5sum >/dev/null 2>&1; then
     CWD_HASH=$(printf '%s' "$CWD" | md5sum | cut -d' ' -f1)
   fi
   CTX_FILE="/tmp/claude-context-pct/$CWD_HASH"
   if [ -f "$CTX_FILE" ]; then
     echo "Bridge: OK — $(cat "$CTX_FILE")% remaining"
   else
     echo "Bridge: NOT FOUND — run /setup-remembrall to configure"
   fi
   ```

2. **Check handoff files** — Run:
   ```bash
   HANDOFF_DIR="$HOME/.remembrall/handoffs/$CWD_HASH"
   if [ -d "$HANDOFF_DIR" ]; then
     COUNT=$(ls "$HANDOFF_DIR"/handoff-*.md 2>/dev/null | wc -l | tr -d ' ')
     echo "Handoffs: $COUNT file(s) in $HANDOFF_DIR"
     ls -lt "$HANDOFF_DIR"/handoff-*.md 2>/dev/null
   else
     echo "Handoffs: None (directory doesn't exist yet)"
   fi
   ```

3. **Check nudge state** — Run:
   ```bash
   NUDGE_DIR="/tmp/remembrall-nudges"
   if [ -d "$NUDGE_DIR" ]; then
     for f in "$NUDGE_DIR"/*; do
       [ -f "$f" ] && echo "Nudge: $(basename "$f") = $(cat "$f")"
     done
   else
     echo "Nudges: None active"
   fi
   ```

4. **Check settings.json for bridge** — Run:
   ```bash
   grep -q "claude-context-pct" ~/.claude/settings.json && echo "Settings bridge: INSTALLED" || echo "Settings bridge: MISSING — run /setup-remembrall"
   ```

5. **Report** — Summarize the status in a clean format:

```
Remembrall Status
─────────────────
Bridge:    OK (87% remaining) | NOT FOUND
Handoffs:  2 file(s) | None
Nudges:    warning | urgent | None active
Settings:  Bridge installed | Bridge missing
```

If anything is wrong, suggest the fix (e.g., "Run /setup-remembrall to install the bridge").
