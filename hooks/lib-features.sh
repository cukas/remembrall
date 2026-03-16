#!/usr/bin/env bash
# sourced by lib.sh
# lib-features.sh — Lineage, Insights, Obliviate, Budget, Patrol, Phoenix

# ─── Session Lineage (v3.0.0) ──────────────────────────────────

# Lineage storage directory per project
# Usage: remembrall_lineage_dir "/path/to/project"
remembrall_lineage_dir() {
  local cwd="${1:-.}"
  local hash
  hash=$(remembrall_md5 "$cwd" | cut -c1-8)
  local name
  name=$(basename "$cwd")
  [ "$name" = "." ] && name="default"
  echo "$HOME/.remembrall/lineage/${name}-${hash}"
}

# Record a session in the lineage index (atomic JSON append)
# Usage: remembrall_lineage_record session_id parent_id cwd type status goal files_count
remembrall_lineage_record() {
  local session_id="$1"
  local parent_id="${2:-}"
  local cwd="${3:-.}"
  local type="${4:-normal}"
  local status="${5:-active}"
  local goal="${6:-}"
  local files_count="${7:-0}"

  [ "$(remembrall_config "lineage" "true")" = "true" ] || return 0

  local dir
  dir=$(remembrall_lineage_dir "$cwd")
  mkdir -p "$dir"

  local index="$dir/index.json"
  local max_entries
  max_entries=$(remembrall_config "lineage_max_entries" "50")
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local entry
  entry=$(jq -n \
    --arg sid "$session_id" \
    --arg pid "$parent_id" \
    --arg type "$type" \
    --arg status "$status" \
    --arg goal "$goal" \
    --argjson files "$files_count" \
    --arg ts "$now" \
    '{session_id: $sid, parent_id: $pid, type: $type, status: $status, goal: $goal, files_touched: $files, timestamp: $ts}')

  # Lock to prevent concurrent writers from losing records
  local lock_dir="${index}.lock"
  local _got_lock=false
  for _i in 1 2 3 4 5; do
    if mkdir "$lock_dir" 2>/dev/null; then
      _got_lock=true
      # shellcheck disable=SC2064
      trap "rmdir '$lock_dir' 2>/dev/null || true" EXIT
      break
    fi
    sleep 0.1
  done
  if [ "$_got_lock" = false ]; then
    remembrall_debug "lineage: failed to acquire lock on $index"
    return 0
  fi

  if [ -f "$index" ]; then
    # Update existing entry or append
    local exists
    exists=$(jq --arg sid "$session_id" '[.sessions[] | select(.session_id == $sid)] | length' "$index" 2>/dev/null) || exists=0
    local tmp
    tmp=$(mktemp "${index}.XXXXXX")
    if [ "$exists" -gt 0 ]; then
      jq --argjson entry "$entry" '
        .sessions = [.sessions[] | if .session_id == ($entry.session_id) then $entry else . end]
      ' "$index" > "$tmp" 2>/dev/null
    else
      jq --argjson entry "$entry" --argjson max "$max_entries" '
        .sessions += [$entry] | .sessions = .sessions[-$max:]
      ' "$index" > "$tmp" 2>/dev/null
    fi
    if [ -s "$tmp" ]; then
      mv "$tmp" "$index"
    else
      rm -f "$tmp"
    fi
  else
    printf '{"sessions":[%s]}' "$entry" | jq '.' > "$index" 2>/dev/null
  fi

  # Release lock
  [ "$_got_lock" = true ] && rmdir "$lock_dir" 2>/dev/null || true
}

# Walk parent chain to compute depth
# Usage: remembrall_lineage_depth cwd session_id
remembrall_lineage_depth() {
  local cwd="${1:-.}"
  local session_id="$2"

  local dir
  dir=$(remembrall_lineage_dir "$cwd")
  local index="$dir/index.json"
  [ -f "$index" ] || { echo "0"; return; }

  local depth=0
  local current="$session_id"
  while [ -n "$current" ] && [ "$depth" -lt 100 ]; do
    local parent
    parent=$(jq -r --arg sid "$current" '.sessions[] | select(.session_id == $sid) | .parent_id // empty' "$index" 2>/dev/null)
    if [ -z "$parent" ]; then
      break
    fi
    depth=$((depth + 1))
    current="$parent"
  done
  echo "$depth"
}

