---
name: phoenix
description: Toggle Phoenix mode on/off — recurring context recycling for zero-click continuity
---

# Toggle Phoenix Mode

Check current state and toggle:

```bash
source "${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}/hooks/lib.sh"
CURRENT=$(remembrall_config "phoenix_mode" "false")
echo "Current: phoenix_mode=$CURRENT"
```

- If currently **off** (`false`): set it to `true` and confirm.
- If currently **on** (`true`): set it to `false` and confirm.

```bash
source "${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}/hooks/lib.sh"
CURRENT=$(remembrall_config "phoenix_mode" "false")
if [ "$CURRENT" = "true" ]; then
  remembrall_config_set "phoenix_mode" "false"
  echo "SWITCHED: phoenix_mode → OFF (normal AK behavior)"
else
  remembrall_config_set "phoenix_mode" "true"
  echo "SWITCHED: phoenix_mode → ON (recurring context recycling)"
fi
```

If user asks for status, show Phoenix chain info:

```bash
source "${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}/hooks/lib.sh"
PHOENIX_MAX=$(remembrall_config "phoenix_max_cycles" "10")
echo "phoenix_mode: $(remembrall_config "phoenix_mode" "false")"
echo "phoenix_max_cycles: $PHOENIX_MAX"
PHOENIX_DIR="/tmp/remembrall-phoenix"
if [ -d "$PHOENIX_DIR" ]; then
  for chain_file in "$PHOENIX_DIR"/*.cycle; do
    [ -f "$chain_file" ] || continue
    chain_id=$(basename "$chain_file" .cycle)
    cycle=$(cat "$chain_file")
    echo "Chain $chain_id: cycle $cycle/$PHOENIX_MAX"
  done
fi
```

Show the user the result and explain:
- **ON**: At the urgent threshold, Remembrall captures state and triggers context recycling automatically. The cycle rearms after each compaction — zero clicks, indefinite continuation. Max cycles configurable via `phoenix_max_cycles` (default 10).
- **OFF**: Normal Avada Kedavra behavior at urgent threshold (one-shot).
