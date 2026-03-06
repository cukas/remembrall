# Remembrall v2.2.0

## Install

```bash
claude plugin install remembrall@cukas
```

## What's New

### Slim Nudge Messages
Nudge messages cut from ~600 tokens to <100 tokens each. The full handoff template now lives entirely in the `/handoff` skill — nudges just say "run /handoff" and Claude reads the template when it executes. This saves significant context in the window the plugin is designed to protect.

### Stop-Check Enforcement
The stop hook now enforces handoff creation when context is below 40%. If no handoff exists for the session, Claude receives an `additionalContext` directive requiring `/handoff` before it can finish. If a handoff already exists, it suggests `/clear + /replay` via stderr.

### Failed Approaches Section
The handoff template now includes a dedicated **Failed Approaches** section. Each entry captures what was attempted, the exact error message or reason it failed, and why it won't work — preventing the next session from repeating dead ends.

### Prior Incantato Spell
New easter egg spell for Harry Potter users: "Prior Incantato" shows how many times `/handoff` was run in the current session. The counter is tracked per session in `/tmp/remembrall-handoff-count/` and displayed in `/remembrall-status`.

### Clean Git History
50 commits squashed into 9 logical units. The history now reads as a clear progression: v1 foundation, v2 core, gauge polish, session isolation, plan mode, autonomous mode, docs, bug fixes, and this release.

## Full Changelog

https://github.com/cukas/remembrall/commits/v2.2.0
