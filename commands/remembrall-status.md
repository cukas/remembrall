---
name: remembrall-status
description: Diagnostic command — check context %, bridge status, handoff files, and nudge state
---

# Remembrall Status

Run the diagnostic script and show the output to the user:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/remembrall-status.sh"
```

If anything shows NOT FOUND or MISSING, suggest the user run `/setup-remembrall`.
