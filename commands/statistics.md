---
name: statistics
description: View ambient learning statistics — file hotspots, patterns, recurring errors
---

# Project Statistics

Run the statistics script to display aggregated project intelligence:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/remembrall-statistics.sh" "$(pwd)"
```

Show the output to the user as-is. The script renders:
- File hotspots (files frequently touched across sessions)
- Workflow patterns (test-fix cycles, dominant activities)
- Recurring errors (errors that appear in multiple sessions)
- Session statistics (averages per session)

Statistics are aggregated automatically from Pensieve session data on session start. If no statistics exist yet, the user needs at least 3 sessions (configurable via `statistics_min_sessions`).
