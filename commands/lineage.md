---
name: lineage
description: View session ancestry DAG — see how sessions branch and chain
---

# Session Lineage

Run the lineage script to display the session ancestry graph:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/remembrall-lineage.sh" "$(pwd)"
```

Show the output to the user as-is. The script renders a text DAG showing:
- Session chains (parent → child relationships)
- Time-Turner branches (parallel agents)
- Session status (active, completed, interrupted, merged)
- Files touched per session

If no lineage data exists yet, inform the user that lineage is recorded automatically as they work.
