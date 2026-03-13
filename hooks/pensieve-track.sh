#!/usr/bin/env bash
# UserPromptSubmit hook: incremental transcript parser for Pensieve feature.
# Reads only new JSONL lines since last run, extracts file access, commands,
# and errors, then appends structured JSONL to a session tracking file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REMEMBRALL_HOOK="pensieve-track"
source "$SCRIPT_DIR/lib.sh"

remembrall_require_jq
remembrall_hook_enabled "pensieve-track" || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# Exit silently if no session_id or transcript path
if [ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

PENSIEVE_DIR="/tmp/remembrall-pensieve"
mkdir -p "$PENSIEVE_DIR"

POS_FILE="$PENSIEVE_DIR/${SESSION_ID}.pos"
OUT_FILE="$PENSIEVE_DIR/${SESSION_ID}.jsonl"

# ── Fast path: check if transcript has grown since last position ──────────
TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ') || exit 0
LAST_POS=0
if [ -f "$POS_FILE" ]; then
  LAST_POS=$(cat "$POS_FILE" 2>/dev/null | tr -d '[:space:]')
  # Validate it's a number; reset if not
  case "$LAST_POS" in
    ''|*[!0-9]*) LAST_POS=0 ;;
  esac
fi

# Nothing new — exit immediately (0ms fast path)
if [ "${TRANSCRIPT_SIZE:-0}" -le "${LAST_POS:-0}" ] 2>/dev/null; then
  exit 0
fi

remembrall_debug "pensieve session=${SESSION_ID} pos=${LAST_POS} size=${TRANSCRIPT_SIZE}"

# ── Extract structured data from new content in a single jq pass ──────────
# tail -c +N is 1-based: byte offset LAST_POS means skip LAST_POS bytes,
# so start at byte (LAST_POS + 1).
READ_FROM=$(( LAST_POS + 1 ))

EXTRACTED=$(
  tail -c +"${READ_FROM}" "$TRANSCRIPT_PATH" 2>/dev/null \
  | jq -sc '
    # Helper: flatten array or return single value as array
    def as_array: if type == "array" then . else [.] end;

    # Collect all valid JSONL objects from the new lines
    [ .[] | select(type == "object") ] as $lines |

    # ── Tool use entries (assistant messages with tool_use content) ──
    ($lines | map(
      select(.type == "assistant")
      | .message.content // []
      | as_array
      | .[]
      | select(.type == "tool_use")
    )) as $tool_uses |

    # ── Tool result entries (user messages with tool_result content) ──
    # Index by tool_use_id for exit-code and error extraction
    ($lines | map(
      select(.type == "user")
      | .message.content // []
      | as_array
      | .[]
      | select(.type == "tool_result")
    )) as $tool_results |

    # Build a lookup: tool_use_id -> result content string
    ( $tool_results | map({
        key: .tool_use_id,
        value: (
          .content
          | if type == "array" then map(.text // "") | join("") else (. // "") end
        )
      }) | from_entries
    ) as $result_by_id |

    # ── Files: Read → "R", Edit/Write/MultiEdit → "E" ────────────────
    ( $tool_uses | map(
        select(.name == "Read" or .name == "Edit" or .name == "Write" or .name == "MultiEdit")
        | {
            path: (.input.file_path // .input.path // ""),
            tag:  (if .name == "Read" then "R" else "E" end)
          }
        | select(.path != "")
      )
      # Last tag wins (E beats R for the same path)
      | group_by(.path)
      | map({
          key:   (.[0].path),
          value: (map(.tag) | if any(. == "E") then "E" else "R" end)
        })
      | from_entries
    ) as $files |

    # ── Commands: Bash tool input.command ────────────────────────────
    ( $tool_uses | map(
        select(.name == "Bash")
        | .input.command // ""
        | select(. != "")
      )
    ) as $cmds |

    # ── Exit codes: parse "Exit code: N" from Bash tool results ──────
    ( $tool_uses | map(
        select(.name == "Bash")
        | . as $tu
        | ($result_by_id[.id] // "") as $res
        | {
            cmd:  (.input.command // ""),
            exit: (try ($res | capture("Exit code: *(?<n>[0-9]+)") | .n | tonumber) catch 0)
          }
        | select(.cmd != "")
      )
      | map({ key: .cmd, value: .exit }) | from_entries
    ) as $exits |

    # ── Errors: tool_result content containing error keywords ─────────
    ( $tool_results | map(
        .content
        | if type == "array" then map(.text // "") | join("") else (. // "") end
        | select(
            test("error|Error|fail|FAIL|exception|Exception|panic"; "")
          )
        | .[0:200]
      )
      | unique
    ) as $errors |

    # ── Emit one JSONL record only if there is something to report ────
    if (($files | length) > 0) or (($cmds | length) > 0) or (($errors | length) > 0)
    then
      {
        ts:     (now | floor),
        files:  $files,
        cmds:   $cmds,
        errors: $errors,
        exits:  $exits
      }
    else
      empty
    end
  ' 2>/dev/null
)
JQ_EXIT=$?

# Only advance position if jq succeeded — on parse failure (e.g. partial
# transcript write), retry from the same offset next time.
if [ "$JQ_EXIT" -ne 0 ]; then
  remembrall_debug "pensieve jq failed (exit=$JQ_EXIT) — will retry from pos=${LAST_POS}"
  exit 0
fi

# Append record if jq produced output (empty = no tool calls in this delta)
if [ -n "$EXTRACTED" ]; then
  printf '%s\n' "$EXTRACTED" >> "$OUT_FILE"
  remembrall_debug "pensieve wrote record to ${OUT_FILE}"
fi

# Update position file to current transcript size
printf '%s\n' "$TRANSCRIPT_SIZE" > "$POS_FILE"

exit 0
