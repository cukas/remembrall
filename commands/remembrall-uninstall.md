# Remembrall Uninstall

Clean up all remembrall data and remove the bridge from settings.json.

## Steps

1. **Preview what will be removed** — Run a dry run first:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}/scripts/remembrall-uninstall.sh" --dry-run
```

2. **Run the uninstall** — If the preview looks correct, run without --dry-run:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}/scripts/remembrall-uninstall.sh"
```

3. **Uninstall the plugin itself:**

```bash
claude plugin uninstall remembrall@cukas
echo "Remembrall plugin uninstalled"
```

4. **Confirm** — Tell the user: "Remembrall has been fully uninstalled. The bridge has been removed from settings.json, all data directories cleaned up, and the plugin uninstalled."
