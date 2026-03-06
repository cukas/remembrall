---
name: setup-remembrall
description: One-time setup — adds the status-line bridge snippet that feeds context % to remembrall's hooks
---

# Setup Remembrall Bridge

Remembrall needs a small bridge in your Claude Code status line to feed context window % to its hooks. This command helps you add it.

## What the Bridge Does

Your status line already has access to `$remaining` (context window % remaining), `$cwd` (current working directory), and `$session_id`. The bridge writes `$remaining` to a file in `/tmp/claude-context-pct/` named `{md5-of-cwd}-{session_id}`. This ensures multiple Claude instances on the same project each get their own bridge file.

## Steps

1. **Check if the bridge already exists** — Run:
   ```bash
   grep -q "claude-context-pct" ~/.claude/settings.json 2>/dev/null && echo "Bridge already installed" || echo "Bridge not found"
   ```

2. **If already installed:** Tell the user "Remembrall bridge is already set up. You're good to go!" and stop.

3. **If not installed:** Read the user's current `~/.claude/settings.json` and find the `statusLine` section.

4. **Find the insertion point** — Look for the block that checks `if [ -n "$remaining" ]`. The bridge snippet goes inside this block, before the closing `fi`.

5. **Show the user the bridge snippet** they need to add inside their existing `if [ -n "$remaining" ]; then ... fi` block. The snippet requires `$session_id` to be extracted earlier in the status line (add `session_id=$(echo "$input" | jq -r '.session_id // empty');` alongside the other extractions):

```bash
CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null;
printf "%s" "$remaining" > "$CTX_DIR/${session_id}" 2>/dev/null;
```

6. **Edit the settings file** — Insert the bridge snippet into the status line command. The exact location depends on the user's existing status line format. Find the `if [ -n "$remaining" ]` block and add the bridge snippet inside it (after the existing context display logic, before the `fi`).

7. **Verify** — After editing, run:
   ```bash
   cat /tmp/claude-context-pct/* 2>/dev/null || echo "No bridge files yet — start a new Claude session to generate them"
   ```

## Important Notes

- The bridge is cross-platform: uses `md5` on macOS, `md5sum` on Linux
- The bridge writes to `/tmp/` so data is ephemeral (cleared on reboot)
- The plugin itself CANNOT modify settings.json — this command guides the user/Claude through the edit
- If the user doesn't have a status line configured at all, they need to set one up first. Point them to the Claude Code docs on status line configuration.
- The bridge snippet is idempotent — running it multiple times is harmless

## Optional Features

After the bridge is set up, present these optional features to the user:

8. **Git Integration** — Ask: "Would you like remembrall to save git patches of your session's changes before handoff? Patches are stored in ~/.remembrall/patches/ — your repo stays untouched."

   If yes, run:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
   remembrall_config_set "git_integration" "true"
   echo "Git integration enabled"
   ```

   If no, run:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
   remembrall_config_set "git_integration" "false"
   echo "Git integration disabled"
   ```

9. **Team Handoffs** — Ask: "Would you like handoffs to also be saved in your project directory so other team members' Claude sessions can pick them up?"

   If yes, run:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
   remembrall_config_set "team_handoffs" "true"
   echo "Team handoffs enabled"
   ```
   Then suggest: "Consider adding `.remembrall/` to your project's `.gitignore` if you don't want handoff files committed."

   If no, run:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
   remembrall_config_set "team_handoffs" "false"
   echo "Team handoffs disabled"
   ```

10. **Show final config** — Display the current configuration:
    ```bash
    echo "Current remembrall config:"
    cat ~/.remembrall/config.json 2>/dev/null || echo "No config file (using defaults)"
    ```

## Reconfiguring

To change settings later, the user can run `/setup-remembrall` again — it will detect existing config and offer to update it. Or they can edit `~/.remembrall/config.json` directly.
