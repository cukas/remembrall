#!/usr/bin/env bash
# The Marauder's Map — visual session overview for Remembrall
# Usage: bash scripts/remembrall-map.sh [cwd]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib.sh"

CWD="${1:-$(pwd)}"

# ─── ANSI helpers ─────────────────────────────────────────────────
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Easter eggs ──────────────────────────────────────────────────
EASTER_EGGS=$(remembrall_config "easter_eggs" "true")
if [ "$EASTER_EGGS" = "true" ]; then
  printf '%b\n' "${YELLOW}I solemnly swear that I am up to no good.${RESET}"
  echo ""
fi

# ─── Header ───────────────────────────────────────────────────────
printf '%b\n' "${BOLD}The Marauder's Map${RESET}"
echo "══════════════════"
echo ""

# ─── Context gauge from bridge ────────────────────────────────────
SESSION_ID=$(remembrall_read_session_id "$CWD" 2>/dev/null) || true
CTX_FILE=$(remembrall_find_bridge "$CWD" "$SESSION_ID" 2>/dev/null) || true

if [ -n "$CTX_FILE" ] && [ -f "$CTX_FILE" ]; then
  CTX_PCT=$(cat "$CTX_FILE" 2>/dev/null | tr -d '[:space:]') || CTX_PCT=""
  if [ -n "$CTX_PCT" ]; then
    # Bridge stores remaining %, gauge takes remaining %
    printf 'Context: '
    remembrall_gauge "$CTX_PCT"
    echo ""
  else
    echo "Context: unknown"
  fi
else
  echo "Context: bridge not found (run /setup-remembrall)"
fi
echo ""

# ─── Load current session JSONL ───────────────────────────────────
PENSIEVE_TMP=$(remembrall_pensieve_tmp)
JSONL_FILE=""
if [ -n "$SESSION_ID" ]; then
  JSONL_FILE="$PENSIEVE_TMP/${SESSION_ID}.jsonl"
fi

HAS_DATA=0
FILES_JSON=""
CMDS_JSON=""
ERRORS_JSON=""

