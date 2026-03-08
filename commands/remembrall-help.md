---
name: remembrall-help
description: List all Remembrall commands, skills, and config options
---

# Remembrall Help

Show the user this reference:

## Commands

| Command | Description |
|---------|-------------|
| `/remembrall-status` | Diagnostic — check context %, bridge, handoffs, nudge state |
| `/remembrall-help` | This help — list all commands, skills, and config |
| `/setup-remembrall` | One-time setup — status-line bridge and config |
| `/autonomous` | Toggle autonomous mode on/off |

## Skills

| Skill | Description |
|-------|-------------|
| `/handoff` | Save structured handoff with state, files, git patches |
| `/replay` | Resume from handoff — verify git state, restore patches |

## Config (`~/.remembrall/config.json`)

| Setting | Default | Description |
|---------|---------|-------------|
| `git_integration` | `false` | Save git patches before handoff |
| `team_handoffs` | `false` | Copy handoffs to project `.remembrall/` |
| `autonomous_mode` | `false` | Skip plan mode for overnight/unattended runs |
| `retention_hours` | `72` | Hours to keep handoffs before cleanup |
| `max_transcript_kb` | *(auto)* | Override max transcript size (rarely needed — bridge calibration handles this) |

## How Context Management Works

```
100% ████████████████████  — working normally
 60% ████████████░░░░░░░░  — nudge: suggests /handoff (fires once in 31-60% band)
 30% ██████░░░░░░░░░░░░░░  — plan mode (or /handoff if autonomous)
 20% ████░░░░░░░░░░░░░░░░  — URGENT plan mode (or immediate /handoff)
  0% ░░░░░░░░░░░░░░░░░░░░  — auto-compaction safety net fires
```

**Attended** (default): At <=30%, Claude runs `/handoff` then enters plan mode. At <=20%, same but with urgent priority. User clicks "clear context" → fresh start.

**Autonomous** (`/autonomous` to toggle): At <=30%, Claude runs `/handoff` → continues working → auto-compaction recycles context automatically. No human needed.
