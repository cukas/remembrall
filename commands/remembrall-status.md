---
name: remembrall-status
description: Diagnostic command — check context %, bridge status, handoff files, and nudge state
---

# Remembrall Status

Run the diagnostic script and show the output to the user:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}/scripts/remembrall-status.sh"
```

If anything shows NOT FOUND or MISSING, suggest the user run `/setup-remembrall`.

If the script fails to run (e.g., permission denied or command not found), check that the plugin is correctly installed and that the hook scripts are executable (`chmod +x hooks/*.sh scripts/*.sh` from the plugin root).
