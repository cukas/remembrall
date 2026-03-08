# Remembrall Uninstall

Clean up all remembrall data and remove the bridge from settings.json.

## Steps

1. **Remove bridge from settings.json** — Run this command to strip the bridge snippet:

```bash
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q "claude-context-pct" "$SETTINGS" 2>/dev/null; then
  CURRENT=$(jq -r '.statusLine.command // empty' "$SETTINGS")
  if [ -n "$CURRENT" ]; then
    # Remove the bridge snippet (everything from CTX_DIR= to the next semicolon after 2>/dev/null;)
    CLEANED=$(printf '%s' "$CURRENT" | sed 's/;* *CTX_DIR="\/tmp\/claude-context-pct"[^;]*;//g' | sed 's/;* *session_id=\$(echo "\$input" | jq -r[^;]*;//g' | sed 's/;* *printf "%s" "\$remaining" > "\$CTX_DIR\/[^;]*;//g' | sed 's/;* *mkdir -p "\$CTX_DIR"[^;]*;//g')
    if [ -n "$CLEANED" ] && [ "$CLEANED" != "$CURRENT" ]; then
      jq --arg cmd "$CLEANED" '.statusLine.command = $cmd' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
      echo "Bridge removed from settings.json"
    else
      echo "Could not cleanly remove bridge — you may need to edit ~/.claude/settings.json manually"
      echo "Look for 'claude-context-pct' in the statusLine.command and remove that section"
    fi
  fi
else
  echo "No bridge found in settings.json"
fi
```

2. **Clean up data directories:**

```bash
rm -rf ~/.remembrall
rm -rf /tmp/remembrall-*
rm -rf /tmp/claude-context-pct
echo "Remembrall data cleaned up"
```

3. **Uninstall the plugin:**

```bash
claude plugin uninstall remembrall@cukas
echo "Remembrall plugin uninstalled"
```

4. **Confirm** — Tell the user: "Remembrall has been fully uninstalled. The bridge has been removed from settings.json, all data directories cleaned up, and the plugin uninstalled."
