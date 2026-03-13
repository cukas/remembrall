#!/usr/bin/env bash
# Pensieve inject: generate compact context text from persisted session summaries.
# Called by session-resume.sh on SessionStart to populate additionalContext.
#
# Usage: pensieve-inject.sh <cwd> [budget]
# Output: compact text on stdout (≤ budget chars), exit 1 if no data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="pensieve-inject"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq

# ─── Arguments ────────────────────────────────────────────────────
CWD="${1:-}"
BUDGET_ARG="${2:-}"

if [ -z "$CWD" ]; then
  echo "Usage: pensieve-inject.sh <cwd> [budget]" >&2
  exit 1
fi

# ─── Config-driven defaults ───────────────────────────────────────
MAX_SESSIONS=$(remembrall_config "pensieve_max_sessions" "3")
[[ "$MAX_SESSIONS" =~ ^[0-9]+$ ]] || MAX_SESSIONS=3

if [ -n "$BUDGET_ARG" ] && [[ "$BUDGET_ARG" =~ ^[0-9]+$ ]]; then
  BUDGET="$BUDGET_ARG"
else
  BUDGET=$(remembrall_config "pensieve_inject_budget" "2000")
  [[ "$BUDGET" =~ ^[0-9]+$ ]] || BUDGET=2000
fi

remembrall_debug "pensieve-inject cwd=${CWD} budget=${BUDGET} max_sessions=${MAX_SESSIONS}"

# ─── Locate session JSON files ────────────────────────────────────
PENSIEVE_DIR=$(remembrall_pensieve_dir "$CWD")

if [ ! -d "$PENSIEVE_DIR" ]; then
  remembrall_debug "pensieve-inject: no pensieve dir at $PENSIEVE_DIR"
  exit 1
fi

# Collect session files, sort by distilled_at descending, take most recent N
SESSION_FILES=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  SESSION_FILES+=("$f")
done < <(
  for f in "$PENSIEVE_DIR"/session-*.json; do
    [ -f "$f" ] || continue
    ts=$(jq -r '.distilled_at // "0"' "$f" 2>/dev/null)
    printf '%s\t%s\n' "$ts" "$f"
  done | sort -r | head -n "$MAX_SESSIONS" | cut -f2
)

if [ "${#SESSION_FILES[@]}" -eq 0 ]; then
  remembrall_debug "pensieve-inject: no session JSON files found"
  exit 1
fi

SESSION_COUNT="${#SESSION_FILES[@]}"
PROJECT_NAME=$(basename "$CWD")

