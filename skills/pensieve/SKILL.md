---
name: pensieve
description: Browse and search Pensieve session memories — what files were touched, commands run, errors resolved across sessions. Use to understand session history when context is unclear.
---

# Pensieve — Session Memory Browser

Browse distilled session memories to understand what happened in previous sessions.

## Steps

1. **Locate memories** — Find Pensieve session files:
   ```bash
   REMEMBRALL_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}"
   PENSIEVE_DIR=$(bash -c 'source "'"$REMEMBRALL_ROOT"'/hooks/lib.sh" && remembrall_pensieve_dir "$(pwd)"')
   ls -lt "$PENSIEVE_DIR"/session-*.json 2>/dev/null || echo "No Pensieve memories found"
   ```

2. **List sessions** — Show available session summaries with timestamps and file counts.

3. **Browse a session** — If user specifies a session or "latest", read that session JSON and present a formatted summary:
   - Files touched (with read/edit counts)
   - Commands run (with exit codes)
   - Errors (resolved vs open)
   - Patterns (dominant activity, test-fix cycles)

4. **Search memories** — If user asks "what files did I edit?" or "did tests pass?", search across all session JSONs for relevant data.

## Rules
- Present data concisely — tables for files, bullet lists for commands/errors
- Don't modify any Pensieve files — read-only browsing
- If no memories exist, suggest that Pensieve tracks automatically during work and memories appear after the first handoff or compaction
