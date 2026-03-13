---
name: insights
description: View ambient learning insights — file hotspots, patterns, recurring errors
---

# Project Insights

Run the insights script to display aggregated project intelligence:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/remembrall-insights.sh" "$(pwd)"
```

Show the output to the user as-is. The script renders:
- File hotspots (files frequently touched across sessions)
- Workflow patterns (test-fix cycles, dominant activities)
- Recurring errors (errors that appear in multiple sessions)
- Session statistics (averages per session)

Insights are aggregated automatically from Pensieve session data on session start. If no insights exist yet, the user needs at least 3 sessions (configurable via `insights_min_sessions`).
