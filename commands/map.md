---
name: map
description: Show the Marauder's Map — visual overview of session context, files, commands, and errors
---

# The Marauder's Map

Run the Marauder's Map visualization to see session state at a glance.

## Steps

1. Run the map script:
   ```bash
   REMEMBRALL_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}"
   bash "$REMEMBRALL_ROOT/scripts/remembrall-map.sh" "$(pwd)"
   ```

2. Present the output to the user as-is (it's already formatted with colors).
