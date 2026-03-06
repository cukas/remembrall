---
name: autonomous
description: Toggle autonomous mode on/off — skip plan mode for unattended overnight runs
---

# Toggle Autonomous Mode

Check current state and toggle:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
CURRENT=$(remembrall_config "autonomous_mode" "false")
echo "Current: autonomous_mode=$CURRENT"
```

- If currently **off** (`false`): set it to `true` and confirm.
- If currently **on** (`true`): set it to `false` and confirm.

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
CURRENT=$(remembrall_config "autonomous_mode" "false")
if [ "$CURRENT" = "true" ]; then
  remembrall_config_set "autonomous_mode" "false"
  echo "SWITCHED: autonomous_mode → OFF (plan mode, human clicks)"
else
  remembrall_config_set "autonomous_mode" "true"
  echo "SWITCHED: autonomous_mode → ON (automatic handoff, no human needed)"
fi
```

Show the user the result and explain:
- **ON**: At low context, Remembrall uses `/handoff` + auto-compaction. No human click needed. Good for overnight/unattended runs.
- **OFF**: At low context, Remembrall tells Claude to enter plan mode. User sees "Yes, clear context" and clicks. Default for attended use.
