---
name: setup-remembrall
description: Manual fallback — the bridge auto-configures on install. Use this only if auto-setup failed or you want to customize the gauge.
---

# Setup Remembrall Bridge (Manual Fallback)

**Note:** Since v2.3.0, the bridge auto-configures on first session start. You only need this command if auto-setup failed or you want to customize the Remembrall gauge.

Remembrall needs a small bridge in your Claude Code status line to feed context window % to its hooks. This command helps you add it.

## What the Bridge Does

Your status line already has access to `$remaining` (context window % remaining) and `$session_id`. The bridge writes `$remaining` to a file in `/tmp/claude-context-pct/` named by `session_id`. Each Claude session gets its own bridge file.

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

## Remembrall Gauge (Status Line)

After the bridge is set up, offer to upgrade the context display to the Remembrall gauge:

"Would you like the Remembrall crystal ball gauge in your status line? It shows a visual bar with Harry Potter theming — the crystal ball pulses and warns 'Obliviate!' when context gets critically low."

If yes, find the existing context display block in the status line (the part inside `if [ -n "$remaining" ]`) and replace it with the Remembrall gauge. The gauge replaces `Context: XX% remaining` with a visual bar:

```bash
pct=${remaining%%.*}; w=10; filled=$((pct * w / 100)); [ $filled -gt $w ] && filled=$w; [ $filled -lt 0 ] && filled=0; empty=$((w - filled)); bar=''; for ((i=0;i<filled;i++)); do bar="${bar}█"; done; for ((i=0;i<empty;i++)); do bar="${bar}░"; done; pulse=$(($(date +%s) % 2)); if [ "$pct" -le 20 ] 2>/dev/null; then ctx_color='\033[31m'; if [ $pulse -eq 0 ]; then orb='🔮'; else orb='💀'; fi; glow=' Obliviate!'; elif [ "$pct" -le 40 ] 2>/dev/null; then ctx_color='\033[33m'; orb='🔮'; glow=' ⚡'; elif [ "$pct" -le 60 ] 2>/dev/null; then ctx_color='\033[33m'; orb='🔮'; glow=' ✦'; else ctx_color='\033[32m'; orb='🔮'; glow=''; fi; status="$status | $(printf "$ctx_color")${orb} [${bar}] ${pct}%${glow}$(printf '\033[0m')";
```

The gauge renders as:
```
>60%:   🔮 [████████░░] 80%              green, calm
41-60%: 🔮 [█████░░░░░] 50% ✦            orange, sparkle
21-40%: 🔮 [███░░░░░░░] 28% ⚡            orange, lightning
≤20%:   💀 [██░░░░░░░░] 15% Obliviate!   red, pulsing 🔮↔💀
```

**Important:** The gauge snippet must go inside the existing `if [ -n "$remaining" ]` block. It replaces the existing `status="$status | Context:..."` line. Keep the bridge snippet (`CTX_DIR=...`) after the gauge — both are needed.

## Optional Features

After the bridge and gauge are set up, present these optional features to the user:

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