# Count sessions sharing the same parent (branches/forks)
# Usage: remembrall_lineage_branches cwd
remembrall_lineage_branches() {
  local cwd="${1:-.}"

  local dir
  dir=$(remembrall_lineage_dir "$cwd")
  local index="$dir/index.json"
  [ -f "$index" ] || { echo "0"; return; }

  jq '[.sessions[] | select(.parent_id != "" and .parent_id != null) | .parent_id] | group_by(.) | map(select(length > 1)) | length' "$index" 2>/dev/null || echo "0"
}

# ─── Ambient Learning / Insights (v3.0.0) ───────────────────────

# Insights storage directory per project
# Usage: remembrall_insights_dir "/path/to/project"
remembrall_insights_dir() {
  local cwd="${1:-.}"
  local hash
  hash=$(remembrall_md5 "$cwd" | cut -c1-8)
  local name
  name=$(basename "$cwd")
  [ "$name" = "." ] && name="default"
  echo "$HOME/.remembrall/insights/${name}-${hash}"
}

# Check if insights are fresh (< 1 hour old)
# Usage: remembrall_insights_fresh "/path/to/project"
remembrall_insights_fresh() {
  local cwd="${1:-.}"
  local dir
  dir=$(remembrall_insights_dir "$cwd")
  local insights_file="$dir/insights.json"
  [ -f "$insights_file" ] || return 1
  local age
  age=$(remembrall_file_age "$insights_file")
  [ "$age" -lt 3600 ]
}

# ─── Obliviate / Semantic Context Pruning (v3.0.0) ──────────────

