#!/usr/bin/env bash
# Pensieve distill: crunch raw JSONL tracking data into a structured summary JSON.
# Called by precompact-handoff.sh and /handoff skill before compaction or handoff.
#
# Usage: pensieve-distill.sh <session_id> <cwd>
# Output: structured JSON on stdout + persisted to ~/.remembrall/pensieve/...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="pensieve-distill"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

# ─── Arguments ────────────────────────────────────────────────────
SESSION_ID="${1:-}"
CWD="${2:-}"

if [ -z "$SESSION_ID" ] || [ -z "$CWD" ]; then
  echo "Usage: pensieve-distill.sh <session_id> <cwd>" >&2
  exit 1
fi

# ─── Source JSONL file ────────────────────────────────────────────
JSONL_FILE="/tmp/remembrall-pensieve/${SESSION_ID}.jsonl"

if [ ! -f "$JSONL_FILE" ] || [ ! -s "$JSONL_FILE" ]; then
  remembrall_debug "pensieve-distill: no JSONL data at $JSONL_FILE — skipping"
  exit 1
fi

remembrall_debug "pensieve-distill: distilling session=$SESSION_ID from $JSONL_FILE"

# ─── Distill via jq ───────────────────────────────────────────────
# --slurpfile reads a JSONL file and produces an array of all parsed objects,
# wrapped in one more outer array: $entries == [ [obj1, obj2, ...] ]
# So $entries[0] is the array of all JSONL rows.
DISTILLED=$(jq -n \
  --argjson version 1 \
  --arg session_id "$SESSION_ID" \
  --arg project "$CWD" \
  --arg distilled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile entries "$JSONL_FILE" \
  '
  # --slurpfile reads JSONL lines into a flat array: $entries == [obj1, obj2, ...]
  # Each entry has: {ts, files: {"path": "R"|"E"}, cmds: [...], errors: [...], exits: {"cmd": N}}
  $entries as $rows |

  # ── files: aggregate reads (R) and edits (E) per file path ──────
  # Track .files is an object: {"src/index.ts": "E", "src/lib.ts": "R"}
  (
    [ $rows[] | select(.files != null) | .files | to_entries[] ] |
    group_by(.key) |
    map({
      key: .[0].key,
      value: {
        reads: (map(select(.value == "R")) | length),
        edits: (map(select(.value == "E")) | length)
      }
    }) |
    from_entries
  ) as $files |

  # ── commands: flatten cmds arrays, pair with exits, dedupe ──────
  # Track .cmds is an array of strings, .exits is {"cmd": exit_code}, .ts is timestamp
  (
    [ $rows[] |
      select(.cmds != null) |
      . as $row |
      .cmds[] |
      { cmd: ., exit: ($row.exits[.] // 0), ts: ($row.ts // 0) }
    ] |
    group_by(.cmd) |
    map(sort_by(.ts) | last) |
    sort_by(.ts) |
    .[-20:]
  ) as $commands |

  # ── errors: unique (first 200 chars), mark resolved heuristic ───
  # Track .errors is an array of strings
  (
    [ $rows[] | select(.errors != null and (.errors | length) > 0) | .errors[] | .[0:200] ] | unique
  ) as $unique_errors |
  (
    [ $rows[] | select(.errors != null and (.errors | length) > 0) |
      . as $row | .errors[] | { err: .[0:200], ts: ($row.ts // 0) } ]
  ) as $error_events |

  ($unique_errors | map(
    . as $etxt |
    ($error_events | map(select(.err == $etxt)) | max_by(.ts) | .ts // 0) as $last_err_ts |
    ($rows | map(select((.ts // 0) > $last_err_ts and (.errors == null or (.errors | length) == 0))) | length > 0) as $has_clean_after |
    {text: $etxt, resolved: $has_clean_after}
  )) as $errors |

  # ── patterns ────────────────────────────────────────────────────
  # test_fix_cycles: adjacent pairs where a test command fails then succeeds
  ($commands |
    [
      range(1; length) |
      . as $i |
      select(
        ($commands[$i-1].cmd | test("test"; "i")) and
        ($commands[$i-1].exit != 0) and
        ($commands[$i].cmd | test("test"; "i")) and
        ($commands[$i].exit == 0)
      )
    ] | length
  ) as $test_fix_cycles |

  # total reads and edits across all files for dominant_activity
  ($files | to_entries | map(.value.reads) | add // 0) as $total_reads |
  ($files | to_entries | map(.value.edits) | add // 0) as $total_edits |

  (if $total_edits > $total_reads then "editing"
   elif $total_reads > $total_edits then "reading"
   else "mixed"
   end) as $dominant_activity |

  ($files | keys | length) as $unique_files |
  ($commands | length) as $total_commands |
  ($errors | length) as $total_errors |
  ($errors | map(select(.resolved == true)) | length) as $resolved_errors |

  # ── assemble output ─────────────────────────────────────────────
  {
    version: $version,
    session_id: $session_id,
    project: $project,
    distilled_at: $distilled_at,
    files: $files,
    commands: $commands,
    errors: $errors,
    patterns: {
      test_fix_cycles: $test_fix_cycles,
      dominant_activity: $dominant_activity,
      unique_files: $unique_files,
      total_commands: $total_commands,
      total_errors: $total_errors,
      resolved_errors: $resolved_errors
    }
  }
  ' 2>/dev/null)

if [ -z "$DISTILLED" ]; then
  remembrall_debug "pensieve-distill: jq distillation failed for session=$SESSION_ID"
  exit 1
fi

# ─── Persist to ~/.remembrall/pensieve/{project-hash}/ ────────────
PENSIEVE_DIR=$(remembrall_pensieve_dir "$CWD")
mkdir -p "$PENSIEVE_DIR"
PERSIST_FILE="$PENSIEVE_DIR/session-${SESSION_ID}.json"

TMPFILE=$(mktemp "${PENSIEVE_DIR}/.distill-XXXXXX.tmp")
printf '%s\n' "$DISTILLED" > "$TMPFILE"
mv "$TMPFILE" "$PERSIST_FILE"

remembrall_debug "pensieve-distill: persisted to $PERSIST_FILE"

# ─── Output ───────────────────────────────────────────────────────
printf '%s\n' "$DISTILLED"
exit 0