# ─── Aggregate across sessions ────────────────────────────────────
# Merge files (reads + edits), commands (first + last exit code), errors (resolved/open)
# patterns: dominant activity + test_fix_cycles (sum across sessions)
# Sessions are passed in order newest-first; jq -s slurps them in that order.
AGGREGATED=$(jq -s '
  . as $sessions |

  # ── Merge files: sum reads and edits per path ─────────────────
  (
    [ $sessions[].files // {} | to_entries[] ]
    | group_by(.key)
    | map({
        key: .[0].key,
        value: {
          reads: (map(.value.reads // 0) | add),
          edits: (map(.value.edits // 0) | add)
        }
      })
    | from_entries
  ) as $merged_files |

  # ── Commands: track first and last exit code per unique cmd ───
  # Sessions are newest-first, so reverse to get chronological order
  (
    [ ($sessions | reverse)[].commands // [] | .[] ]
    | group_by(.cmd)
    | map({
        cmd:        .[0].cmd,
        first_exit: (sort_by(.ts) | first | .exit // 0),
        last_exit:  (sort_by(.ts) | last  | .exit // 0)
      })
  ) as $merged_commands |

  # ── Errors: collect all, count resolved vs open ───────────────
  (
    [ $sessions[].errors // [] | .[] ]
    | group_by(.text)
    | map(if any(.resolved == true) then {text: .[0].text, resolved: true} else {text: .[0].text, resolved: false} end)
  ) as $merged_errors |

  # ── Patterns: sum test_fix_cycles, use most common dominant_activity ──
  (
    [ $sessions[].patterns.test_fix_cycles // 0 ] | add // 0
  ) as $total_cycles |
  (
    [ $sessions[].patterns.dominant_activity // "mixed" ]
    | group_by(.)
    | max_by(length)
    | .[0]
  ) as $dominant |

  # ── Error counts ──────────────────────────────────────────────
  ($merged_errors | map(select(.resolved == true))  | length) as $resolved_count |
  ($merged_errors | map(select(.resolved != true)) | length) as $open_count |

  {
    files:    $merged_files,
    commands: $merged_commands,
    resolved: $resolved_count,
    open:     $open_count,
    dominant: $dominant,
    cycles:   $total_cycles
  }
' "${SESSION_FILES[@]}" 2>/dev/null) || { remembrall_debug "pensieve-inject: jq aggregation failed"; exit 1; }

if [ -z "$AGGREGATED" ]; then
  remembrall_debug "pensieve-inject: empty aggregation"
  exit 1
fi

# ─── Budget allocation ─────────────────────────────────────────────
FILE_BUDGET=$(( BUDGET * 40 / 100 ))
CMD_BUDGET=$(( BUDGET * 25 / 100 ))

# ─── Build header line ───────────────────────────────────────────
HEADER="PENSIEVE MEMORY: [${PROJECT_NAME}] sessions=${SESSION_COUNT}"

# ─── Build files line ────────────────────────────────────────────
FILES_LINE=$(echo "$AGGREGATED" | jq -r '
  # Sort files by total activity descending
  [ .files | to_entries | .[] |
    {
      name: (.key | split("/") | last),
      r:    .value.reads,
      e:    .value.edits,
      total: (.value.reads + .value.edits)
    }
  ]
  | sort_by(-.total)
  | map(
      if .e > 0 then
        "\(.name)(R\(.r),E\(.e))"
      else
        "\(.name)(R\(.r))"
      end
    )
  | join(" ")
' 2>/dev/null) || FILES_LINE=""

if [ -n "$FILES_LINE" ]; then
  FILES_LINE="Files: ${FILES_LINE}"
  # Truncate if over budget
  if [ "${#FILES_LINE}" -gt "$FILE_BUDGET" ]; then
    FILES_LINE="${FILES_LINE:0:$((FILE_BUDGET - 3))}..."
  fi
fi

# ─── Build commands line ──────────────────────────────────────────
CMDS_LINE=$(echo "$AGGREGATED" | jq -r '
  .commands
  | map(
      # Shorten long commands to first two tokens (e.g. "npm test --watch" -> "npm test")
      (.cmd | split(" ") | .[0:2] | join(" ")) as $short |
      if .first_exit == .last_exit then
        "\($short)(\(.last_exit))"
      else
        "\($short)(\(.first_exit)→\(.last_exit))"
      end
    )
  | join(" ")
' 2>/dev/null) || CMDS_LINE=""

if [ -n "$CMDS_LINE" ]; then
  CMDS_LINE="Commands: ${CMDS_LINE}"
  if [ "${#CMDS_LINE}" -gt "$CMD_BUDGET" ]; then
    CMDS_LINE="${CMDS_LINE:0:$((CMD_BUDGET - 3))}..."
  fi
fi

# ─── Build errors line ────────────────────────────────────────────
RESOLVED=$(echo "$AGGREGATED" | jq -r '.resolved' 2>/dev/null) || RESOLVED=0
OPEN=$(echo "$AGGREGATED" | jq -r '.open' 2>/dev/null) || OPEN=0
ERRORS_LINE="Errors: ${RESOLVED} resolved, ${OPEN} open"

# ─── Build pattern line ───────────────────────────────────────────
DOMINANT=$(echo "$AGGREGATED" | jq -r '.dominant' 2>/dev/null) || DOMINANT="mixed"
CYCLES=$(echo "$AGGREGATED" | jq -r '.cycles' 2>/dev/null) || CYCLES=0
if [ "$CYCLES" -gt 0 ] 2>/dev/null; then
  PATTERN_LINE="Pattern: ${DOMINANT}, ${CYCLES} test-fix cycles"
else
  PATTERN_LINE="Pattern: ${DOMINANT}"
fi

# ─── Check for active Time-Turner ────────────────────────────────
TIMETURNER_LINE=""
TT_BASE="/tmp/remembrall-timeturner"
if [ -d "$TT_BASE" ]; then
  for status_file in "$TT_BASE"/*/status; do
    [ -f "$status_file" ] || continue
    STATUS=$(cat "$status_file" 2>/dev/null) || continue
    TT_DIR=$(dirname "$status_file")
    case "$STATUS" in
      completed)
        FILES_CHANGED=0
        if [ -f "$TT_DIR/files_changed" ]; then
          FILES_CHANGED=$(cat "$TT_DIR/files_changed" 2>/dev/null | tr -d '[:space:]') || FILES_CHANGED=0
        fi
        TIMETURNER_LINE="Time-Turner: completed (${FILES_CHANGED} files changed)"
        ;;
      running)
        ELAPSED=0
        if [ -f "$TT_DIR/started" ]; then
          STARTED=$(cat "$TT_DIR/started" 2>/dev/null | tr -d '[:space:]') || STARTED=0
          NOW_TS=$(date +%s 2>/dev/null) || NOW_TS=0
          if [ -n "$STARTED" ] && [[ "$STARTED" =~ ^[0-9]+$ ]]; then
            ELAPSED=$(( (NOW_TS - STARTED) / 60 ))
          fi
        fi
        TIMETURNER_LINE="Time-Turner: running (${ELAPSED}m elapsed)"
        ;;
    esac
    break  # Only report first active Time-Turner
  done
fi

# ─── Assemble output within budget ───────────────────────────────
OUTPUT="$HEADER"
[ -n "$FILES_LINE" ] && OUTPUT="${OUTPUT}
${FILES_LINE}"
[ -n "$CMDS_LINE" ] && OUTPUT="${OUTPUT}
${CMDS_LINE}"
OUTPUT="${OUTPUT}
${ERRORS_LINE}
${PATTERN_LINE}"
[ -n "$TIMETURNER_LINE" ] && OUTPUT="${OUTPUT}
${TIMETURNER_LINE}"

# Final budget check: hard truncate if still over
if [ "${#OUTPUT}" -gt "$BUDGET" ]; then
  OUTPUT="${OUTPUT:0:$((BUDGET - 3))}..."
fi

remembrall_debug "pensieve-inject: output ${#OUTPUT} chars, budget=${BUDGET}"
printf '%s\n' "$OUTPUT"
exit 0