# Glob all memory directories
# Usage: remembrall_memory_dirs
remembrall_memory_dirs() {
  local dirs=()
  for d in "$HOME"/.claude/projects/*/memory/; do
    [ -d "$d" ] && dirs+=("$d")
  done
  printf '%s\n' "${dirs[@]}"
}

# Obliviate temp directory
# Usage: remembrall_obliviate_dir
remembrall_obliviate_dir() {
  echo "/tmp/remembrall-obliviate"
}

# Analyze memory staleness by cross-referencing with Pensieve data
# Usage: remembrall_analyze_memory_staleness cwd pensieve_dir
# Returns JSON: [{file, stale, reason, last_referenced}]
remembrall_analyze_memory_staleness() {
  local cwd="${1:-.}"
  local pensieve_dir="${2:-}"

  # Find memory dir: try multiple path formats
  # Claude Code uses: ~/.claude/projects/-Users-name-project/memory/
  local memory_dir=""
  local project_hash
  project_hash=$(printf '%s' "$cwd" | sed 's|/|-|g; s|^-||')
  # Try: exact match, dash-prefixed, Claude's format
  for _candidate in \
    "$HOME/.claude/projects/${project_hash}/memory" \
    "$HOME/.claude/projects/-${project_hash}/memory"; do
    if [ -d "$_candidate" ]; then
      memory_dir="$_candidate"
      break
    fi
  done

  [ -n "$memory_dir" ] && [ -d "$memory_dir" ] || { echo "[]"; return; }

  local stale_sessions
  stale_sessions=$(remembrall_config "obliviate_stale_sessions" "5")

  local results="[]"
  for mem_file in "$memory_dir"/*.md; do
    [ -f "$mem_file" ] || continue
    local basename_f
    basename_f=$(basename "$mem_file")
    [ "$basename_f" = "MEMORY.md" ] && continue

    local age_hours
    age_hours=$(( $(remembrall_file_age "$mem_file") / 3600 ))
    local stale=false
    local reason=""

    # Stale if not modified in stale_sessions worth of time (approx 1 session = 2h)
    local stale_hours
    stale_hours=$(( stale_sessions * 2 ))
    if [ "$age_hours" -gt "$stale_hours" ]; then
      stale=true
      reason="Not updated in ${age_hours}h (threshold: ${stale_hours}h)"
    fi

    # Check Pensieve for recent references (reduces staleness)
    if [ "$stale" = true ] && [ -n "$pensieve_dir" ] && [ -d "$pensieve_dir" ]; then
      local referenced
      referenced=$(jq -r '.files | keys[]' "$pensieve_dir"/session-*.json 2>/dev/null | { grep -cF "$basename_f" || echo 0; }) || referenced=0
      if [ "$referenced" -gt 0 ]; then
        stale=false
        reason="Referenced in $referenced Pensieve session(s) — not stale"
      fi
    fi

    results=$(echo "$results" | jq --arg file "$basename_f" --arg path "$mem_file" \
      --argjson stale "$stale" --arg reason "$reason" --argjson age "$age_hours" \
      '. += [{"file": $file, "path": $path, "stale": $stale, "reason": $reason, "age_hours": $age}]')
  done

  echo "$results"
}

# ─── Context Budget Allocation (v3.0.0) ─────────────────────────

# Budget temp directory
# Usage: remembrall_budget_dir
remembrall_budget_dir() {
  echo "/tmp/remembrall-budget"
}

# Categorize transcript content into code/conversation/memory bytes
# Usage: remembrall_extract_category_bytes transcript_path
# Output: code_bytes\tconversation_bytes\tmemory_bytes
remembrall_extract_category_bytes() {
  local transcript="$1"
  [ -f "$transcript" ] || { printf '0\t0\t0'; return; }

  jq -r '
    def str_bytes: (. // "") | tostring | length;
    reduce .[] as $row (
      {code: 0, conversation: 0, memory: 0};
      if $row.type == "assistant" then
        reduce ($row.content // [])[] as $c (.;
          if $c.type == "tool_use" or $c.type == "tool_result" then
            .code += ($c | tostring | length)
          elif $c.type == "text" then
            .conversation += ($c.text | str_bytes)
          else .
          end
        )
      elif $row.type == "user" then
        reduce ($row.content // [])[] as $c (.;
          if $c.type == "tool_result" then
            .code += ($c | tostring | length)
          elif $c.type == "text" then
            if ($c.text // "" | test("REMEMBRALL|additionalContext|hookSpecificOutput")) then
              .memory += ($c.text | str_bytes)
            else
              .conversation += ($c.text | str_bytes)
            end
          else .
          end
        )
      elif $row.type == "system" then
        .memory += ($row | tostring | length)
      else .
      end
    ) | [.code, .conversation, .memory] | map(tostring) | join("\t")
  ' "$transcript" 2>/dev/null || printf '0\t0\t0'
}

# Check budget allocation vs configured limits
# Usage: remembrall_budget_check session_id
# Output: JSON with actuals, configured, and warnings
remembrall_budget_check() {
  local session_id="$1"
  local budget_dir
  budget_dir=$(remembrall_budget_dir)
  local budget_file="$budget_dir/${session_id}.json"
  [ -f "$budget_file" ] || { echo "{}"; return; }

  local code_pct conversation_pct memory_pct
  code_pct=$(jq -r '.code_pct // 0' "$budget_file" 2>/dev/null)
  conversation_pct=$(jq -r '.conversation_pct // 0' "$budget_file" 2>/dev/null)
  memory_pct=$(jq -r '.memory_pct // 0' "$budget_file" 2>/dev/null)

  local cfg_code cfg_conv cfg_mem
  cfg_code=$(remembrall_config "budget_code" "50")
  cfg_conv=$(remembrall_config "budget_conversation" "30")
  cfg_mem=$(remembrall_config "budget_memory" "20")

  local warnings="[]"
  # Warn if any category exceeds its budget by >10 percentage points
  # Use integer shell arithmetic (values from jq are already integers)
  local _code_diff=$(( ${code_pct%%.*} - ${cfg_code%%.*} ))
  local _conv_diff=$(( ${conversation_pct%%.*} - ${cfg_conv%%.*} ))
  local _mem_diff=$(( ${memory_pct%%.*} - ${cfg_mem%%.*} ))
  if [ "$_code_diff" -gt 10 ]; then
    warnings=$(echo "$warnings" | jq '. += ["code over budget"]')
  fi
  if [ "$_conv_diff" -gt 10 ]; then
    warnings=$(echo "$warnings" | jq '. += ["conversation over budget"]')
  fi
  if [ "$_mem_diff" -gt 10 ]; then
    warnings=$(echo "$warnings" | jq '. += ["memory over budget"]')
  fi

  jq -n \
    --argjson code_pct "$code_pct" \
    --argjson conv_pct "$conversation_pct" \
    --argjson mem_pct "$memory_pct" \
    --argjson cfg_code "$cfg_code" \
    --argjson cfg_conv "$cfg_conv" \
    --argjson cfg_mem "$cfg_mem" \
    --argjson warnings "$warnings" \
    '{actual: {code: $code_pct, conversation: $conv_pct, memory: $mem_pct}, configured: {code: $cfg_code, conversation: $cfg_conv, memory: $cfg_mem}, warnings: $warnings}'
}

# Validate budget percentages sum to 100
# Usage: remembrall_budget_validate_total
# Returns 0 if valid, 1 if not
remembrall_budget_validate_total() {
  local code conv mem
  code=$(remembrall_config "budget_code" "50")
  conv=$(remembrall_config "budget_conversation" "30")
  mem=$(remembrall_config "budget_memory" "20")
  local total=$((code + conv + mem))
  [ "$total" -eq 100 ]
}

# ─── Patrol Integration (v3.0.0) ────────────────────────────────

# Signal directory for Patrol ↔ Remembrall communication
# Usage: remembrall_signal_dir
remembrall_signal_dir() {
  echo "/tmp/remembrall-signals"
}

# Check for Patrol signal files
# Usage: remembrall_check_patrol_signal session_id
# Returns signal type or empty
remembrall_check_patrol_signal() {
  local session_id="$1"
  [ "$(remembrall_config "patrol_integration" "true")" = "true" ] || return 0

  local signal_dir
  signal_dir="$(remembrall_signal_dir)/${session_id}"
  [ -d "$signal_dir" ] || return 0

  local ttl
  ttl=$(remembrall_config "patrol_signal_ttl" "300")

  for signal_file in "$signal_dir"/*.json; do
    [ -f "$signal_file" ] || continue
    local age
    age=$(remembrall_file_age "$signal_file")
    if [ "$age" -lt "$ttl" ]; then
      local signal_type
      signal_type=$(basename "$signal_file" .json)
      echo "$signal_type"
      return 0
    else
      # Expired — clean up
      rm -f "$signal_file"
    fi
  done
}

# Read and consume a signal file (read payload, delete file)
# Usage: remembrall_consume_signal session_id signal_type
# Returns signal payload JSON
remembrall_consume_signal() {
  local session_id="$1"
  local signal_type="$2"
  local signal_dir
  signal_dir="$(remembrall_signal_dir)/${session_id}"
  local signal_file="$signal_dir/${signal_type}.json"

  if [ -f "$signal_file" ]; then
    cat "$signal_file"
    rm -f "$signal_file"
    # Clean up empty dir
    rmdir "$signal_dir" 2>/dev/null || true
  fi
}

# ─── Phoenix: recurring context recycling ─────────────────────────

PHOENIX_DIR="/tmp/remembrall-phoenix"

# Get chain ID for a session
# Usage: remembrall_phoenix_chain_id session_id
remembrall_phoenix_chain_id() {
  local session_id="$1"
  local chain_file="$PHOENIX_DIR/chain-${session_id}"
  if [ -f "$chain_file" ]; then
    cat "$chain_file"
  fi
}

# Set chain ID for a session
# Usage: remembrall_phoenix_set_chain session_id chain_id
remembrall_phoenix_set_chain() {
  local session_id="$1"
  local chain_id="$2"
  mkdir -p "$PHOENIX_DIR"
  printf '%s' "$chain_id" > "$PHOENIX_DIR/chain-${session_id}"
}

# Get cycle count for a chain
# Usage: remembrall_phoenix_cycle_count chain_id
remembrall_phoenix_cycle_count() {
  local chain_id="$1"
  local cycle_file="$PHOENIX_DIR/${chain_id}.cycle"
  if [ -f "$cycle_file" ]; then
    cat "$cycle_file"
  else
    echo "0"
  fi
}

# Increment cycle count for a chain
# Usage: remembrall_phoenix_increment chain_id
remembrall_phoenix_increment() {
  local chain_id="$1"
  mkdir -p "$PHOENIX_DIR"
  local cycle_file="$PHOENIX_DIR/${chain_id}.cycle"
  local current=0
  if [ -f "$cycle_file" ]; then
    current=$(cat "$cycle_file")
  fi
  echo $((current + 1)) > "$cycle_file"
}

# Record a cycle in the chain's lineage
# Usage: remembrall_phoenix_record chain_id session_id cycle
remembrall_phoenix_record() {
  local chain_id="$1"
  local session_id="$2"
  local cycle="$3"
  mkdir -p "$PHOENIX_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$session_id" "$cycle" "$chain_id" >> "$PHOENIX_DIR/${chain_id}.lineage"
}

# Check if Patrol is installed (for status display)
# Usage: remembrall_patrol_detected
remembrall_patrol_detected() {
  # Check common Patrol installation paths
  [ -d "$HOME/.claude/plugins/cache/cukas/patrol" ] && return 0
  [ -d "$HOME/.claude/plugins/patrol" ] && return 0
  command -v patrol >/dev/null 2>&1 && return 0
  return 1
}