if [ -n "$JSONL_FILE" ] && [ -f "$JSONL_FILE" ] && [ -s "$JSONL_FILE" ]; then
  HAS_DATA=1

  # Aggregate files: {"path": {reads: N, edits: N}}
  FILES_JSON=$(jq -sc '
    [ .[] | select(.files != null) | .files | to_entries[] ]
    | group_by(.key)
    | map({
        key: .[0].key,
        value: {
          reads: (map(select(.value == "R")) | length),
          edits: (map(select(.value == "E")) | length)
        }
      })
    | from_entries
  ' "$JSONL_FILE" 2>/dev/null) || FILES_JSON="{}"

  # Aggregate commands: [{cmd, exit}] latest per command
  CMDS_JSON=$(jq -sc '
    [ .[] | select(.cmds != null) | . as $row | .cmds[] |
      { cmd: ., exit: ($row.exits[.] // 0), ts: ($row.ts // 0) }
    ]
    | group_by(.cmd)
    | map(sort_by(.ts) | last)
    | sort_by(.ts)
    | .[-20:]
  ' "$JSONL_FILE" 2>/dev/null) || CMDS_JSON="[]"

  # Aggregate errors: [{text, resolved}]
  ERRORS_JSON=$(jq -sc '
    . as $rows |
    [ $rows[] | select(.errors != null and (.errors | length) > 0) |
      . as $row | .errors[] | { err: .[0:200], ts: ($row.ts // 0) }
    ] as $events |
    ($events | map(.err) | unique) as $unique |
    $unique | map(
      . as $etxt |
      ($events | map(select(.err == $etxt)) | max_by(.ts) | .ts // 0) as $last_ts |
      # heuristic: resolved if there is a later row with no errors
      ([ $rows[] | select((.ts // 0) > $last_ts and (.errors == null or (.errors | length) == 0)) ] | length > 0) as $resolved |
      { text: $etxt, resolved: $resolved }
    )
  ' "$JSONL_FILE" 2>/dev/null) || ERRORS_JSON="[]"
fi

# ─── Files Explored ───────────────────────────────────────────────
echo "Files Explored:"
if [ "$HAS_DATA" -eq 1 ] && [ -n "$FILES_JSON" ] && [ "$FILES_JSON" != "{}" ]; then
  # Build chronological tag string per file from raw JSONL, then display
  while IFS=$'\t' read -r fpath reads edits; do
    [ -z "$fpath" ] && continue
    # Build tag string: we only know totals from aggregated data
    # Reconstruct a simplified [RRREE] from reads/edits counts
    TAGS=""
    r=0; while [ "$r" -lt "$reads" ] && [ "${#TAGS}" -lt 8 ]; do TAGS="${TAGS}R"; r=$((r+1)); done
    e=0; while [ "$e" -lt "$edits" ] && [ "${#TAGS}" -lt 8 ]; do TAGS="${TAGS}E"; e=$((e+1)); done
    # Truncate path for display
    DISPLAY_PATH="$fpath"
    if [ "${#fpath}" -gt 40 ]; then
      DISPLAY_PATH="...${fpath: -37}"
    fi
    printf '  %-42s [%s]\n' "$DISPLAY_PATH" "$TAGS"
  done < <(echo "$FILES_JSON" | jq -r 'to_entries[] | [.key, (.value.reads | tostring), (.value.edits | tostring)] | @tsv' 2>/dev/null)
else
  echo "  (none tracked yet)"
fi
echo ""

# ─── Commands Run ─────────────────────────────────────────────────
echo "Commands Run:"
if [ "$HAS_DATA" -eq 1 ] && [ -n "$CMDS_JSON" ] && [ "$CMDS_JSON" != "[]" ]; then
  CMD_COUNT=$(echo "$CMDS_JSON" | jq 'length' 2>/dev/null) || CMD_COUNT=0
  if [ "${CMD_COUNT:-0}" -gt 0 ]; then
    while IFS=$'\t' read -r cmd exit_code; do
      [ -z "$cmd" ] && continue
      # Truncate long commands
      DISPLAY_CMD="$cmd"
      if [ "${#cmd}" -gt 50 ]; then
        DISPLAY_CMD="${cmd:0:47}..."
      fi
      if [ "${exit_code:-0}" -eq 0 ]; then
        printf '%b  %s (exit %s)%b\n' "$GREEN" "$DISPLAY_CMD" "$exit_code" "$RESET"
      else
        printf '%b  %s (exit %s)%b\n' "$RED" "$DISPLAY_CMD" "$exit_code" "$RESET"
      fi
    done < <(echo "$CMDS_JSON" | jq -r '.[] | [.cmd, (.exit | tostring)] | @tsv' 2>/dev/null)
  else
    echo "  (none tracked yet)"
  fi
else
  echo "  (none tracked yet)"
fi
echo ""

# ─── Errors ───────────────────────────────────────────────────────
RESOLVED_COUNT=0
OPEN_COUNT=0
if [ "$HAS_DATA" -eq 1 ] && [ -n "$ERRORS_JSON" ] && [ "$ERRORS_JSON" != "[]" ]; then
  RESOLVED_COUNT=$(echo "$ERRORS_JSON" | jq '[.[] | select(.resolved == true)] | length' 2>/dev/null) || RESOLVED_COUNT=0
  OPEN_COUNT=$(echo "$ERRORS_JSON" | jq '[.[] | select(.resolved == false)] | length' 2>/dev/null) || OPEN_COUNT=0
fi

printf 'Errors: '
if [ "${RESOLVED_COUNT:-0}" -gt 0 ]; then
  printf '%b%d resolved%b' "$GREEN" "$RESOLVED_COUNT" "$RESET"
else
  printf '0 resolved'
fi
printf ', '
if [ "${OPEN_COUNT:-0}" -gt 0 ]; then
  printf '%b%d open%b\n' "$RED" "$OPEN_COUNT" "$RESET"
else
  printf '0 open\n'
fi

# ─── Burn Rate ────────────────────────────────────────────────────
GROWTH_FILE=""
if [ -n "$SESSION_ID" ]; then
  GROWTH_FILE="/tmp/remembrall-growth/$SESSION_ID"
fi

if [ -n "$GROWTH_FILE" ] && [ -f "$GROWTH_FILE" ]; then
  # Compute average growth per prompt from the growth file
  AVG_GROWTH=$(awk '
    NR>1 { delta = $1 - prev; if (delta > 0) { sum += delta; count++ } }
    { prev = $1 }
    END { if (count > 0) printf "%d", sum/count; else print "0" }
  ' "$GROWTH_FILE" 2>/dev/null) || AVG_GROWTH=0

  if [ "${AVG_GROWTH:-0}" -gt 0 ]; then
    AVG_KB=$(( AVG_GROWTH / 1024 ))
    [ "$AVG_KB" -eq 0 ] && AVG_KB=1

    # Estimate prompts to warning threshold (20%)
    CONTENT_MAX=$(remembrall_calibrated_content_max 2>/dev/null) || CONTENT_MAX=""
    if [ -z "$CONTENT_MAX" ] || [ "${CONTENT_MAX:-0}" -eq 0 ] 2>/dev/null; then
      CONTENT_MAX=$(remembrall_default_content_max 2>/dev/null) || CONTENT_MAX=337920
    fi

    if [ -n "$CTX_PCT" ] && [ "${CTX_PCT:-0}" -gt 0 ] 2>/dev/null; then
      CURRENT_BYTES=$(( CONTENT_MAX * (100 - CTX_PCT) / 100 ))
      THRESHOLD_BYTES=$(( CONTENT_MAX * 80 / 100 ))
      BYTES_TO_WARNING=$(( THRESHOLD_BYTES - CURRENT_BYTES ))
      if [ "$BYTES_TO_WARNING" -gt 0 ] && [ "$AVG_GROWTH" -gt 0 ]; then
        PROMPTS_LEFT=$(( BYTES_TO_WARNING / AVG_GROWTH ))
        printf 'Burn Rate: ~%dKB/prompt (~%d prompts to warning)\n' "$AVG_KB" "$PROMPTS_LEFT"
      else
        printf 'Burn Rate: ~%dKB/prompt\n' "$AVG_KB"
      fi
    else
      printf 'Burn Rate: ~%dKB/prompt\n' "$AVG_KB"
    fi
  else
    echo "Burn Rate: not enough data"
  fi
else
  echo "Burn Rate: not enough data"
fi

# ─── Budget ───────────────────────────────────────────────────────
BUDGET_DIR=$(remembrall_budget_dir)
if [ -n "$SESSION_ID" ] && [ -f "$BUDGET_DIR/${SESSION_ID}.json" ]; then
  echo ""
  B_CODE=$(jq -r '.code_pct // 0' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null)
  B_CONV=$(jq -r '.conversation_pct // 0' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null)
  B_MEM=$(jq -r '.memory_pct // 0' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null)
  printf 'Budget: code %d%% | conversation %d%% | memory %d%%\n' "$B_CODE" "$B_CONV" "$B_MEM"

  # Show warnings
  WARNING_COUNT=$(jq '.warnings | length' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null) || WARNING_COUNT=0
  if [ "$WARNING_COUNT" -gt 0 ]; then
    if [ "$EASTER_EGGS" = "true" ]; then
      _top_cat=$(jq -r '.warnings[0].category // "unknown"' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null)
      _top_pct=$(jq -r '.warnings[0].actual // 0' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null)
      _house="Ravenclaw"
      case "$_top_cat" in
        conversation) _house="Gryffindor" ;;
        memory) _house="Hufflepuff" ;;
      esac
      printf '%b  The Sorting Hat detects an imbalance! %s has claimed %d%% of the common room.%b\n' "$YELLOW" "$_house" "$_top_pct" "$RESET"
    else
      jq -r '.warnings[] | "  Warning: \(.category) at \(.actual)% (budget: \(.budget)%)"' "$BUDGET_DIR/${SESSION_ID}.json" 2>/dev/null
    fi
  fi
fi

# ─── Time-Turner ──────────────────────────────────────────────────
TT_BASE="/tmp/remembrall-timeturner"
TT_STATUS="not active"
if [ -d "$TT_BASE" ]; then
  for status_file in "$TT_BASE"/*/status; do
    [ -f "$status_file" ] || continue
    STATUS=$(cat "$status_file" 2>/dev/null) || continue
    TT_DIR=$(dirname "$status_file")
    case "$STATUS" in
      completed)
        FILES_CHANGED=0
        [ -f "$TT_DIR/files_changed" ] && FILES_CHANGED=$(cat "$TT_DIR/files_changed" 2>/dev/null | tr -d '[:space:]') || true
        TT_STATUS="completed (${FILES_CHANGED} files changed)"
        ;;
      running)
        ELAPSED=0
        if [ -f "$TT_DIR/started" ]; then
          STARTED=$(cat "$TT_DIR/started" 2>/dev/null | tr -d '[:space:]') || STARTED=0
          NOW_TS=$(date +%s 2>/dev/null) || NOW_TS=0
          if [ -n "$STARTED" ] && [ "$STARTED" -gt 0 ] 2>/dev/null; then
            ELAPSED=$(( (NOW_TS - STARTED) / 60 ))
          fi
        fi
        TT_STATUS="running (${ELAPSED}m elapsed)"
        ;;
    esac
    break
  done
fi
printf 'Time-Turner: %s\n' "$TT_STATUS"

# ─── Easter egg footer ────────────────────────────────────────────
if [ "$EASTER_EGGS" = "true" ]; then
  echo ""
  printf '%b\n' "${YELLOW}Mischief managed.${RESET}"
fi
