# Patrol Integration — Signal Protocol Specification

## Overview

Remembrall and Patrol communicate via a file-based signal protocol. Patrol is **optional** — if not installed, Remembrall behaves identically to before. Zero behavior change.

## Signal Directory

```
/tmp/remembrall-signals/{session_id}/
  handoff_trigger.json    # Patrol requests a handoff
  context_alert.json      # Patrol sends a context advisory
```

## Protocol

1. **Writer:** Patrol creates `{signal_type}.json` in the session's signal directory
2. **Reader:** Remembrall's `context-monitor.sh` checks for signals before threshold comparison
3. **Consumer:** After reading, Remembrall deletes the signal file (single-use)
4. **TTL:** Signals older than `patrol_signal_ttl` seconds (default: 300) are expired and deleted

## Signal Types

### `handoff_trigger`

Patrol requests Remembrall to create a handoff. Used when Patrol detects conditions that warrant a session handoff (e.g., policy violations, task completion).

```json
{
  "type": "handoff_trigger",
  "reason": "Policy violation detected — session should save state",
  "timestamp": "2026-03-13T10:00:00Z",
  "priority": "normal"
}
```

**Remembrall response:** Creates a preemptive handoff (same as the warning threshold behavior).

### `context_alert`

Patrol sends an advisory about context usage. Can include directives like `skip_timeturner`.

```json
{
  "type": "context_alert",
  "message": "Debug tasks don't benefit from parallel work",
  "skip_timeturner": true,
  "timestamp": "2026-03-13T10:00:00Z"
}
```

**Remembrall response:** Includes the message in `additionalContext`. If `skip_timeturner: true`, suppresses Time-Turner spawn for this session.

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `patrol_integration` | `true` | Enable signal checking |
| `patrol_signal_ttl` | `300` | Signal expiry in seconds |

## Implementation Notes

- Signal check runs in `context-monitor.sh` before threshold logic
- `session-resume.sh` cleans stale signals on startup
- All operations are atomic (write file, then read+delete)
- No dependency on Patrol's internals — only the signal files matter
- Patrol detection is for status display only (`remembrall_patrol_detected()`)

## Harry Potter Theme

- Signals = "Owl Post" (messages between institutions)
- Status display: "Ministry of Magic: Patrol (connected)" or "Ministry of Magic: Patrol (not detected)"
