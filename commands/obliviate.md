---
name: obliviate
description: Analyze and archive stale memories — semantic context pruning
---

# Obliviate — Memory Pruning

Check if an obliviate analysis report exists for the current session:

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-}"
REPORT="/tmp/remembrall-obliviate/${SESSION_ID}.json"
```

If the report exists, show the user a summary of stale memories:

```bash
jq -r '.memories[] | select(.stale == true) | "  - \(.file): \(.reason)"' "$REPORT"
```

Then ask the user if they want to archive stale memories. If yes:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/obliviate-archive.sh" "$SESSION_ID"
```

If no report exists, run the analyzer first:

```bash
echo '{"session_id":"'"$SESSION_ID"'","cwd":"'"$(pwd)"'"}' | bash "$CLAUDE_PLUGIN_ROOT/hooks/obliviate-analyze.sh"
```

Then display the results and ask for confirmation before archiving.

**Always confirm with the user before archiving.** Show them what will be archived and why.
