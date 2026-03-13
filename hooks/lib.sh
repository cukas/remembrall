#!/usr/bin/env bash
# Shared helpers for remembrall hooks

# ─── Debug Logging ─────────────────────────────────────────────────
# Enable via config: remembrall_config_set "debug" "true"
# Or env: REMEMBRALL_DEBUG=1
# Logs to ~/.remembrall/debug.log (rotated at 1MB)

remembrall_debug() {
  # Fast path: check cached env var (no jq call after first invocation)
  case "${_REMEMBRALL_DEBUG_CACHED:-}" in
    0) return 0 ;;  # debug off — cached
    1) ;;           # debug on — fall through to log
    *)
      # First call: resolve from env or config, then cache
      if [ "${REMEMBRALL_DEBUG:-}" = "1" ]; then
        export _REMEMBRALL_DEBUG_CACHED=1
      else
        local debug_enabled
        debug_enabled=$(remembrall_config "debug" "false" 2>/dev/null)
        if [ "$debug_enabled" = "true" ]; then
          export _REMEMBRALL_DEBUG_CACHED=1
        else
          export _REMEMBRALL_DEBUG_CACHED=0
          return 0
        fi
      fi
      ;;
  esac

  local log_file="$HOME/.remembrall/debug.log"
  mkdir -p "$HOME/.remembrall" 2>/dev/null

  # Rotate at 1MB
  if [ -f "$log_file" ]; then
    local size
    size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ')
    if [ "${size:-0}" -gt 1048576 ] 2>/dev/null; then
      mv "$log_file" "${log_file}.1" 2>/dev/null
    fi
  fi

  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${REMEMBRALL_HOOK:-remembrall}" "$*" >> "$log_file" 2>/dev/null
}

# ─── Configurable Thresholds ──────────────────────────────────────
# Users can override nudge thresholds via config.json:
#   threshold_journal (default: 60) — first nudge: "run /handoff"
#   threshold_warning (default: 35) — second nudge: "run /handoff then EnterPlanMode"
#   threshold_urgent  (default: 15) — final nudge: two-stage block

remembrall_threshold() {
  local name="$1"
  local default="$2"
  local val
  val=$(remembrall_config "threshold_${name}" "$default" 2>/dev/null)
  if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] && [ "$val" -lt 100 ] 2>/dev/null; then
    echo "$val"
  else
    echo "$default"
  fi
}

# Require jq — exit gracefully if not available
remembrall_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "remembrall: jq not found — hook disabled" >&2
    exit 0
  fi
}

# Cross-platform md5 hash
remembrall_md5() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -qs "$1"
  elif command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  else
    return 1
  fi
}

# Find bridge file for a session.
# Bridge is keyed by session_id only (not CWD) because the status line's
# workspace.current_dir can differ from the hook's CWD.
# Without session_id: reads the published session_id for the CWD (diagnostics).
# Bridge is invalidated on compact/clear by session-resume.sh.
remembrall_find_bridge() {
  local cwd="$1"
  local session_id="$2"
  local ctx_dir="/tmp/claude-context-pct"

  # Without session_id: try published session_id for this CWD (diagnostic use)
  if [ -z "$session_id" ]; then
    session_id=$(remembrall_read_session_id "$cwd" 2>/dev/null)
  fi

  [ -z "$session_id" ] && return 1

  local f="$ctx_dir/$session_id"
  if [ -f "$f" ]; then
    echo "$f"
    return 0
  fi

  return 1
}

# Compute handoff directory for a given CWD
# Uses project basename + short hash suffix for readability + collision safety
# e.g., ~/.remembrall/handoffs/ai-buddies-8f9a0596/
# Falls back to legacy full-hash format (~/.remembrall/handoffs/{md5}) for v2.x compat
remembrall_handoff_dir() {
  local cwd="$1"
  local full_hash
  full_hash=$(remembrall_md5 "$cwd") || return 1
  # v3 format: name-shortHash
  local project_name
  project_name=$(basename "$cwd")
  project_name=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | sed 's/^\.*//' | sed 's/[^a-z0-9_-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  [ -z "$project_name" ] && project_name="default"
  local short_hash
  short_hash=$(printf '%s' "$full_hash" | cut -c1-8)
  local new_dir="$HOME/.remembrall/handoffs/${project_name}-${short_hash}"
  local old_dir="$HOME/.remembrall/handoffs/${full_hash}"
  # Prefer new format; fall back to legacy if it exists and new doesn't
  if [ -d "$new_dir" ]; then
    echo "$new_dir"
  elif [ -d "$old_dir" ]; then
    echo "$old_dir"
  else
    echo "$new_dir"
  fi
}

# Cross-platform file age in seconds (returns 0 on stat failure)
remembrall_file_age() {
  local file="$1"
  local mtime
  if [ "$(uname)" = "Darwin" ]; then
    mtime=$(stat -f %m "$file" 2>/dev/null) || { echo 0; return; }
  else
    mtime=$(stat -c %Y "$file" 2>/dev/null) || { echo 0; return; }
  fi
  echo $(( $(date +%s) - mtime ))
}

# JSON-safe string escaping using jq (RFC 8259 compliant)
remembrall_escape_json() {
  printf '%s' "$1" | jq -Rs . | sed 's/^"//;s/"$//'
}

# Validate that a value is a number (integer or decimal)
remembrall_validate_number() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# Estimate context remaining from transcript.
# Used as a fallback when the status-line bridge is not configured.
# Returns estimated remaining % on stdout, or exits 1 if no estimate possible.
#
# Strategy (in order):
#   1. Structural JSONL parser — most accurate, parses by message role
#   2. File-size estimation — simple total_bytes / max_bytes fallback
#
# Self-calibrating: after the first compaction, remembrall records the actual
# transcript size at which context ran out. Subsequent sessions use the
# calibrated value instead of the default, improving accuracy over time.
remembrall_estimate_context() {
  local transcript_path="$1"
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 1
  fi

  # Try structural estimation first (Phase 2 — more accurate)
  local structural_result
  structural_result=$(remembrall_estimate_context_structural "$transcript_path" 2>/dev/null)
  if [ -n "$structural_result" ]; then
    echo "$structural_result"
    return 0
  fi

  # Fallback: simple file-size estimation
  local size
  size=$(wc -c < "$transcript_path" 2>/dev/null) || return 1
  size=$(echo "$size" | tr -d ' ')

  # Use calibrated max if available, otherwise model-aware default
  local max_bytes
  max_bytes=$(remembrall_calibrated_max "$transcript_path")
  if [ -z "$max_bytes" ] || [ "$max_bytes" -eq 0 ] 2>/dev/null; then
    # Check user config override first
    local max_kb
    max_kb=$(remembrall_config "max_transcript_kb" "")
    if [ -n "$max_kb" ] && [[ "$max_kb" =~ ^[0-9]+$ ]]; then
      max_bytes=$((max_kb * 1024))
    else
      # Model-aware default: detect model and use per-model max
      local model_info
      model_info=$(remembrall_detect_model "$transcript_path")
      local _m _w _b model_max_kb
      IFS=$'\t' read -r _m _w _b model_max_kb <<< "$model_info"
      max_bytes=$((model_max_kb * 1024))
    fi
  fi

  # Too small to estimate reliably (<40% of expected max)
  if [ "$size" -lt $((max_bytes * 40 / 100)) ]; then
    return 1
  fi

  local used_pct=$((size * 100 / max_bytes))
  if [ "$used_pct" -gt 100 ]; then
    used_pct=100
  fi
  local remaining=$((100 - used_pct))

  # Floor at 5% — never report 0
  if [ "$remaining" -lt 5 ]; then
    remaining=5
  fi

  echo "$remaining"
}

# ─── Model Default Content Max ────────────────────────────────────
# Single source of truth for model-specific content_max defaults.
# Used when no calibration data is available yet.
remembrall_default_content_max() {
  local model_name="${1:-unknown}"
  case "$model_name" in
    claude-opus-4-6*|claude-opus-4*)     echo 358400 ;;  # ~350KB
    claude-sonnet-4-6*|claude-sonnet-4*) echo 337920 ;;  # ~330KB
    claude-haiku-4-5*|claude-haiku-4*)   echo 317440 ;;  # ~310KB
    *)                                    echo 337920 ;;  # ~330KB default
  esac
}

# ─── Content Bytes Extraction ─────────────────────────────────────

# Single source of truth for extracting content bytes from a transcript.
# Sums text, tool_use input, thinking, and tool_result content lengths.
# Skips JSON structural overhead and non-context message types.
remembrall_extract_content_bytes() {
  local transcript_path="$1"
  [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ] && return 1
  jq -r '
    [.message.content[]? |
      if .type == "text" then (.text // "" | length)
      elif .type == "tool_use" then (.input | tostring | length)
      elif .type == "thinking" then (.thinking // "" | length)
      elif .type == "tool_result" then (.content // "" | tostring | length)
      else 0 end
    ] | add // 0
  ' "$transcript_path" 2>/dev/null | awk '{s+=$1} END {printf "%d", s}'
}

# ─── JSONL Structural Token Estimation ────────────────────────────

# Estimate tokens used from transcript by parsing JSONL structure.
# Extracts actual content bytes (text, thinking, tool inputs/results) using jq.
# Skips JSON structural overhead (~79% of context lines) and non-context types.
#
# Returns estimated token count on stdout, or exits 1 if no estimate possible.
# Runs in <50ms on typical transcripts (1-2MB).
remembrall_estimate_tokens() {
  local transcript_path="$1"
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 1
  fi

  local content_bytes
  content_bytes=$(remembrall_extract_content_bytes "$transcript_path") || return 1
  [ "$content_bytes" -eq 0 ] 2>/dev/null && return 1

  # Get model-specific bytes/token ratio
  local model_info bpt_str
  model_info=$(remembrall_detect_model "$transcript_path")
  bpt_str=$(printf '%s' "$model_info" | cut -f3)

  # Integer arithmetic: multiply by 10 to handle one decimal place
  # e.g., 4.2 → 42, then divide result by 10
  # IMPORTANT: only works for values with exactly one decimal digit (e.g., 4.2, 3.8)
  local bpt_int
  bpt_int=$(printf '%s' "$bpt_str" | sed 's/\.//')
  [ -z "$bpt_int" ] && bpt_int=40

  local estimated_tokens=$(( (content_bytes * 10) / bpt_int ))

  echo "$estimated_tokens"
}

# Estimate context remaining % using structural JSONL parsing.
# More accurate than raw file size because it:
#   1. Extracts only actual content bytes (text, thinking, tool I/O)
#   2. Skips JSON wrapper fields (~79% of each line) and non-context types
#   3. Compares against calibrated content max (learned from compaction events)
#
# Content max varies by user setup (plugins, tools, CLAUDE.md size all affect
# overhead). Calibration learns the right value within 1-2 compaction events.
# Before calibration, uses conservative per-model defaults.
remembrall_estimate_context_structural() {
  local transcript_path="$1"
  local precomputed_bytes="${2:-}"
  local precomputed_model="${3:-}"
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 1
  fi

  local content_bytes
  if [ -n "$precomputed_bytes" ] && [ "$precomputed_bytes" -gt 0 ] 2>/dev/null; then
    content_bytes="$precomputed_bytes"
  else
    content_bytes=$(remembrall_extract_content_bytes "$transcript_path") || return 1
  fi
  [ "$content_bytes" -eq 0 ] 2>/dev/null && return 1

  # Detect model (needed for both content_max defaults and correction)
  local model_info model_name
  if [ -n "$precomputed_model" ] && [ "$precomputed_model" != "unknown" ]; then
    model_name="$precomputed_model"
  else
    model_info=$(remembrall_detect_model "$transcript_path")
    model_name=$(printf '%s' "$model_info" | cut -f1)
  fi

  # Get content max: calibrated per-model value, or default
  local content_max
  content_max=$(remembrall_calibrated_content_max "$transcript_path")
  if [ -z "$content_max" ] || [ "$content_max" -eq 0 ] 2>/dev/null; then
    content_max=$(remembrall_default_content_max "$model_name")
  fi

  # Too early to estimate reliably (<30% of content max used)
  if [ "$content_bytes" -lt $((content_max * 30 / 100)) ]; then
    return 1
  fi

  local used_pct=$((content_bytes * 100 / content_max))
  if [ "$used_pct" -gt 100 ]; then
    used_pct=100
  fi
  local remaining=$((100 - used_pct))

  # Floor at 5%
  if [ "$remaining" -lt 5 ]; then
    remaining=5
  fi

  # Apply correction from calibration pairs if available (Phase 5)
  if [ -n "$model_name" ] && [ "$model_name" != "unknown" ]; then
    remaining=$(remembrall_apply_correction "$remaining" "$model_name")
  fi

  echo "$remaining"
}

# Get calibrated content max (content bytes at compaction) for structural estimation.
# Priority: bridge-derived per-model → compaction-based per-model → compaction-based global.
# Bridge-derived is most accurate because it calibrates per-user overhead automatically.
# Returns empty if no calibration data exists (falls through to hardcoded defaults).
remembrall_calibrated_content_max() {
  local transcript_path="${1:-}"
  local cal_file="$HOME/.remembrall/calibration.json"
  [ -f "$cal_file" ] || return 0

  local avg=""

  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    local model_info model_name
    model_info=$(remembrall_detect_model "$transcript_path")
    model_name=$(printf '%s' "$model_info" | cut -f1)
    if [ -n "$model_name" ] && [ "$model_name" != "unknown" ]; then
      # 1. Bridge-derived content_max (best: auto-calibrated per user+model)
      avg=$(jq -r --arg m "$model_name" '
        if ((.models[$m].derived_content_max // []) | length) > 0 then
          ((.models[$m].derived_content_max | add) / (.models[$m].derived_content_max | length)) | floor
        else
          empty
        end
      ' "$cal_file" 2>/dev/null)

      # 2. Compaction-based content_samples (good: real compaction data)
      if [ -z "$avg" ]; then
        avg=$(jq -r --arg m "$model_name" '
          if ((.models[$m].content_samples // []) | length) > 0 then
            ((.models[$m].content_samples | add) / (.models[$m].content_samples | length)) | floor
          else
            empty
          end
        ' "$cal_file" 2>/dev/null)
      fi
    fi
  fi

  # 3. Global content samples (fallback)
  if [ -z "$avg" ]; then
    avg=$(jq -r '
      if ((.content_samples // []) | length) > 0 then
        ((.content_samples | add) / (.content_samples | length)) | floor
      else
        empty
      end
    ' "$cal_file" 2>/dev/null)
  fi

  echo "$avg"
}

# ─── Calibration File Locking ────────────────────────────────────

# Atomic read-modify-write for calibration.json.
# Uses flock when available, falls back to mkdir-based lock.
# Usage: remembrall_locked_cal_update 'jq expression' [--argjson k v ...]
remembrall_locked_cal_update() {
  local cal_file="$HOME/.remembrall/calibration.json"
  local lock_file="${cal_file}.lock"
  mkdir -p "$HOME/.remembrall"

  # Initialize if missing — canonical schema with all top-level keys
  [ ! -f "$cal_file" ] && echo '{"samples":[],"models":{},"pairs":{}}' > "$cal_file"

  local tmp
  tmp=$(mktemp "${cal_file}.XXXXXX")

  if command -v flock >/dev/null 2>&1; then
    (
      flock -x -w 5 9 || { rm -f "$tmp"; return 1; }
      jq "$@" "$cal_file" > "$tmp" 2>/dev/null && mv "$tmp" "$cal_file" || rm -f "$tmp"
    ) 9>"$lock_file"
  else
    # mkdir is atomic on POSIX — use as spinlock with timeout
    local attempts=0
    while ! mkdir "$lock_file" 2>/dev/null; do
      attempts=$((attempts + 1))
      [ "$attempts" -gt 50 ] && { rm -f "$tmp"; return 1; }
      # Clean stale locks (>10s old)
      local lock_age
      lock_age=$(remembrall_file_age "$lock_file" 2>/dev/null)
      [ "$lock_age" -gt 10 ] 2>/dev/null && rmdir "$lock_file" 2>/dev/null
      sleep 0.1
    done
    jq "$@" "$cal_file" > "$tmp" 2>/dev/null && mv "$tmp" "$cal_file" || rm -f "$tmp"
    rmdir "$lock_file" 2>/dev/null
  fi
}

# ─── Bridge-Derived Content Max ───────────────────────────────────

# Derive content_max from bridge truth and store for future estimation.
# When bridge is active: content_max = content_bytes / (used_pct / 100).
# This auto-calibrates per user — no hardcoded defaults needed after first bridge session.
# Requires ≥20% usage for stable measurement (small numbers = high noise).
# Stores rolling last 5 per model in calibration.json.
remembrall_store_derived_content_max() {
  local content_bytes="$1"
  local bridge_remaining="$2"
  local model_name="$3"

  [ -z "$content_bytes" ] || [ "$content_bytes" -le 0 ] 2>/dev/null && return
  [ -z "$bridge_remaining" ] && return
  [ -z "$model_name" ] || [ "$model_name" = "unknown" ] && return

  # Need ≥20% used for stable derivation (avoid noise at session start)
  local used_pct=$((100 - bridge_remaining))
  [ "$used_pct" -lt 20 ] 2>/dev/null && return

  # Derive: content_max = content_bytes / (used_pct / 100)
  local derived=$(( content_bytes * 100 / used_pct ))
  [ "$derived" -le 0 ] 2>/dev/null && return

  remembrall_locked_cal_update \
    --argjson d "$derived" --arg m "$model_name" \
    '.models //= {} |
    .models[$m] //= {} |
    .models[$m].derived_content_max = ((.models[$m].derived_content_max // []) + [$d])[-5:]'
}

# ─── Bridge-Paired Calibration ────────────────────────────────────

# Log a calibration pair when both bridge and structural estimates are available.
# Stores {content_bytes, bridge_pct, structural_pct, model, msg_count, timestamp}
# in calibration.json under .pairs[]. Keeps last 20 pairs per model.
remembrall_log_calibration_pair() {
  local transcript_path="$1"
  local bridge_pct="$2"
  local structural_pct="$3"
  local precomputed_bytes="${4:-}"
  local precomputed_model="${5:-}"

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 1
  fi

  local content_bytes
  if [ -n "$precomputed_bytes" ] && [ "$precomputed_bytes" -gt 0 ] 2>/dev/null; then
    content_bytes="$precomputed_bytes"
  else
    content_bytes=$(remembrall_extract_content_bytes "$transcript_path" 2>/dev/null)
  fi
  [ -z "$content_bytes" ] && content_bytes=0

  # Get model and message count
  local model_info model_name
  if [ -n "$precomputed_model" ] && [ "$precomputed_model" != "unknown" ]; then
    model_name="$precomputed_model"
  else
    model_info=$(remembrall_detect_model "$transcript_path")
    model_name=$(printf '%s' "$model_info" | cut -f1)
  fi

  local msg_count
  msg_count=$(wc -l < "$transcript_path" 2>/dev/null | tr -d ' ')
  [ -z "$msg_count" ] && msg_count=0

  local timestamp
  timestamp=$(date +%s)

  remembrall_locked_cal_update \
    --argjson cb "$content_bytes" \
    --argjson bp "$bridge_pct" \
    --argjson sp "$structural_pct" \
    --arg m "$model_name" \
    --argjson mc "$msg_count" \
    --argjson ts "$timestamp" \
    '.pairs //= {} |
    .pairs[$m] //= [] |
    .pairs[$m] += [{
      content_bytes: $cb,
      bridge_pct: $bp,
      structural_pct: $sp,
      model: $m,
      msg_count: $mc,
      timestamp: $ts
    }] |
    .pairs[$m] = .pairs[$m][-20:]'
}

# Compute correction offset from calibration pairs for a model.
# Returns the weighted average of (bridge_pct - structural_pct).
# Newer pairs weighted 2x vs older. Returns empty if <5 pairs.
remembrall_correction_offset() {
  local model_name="$1"
  local cal_file="$HOME/.remembrall/calibration.json"
  [ -f "$cal_file" ] || return 0

  local offset
  offset=$(jq -r --arg m "$model_name" '
    if (.pairs[$m] | length) >= 5 then
      (.pairs[$m] | length) as $len |
      (.pairs[$m] | to_entries |
        map(
          (.value.bridge_pct - .value.structural_pct) *
          (if .key >= ($len - ($len / 2 | floor)) then 2 else 1 end)
        ) | add) as $weighted_sum |
      (.pairs[$m] | to_entries |
        map(if .key >= ($len - ($len / 2 | floor)) then 2 else 1 end) | add
      ) as $weight_total |
      ($weighted_sum / $weight_total) | round
    else
      empty
    end
  ' "$cal_file" 2>/dev/null)

  echo "$offset"
}

# ─── Self-Correcting Feedback Loop ────────────────────────────────

# Apply correction offset to a structural estimate.
# Uses weighted moving average from calibration pairs.
# Caps correction at ±15% to prevent runaway corrections.
# Returns corrected % on stdout, or the original if no correction available.
remembrall_apply_correction() {
  local structural_pct="$1"
  local model_name="$2"

  local offset
  offset=$(remembrall_correction_offset "$model_name")
  if [ -z "$offset" ]; then
    echo "$structural_pct"
    return
  fi

  # Cap at ±15%
  if [ "$offset" -gt 15 ] 2>/dev/null; then
    offset=15
  elif [ "$offset" -lt -15 ] 2>/dev/null; then
    offset=-15
  fi

  local corrected=$((structural_pct + offset))

  # Clamp to 5-100
  if [ "$corrected" -gt 100 ]; then
    corrected=100
  elif [ "$corrected" -lt 5 ]; then
    corrected=5
  fi

  echo "remembrall: correction applied: ${offset}% offset for ${model_name} (${structural_pct}% → ${corrected}%)" >&2
  echo "$corrected"
}

# ─── Calibration ──────────────────────────────────────────────────

# Record transcript size at compaction for future estimation.
# Called by precompact-handoff.sh when context pressure triggers compaction.
# Stores last 5 measurements and uses the average as the calibrated max.
remembrall_calibrate() {
  local transcript_path="$1"
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 1
  fi

  local size
  size=$(wc -c < "$transcript_path" 2>/dev/null) || return 1
  size=$(echo "$size" | tr -d ' ')

  # Ignore tiny transcripts (likely not real compaction)
  if [ "$size" -lt 50000 ]; then
    return 0
  fi

  # Detect model for per-model calibration
  local model_info model_name
  model_info=$(remembrall_detect_model "$transcript_path")
  model_name=$(printf '%s' "$model_info" | cut -f1)

  local content_bytes
  content_bytes=$(remembrall_extract_content_bytes "$transcript_path" 2>/dev/null)
  [ -z "$content_bytes" ] && content_bytes=0

  # Append samples to global + per-model arrays (keep last 5 each)
  remembrall_locked_cal_update \
    --argjson s "$size" --argjson cb "$content_bytes" --arg m "$model_name" \
    '.samples += [$s] |
    .samples = .samples[-5:] |
    (if $cb > 0 then .content_samples = ((.content_samples // []) + [$cb])[-5:] else . end) |
    .models //= {} |
    .models[$m] //= {"samples":[],"content_samples":[]} |
    .models[$m].samples += [$s] |
    .models[$m].samples = .models[$m].samples[-5:] |
    (if $cb > 0 then .models[$m].content_samples = ((.models[$m].content_samples // []) + [$cb])[-5:] else . end) |
    .updated = now'
}

# Get calibrated max transcript size in bytes (average of stored samples).
# Checks per-model calibration first (Phase 3), falls back to global samples.
# Returns empty string if no calibration data exists.
remembrall_calibrated_max() {
  local transcript_path="${1:-}"
  local cal_file="$HOME/.remembrall/calibration.json"
  if [ ! -f "$cal_file" ]; then
    echo ""
    return
  fi

  local avg=""

  # Try per-model calibration first (Phase 3+)
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    local model_info model_name
    model_info=$(remembrall_detect_model "$transcript_path")
    model_name=$(printf '%s' "$model_info" | cut -f1)
    if [ -n "$model_name" ] && [ "$model_name" != "unknown" ]; then
      avg=$(jq -r --arg m "$model_name" '
        if (.models[$m].samples | length) > 0 then
          ((.models[$m].samples | add) / (.models[$m].samples | length)) | floor
        else
          empty
        end
      ' "$cal_file" 2>/dev/null)
    fi
  fi

  # Fallback to global samples
  if [ -z "$avg" ]; then
    avg=$(jq -r '
      if (.samples | length) > 0 then
        ((.samples | add) / (.samples | length)) | floor
      else
        empty
      end
    ' "$cal_file" 2>/dev/null)
  fi

  echo "$avg"
}

# ─── Model Detection ──────────────────────────────────────────────

# Detect model from transcript JSONL. Returns tab-separated:
#   model_name  window_tokens  bytes_per_token  max_transcript_kb
#
# Parses the first assistant message for .message.model.
# Falls back to "unknown" with safe defaults.
#
# max_transcript_kb is the expected total JSONL file size at compaction.
# Calibration data overrides this when available (Phase 5).
remembrall_detect_model() {
  local transcript_path="$1"
  local model="unknown"

  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    model=$(head -100 "$transcript_path" 2>/dev/null | \
      jq -r 'select(.type == "assistant" and .message.model != null) | .message.model' 2>/dev/null | \
      head -1)
    [ -z "$model" ] && model="unknown"
  fi

  # Lookup table: model → window_tokens, bytes_per_token, max_transcript_kb
  # max_transcript_kb = estimated total JSONL size at compaction
  # Based on observed data: Opus transcripts compact at ~1675KB
  local window=200000
  local bpt="4.2"
  local max_kb=1600
  case "$model" in
    claude-opus-4-6*|claude-opus-4*)
      window=200000; bpt="4.2"; max_kb=1700 ;;
    claude-sonnet-4-6*|claude-sonnet-4*)
      window=200000; bpt="4.0"; max_kb=1600 ;;
    claude-haiku-4-5*|claude-haiku-4*)
      window=200000; bpt="3.8"; max_kb=1500 ;;
    *)
      window=200000; bpt="4.0"; max_kb=1600 ;;
  esac

  printf '%s\t%d\t%s\t%d\n' "$model" "$window" "$bpt" "$max_kb"
}

# Parse model detection output into individual variables.
# Usage: eval "$(remembrall_parse_model_info "$transcript_path")"
# Sets: REMEMBRALL_MODEL, REMEMBRALL_WINDOW, REMEMBRALL_BPT, REMEMBRALL_MAX_KB
remembrall_parse_model_info() {
  local transcript_path="$1"
  local info
  info=$(remembrall_detect_model "$transcript_path")
  local m w b k
  IFS=$'\t' read -r m w b k <<< "$info"
  printf 'REMEMBRALL_MODEL=%q REMEMBRALL_WINDOW=%q REMEMBRALL_BPT=%q REMEMBRALL_MAX_KB=%q' \
    "$m" "$w" "$b" "$k"
}

# ─── Growth Tracking ──────────────────────────────────────────────

# Track content growth per prompt for a session.
# Appends content_bytes to /tmp/remembrall-growth/$SESSION_ID (last 10).
# Returns tab-separated: avg_growth_per_prompt  is_volatile
# is_volatile=1 if last 3 growths > 2x average.
remembrall_track_growth() {
  local session_id="$1"
  local transcript_path="$2"
  [ -z "$session_id" ] || [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ] && return 1

  local content_bytes
  content_bytes=$(remembrall_extract_content_bytes "$transcript_path") || return 1
  [ "$content_bytes" -eq 0 ] 2>/dev/null && return 1

  local growth_dir="/tmp/remembrall-growth"
  mkdir -p "$growth_dir" 2>/dev/null
  local growth_file="$growth_dir/$session_id"

  # Append current measurement
  echo "$content_bytes" >> "$growth_file"

  # Keep last 10 measurements
  local line_count
  line_count=$(wc -l < "$growth_file" | tr -d ' ')
  if [ "$line_count" -gt 10 ]; then
    local tmp
    tmp=$(tail -10 "$growth_file")
    printf '%s\n' "$tmp" > "$growth_file"
  fi

  # Need at least 2 measurements for deltas
  line_count=$(wc -l < "$growth_file" | tr -d ' ')
  if [ "$line_count" -lt 2 ]; then
    printf '0\t0\n'
    return 0
  fi

  # Calculate deltas and average growth
  local prev="" total_delta=0 delta_count=0
  local -a recent_deltas=()
  while IFS= read -r val; do
    if [ -n "$prev" ]; then
      local delta=$((val - prev))
      [ "$delta" -lt 0 ] && delta=0
      total_delta=$((total_delta + delta))
      delta_count=$((delta_count + 1))
      recent_deltas+=("$delta")
    fi
    prev="$val"
  done < "$growth_file"

  local avg_growth=0
  if [ "$delta_count" -gt 0 ]; then
    avg_growth=$((total_delta / delta_count))
  fi

  # Check volatility: last 3 deltas > 2x average
  local is_volatile=0
  if [ "$delta_count" -ge 3 ] && [ "$avg_growth" -gt 0 ]; then
    local volatile_count=0
    local threshold=$((avg_growth * 2))
    local start=$(( ${#recent_deltas[@]} > 3 ? ${#recent_deltas[@]} - 3 : 0 ))
    local i
    for ((i=start; i<${#recent_deltas[@]}; i++)); do
      [ "${recent_deltas[$i]}" -gt "$threshold" ] 2>/dev/null && volatile_count=$((volatile_count + 1))
    done
    [ "$volatile_count" -ge 3 ] && is_volatile=1
  fi

  printf '%d\t%d\n' "$avg_growth" "$is_volatile"
}

# Estimate prompts remaining until a threshold % is reached.
# Usage: remembrall_prompts_until_threshold content_bytes avg_growth content_max threshold_pct
# Returns estimated prompt count, or empty if not enough data.
remembrall_prompts_until_threshold() {
  local content_bytes="$1"
  local avg_growth="$2"
  local content_max="$3"
  local threshold_pct="${4:-20}"

  [ -z "$avg_growth" ] || [ "$avg_growth" -le 0 ] 2>/dev/null && return 1
  [ -z "$content_max" ] || [ "$content_max" -le 0 ] 2>/dev/null && return 1
  [ -z "$content_bytes" ] && return 1

  # Bytes at threshold
  local threshold_bytes=$(( content_max * (100 - threshold_pct) / 100 ))
  local bytes_remaining=$((threshold_bytes - content_bytes))
  [ "$bytes_remaining" -le 0 ] && { echo "0"; return 0; }

  local prompts=$((bytes_remaining / avg_growth))
  echo "$prompts"
}

# ─── Context Gauge ────────────────────────────────────────────────

# Render a visual context gauge with color.
# Usage: remembrall_gauge 42
# Output: [████░░░░░░] 42%
# Colors: green >60%, orange 21-60%, red <=20%
remembrall_gauge() {
  local pct="${1%%.*}"  # truncate decimal
  [ -z "$pct" ] && pct=0

  local width=10
  local filled=$((pct * width / 100))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  local empty=$((width - filled))

  local bar=""
  local i
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  # ANSI colors: green=32, orange/yellow=33, red=31
  local color
  if [ "$pct" -le 20 ] 2>/dev/null; then
    color="31"  # red
  elif [ "$pct" -le 60 ] 2>/dev/null; then
    color="33"  # orange/yellow
  else
    color="32"  # green
  fi

  printf '\033[%sm[%s]\033[0m %s%%' "$color" "$bar" "$pct"
}

# Plain-text gauge for embedding in JSON (no ANSI escape codes).
# Usage: remembrall_gauge_plain 42
remembrall_gauge_plain() {
  local pct="${1%%.*}"
  [ -z "$pct" ] && pct=0

  local width=10
  local filled=$((pct * width / 100))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  local empty=$((width - filled))

  local bar=""
  local i
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  printf '[%s] %s%%' "$bar" "$pct"
}

# ─── Integer Comparison ──────────────────────────────────────────

# Compare a number (possibly decimal) against an integer threshold.
# Usage: remembrall_gt "$REMAINING" 60 → returns 0 (true) if REMAINING > 60
# Truncates decimals — "42.7" becomes 42. No bc dependency.
remembrall_gt() {
  local val="${1%%.*}"  # truncate decimal
  local threshold="$2"
  [ -z "$val" ] && return 1
  [ "$val" -gt "$threshold" ] 2>/dev/null
}

remembrall_le() {
  local val="${1%%.*}"
  local threshold="$2"
  [ -z "$val" ] && return 1
  [ "$val" -le "$threshold" ] 2>/dev/null
}

remembrall_ge() {
  local val="${1%%.*}"
  local threshold="$2"
  [ -z "$val" ] && return 1
  [ "$val" -ge "$threshold" ] 2>/dev/null
}

# ─── Config ────────────────────────────────────────────────────────

# Read a config value from ~/.remembrall/config.json
# Usage: remembrall_config "key" "default_value"
remembrall_config() {
  local key="$1"
  local default="$2"
  local config_file="$HOME/.remembrall/config.json"

  if [ ! -f "$config_file" ]; then
    echo "$default"
    return
  fi

  local value
  # Use raw jq to get the value; .[$k] // empty returns nothing for missing keys
  # Use tostring for scalars, raw output for arrays/objects
  value=$(jq -r --arg k "$key" 'if has($k) then (if (.[$k] | type) == "array" or (.[$k] | type) == "object" then .[$k] | tojson else .[$k] | tostring end) else empty end' "$config_file" 2>/dev/null)

  if [ -z "$value" ]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# Validate config values before writing
# Returns 0 if valid, 1 if invalid (prints error to stderr)
remembrall_config_validate() {
  local key="$1"
  local value="$2"
  case "$key" in
    retention_hours)
      if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -eq 0 ]; then
        echo "remembrall: invalid retention_hours '$value' — must be a positive integer" >&2
        return 1
      fi
      ;;
    max_transcript_kb|recency_window|pensieve_max_sessions|pensieve_inject_budget)
      if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -eq 0 ]; then
        echo "remembrall: invalid $key '$value' — must be a positive integer" >&2
        return 1
      fi
      ;;
    time_turner_max_budget_usd)
      if ! [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "remembrall: invalid $key '$value' — must be a positive number" >&2
        return 1
      fi
      ;;
    time_turner_model)
      case "$value" in
        sonnet|opus|haiku) ;;
        *) echo "remembrall: invalid $key '$value' — must be sonnet, opus, or haiku" >&2; return 1 ;;
      esac
      ;;
    autonomous_mode|git_integration|team_handoffs|easter_eggs|debug|pensieve|time_turner)
      if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        echo "remembrall: invalid $key '$value' — must be true or false" >&2
        return 1
      fi
      ;;
    threshold_journal|threshold_warning|threshold_urgent|threshold_timeturner)
      if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -eq 0 ] || [ "$value" -ge 100 ]; then
        echo "remembrall: invalid $key '$value' — must be an integer between 1 and 99" >&2
        return 1
      fi
      ;;
    disabled_hooks)
      if ! echo "$value" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "remembrall: invalid disabled_hooks '$value' — must be a JSON array" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

# Write a config value to ~/.remembrall/config.json
# Creates the file and directory if they don't exist
remembrall_config_set() {
  local key="$1"
  local value="$2"
  local config_file="$HOME/.remembrall/config.json"

  # Validate before writing
  if ! remembrall_config_validate "$key" "$value"; then
    return 1
  fi

  mkdir -p "$(dirname "$config_file")"

  if [ ! -f "$config_file" ]; then
    echo '{}' > "$config_file"
  fi

  local tmp
  tmp=$(mktemp "${config_file}.XXXXXX")
  # Store booleans and numbers as native JSON types, strings as strings
  local jq_ok=false
  if [ "$value" = "true" ] || [ "$value" = "false" ] || [[ "$value" =~ ^[0-9]+$ ]]; then
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$config_file" > "$tmp" 2>/dev/null && jq_ok=true
  else
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$config_file" > "$tmp" 2>/dev/null && jq_ok=true
  fi

  if [ "$jq_ok" = true ]; then
    mv "$tmp" "$config_file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# ─── Hook Enable/Disable ─────────────────────────────────────

# Check if a hook is enabled (not in the disabled_hooks list).
# Returns 0 (enabled) or 1 (disabled).
remembrall_hook_enabled() {
  local hook_name="$1"
  local disabled
  disabled=$(remembrall_config "disabled_hooks" "[]")
  if echo "$disabled" | jq -e --arg h "$hook_name" 'index($h)' >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ─── Git Integration ──────────────────────────────────────────────

# Check if git integration is enabled AND cwd is a git repo
# Supports both boolean true and string "true" for backwards compatibility
remembrall_git_enabled() {
  local cwd="$1"
  local val
  val=$(remembrall_config "git_integration" "false")
  [ "$val" = "true" ] || return 1
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
}

# Compute patches directory for a project
# Falls back to legacy full-hash format for v2.x compat
remembrall_patches_dir() {
  local cwd="$1"
  local full_hash
  full_hash=$(remembrall_md5 "$cwd") || return 1
  local project_name
  project_name=$(basename "$cwd")
  project_name=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | sed 's/^\.*//' | sed 's/[^a-z0-9_-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  [ -z "$project_name" ] && project_name="default"
  local short_hash
  short_hash=$(printf '%s' "$full_hash" | cut -c1-8)
  local new_dir="$HOME/.remembrall/patches/${project_name}-${short_hash}"
  local old_dir="$HOME/.remembrall/patches/${full_hash}"
  if [ -d "$new_dir" ]; then
    echo "$new_dir"
  elif [ -d "$old_dir" ]; then
    echo "$old_dir"
  else
    echo "$new_dir"
  fi
}

# ─── Team Handoffs ────────────────────────────────────────────────

# Check if team handoffs are enabled
# Supports both boolean true and string "true" for backwards compatibility
remembrall_team_enabled() {
  local val
  val=$(remembrall_config "team_handoffs" "false")
  [ "$val" = "true" ]
}

# Get handoff retention in hours (default: 72)
remembrall_retention_hours() {
  local val
  val=$(remembrall_config "retention_hours" "72")
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "$val"
  else
    echo "72"
  fi
}

# Compute team handoff directory — same as personal (all centralized)
# Team handoffs are distinguished by metadata, not location
remembrall_team_handoff_dir() {
  local cwd="$1"
  remembrall_handoff_dir "$cwd"
}

# ─── Session ID Publishing ────────────────────────────────────────

# Publish session_id so skill bash commands can read it.
# Hooks have session_id from JSON input; Bash tool commands don't.
# Written on every prompt by context-monitor.sh — always current.
# ─── Plugin Root Discovery ────────────────────────────────────────
# Hooks get CLAUDE_PLUGIN_ROOT from Claude Code automatically.
# Skills/commands run in a bare shell where it's NOT set.
# Persist the root on every hook run so skills can find it.

remembrall_publish_plugin_root() {
  [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && return
  local dir="/tmp/remembrall-meta"
  mkdir -p "$dir" 2>/dev/null
  printf '%s' "$CLAUDE_PLUGIN_ROOT" > "$dir/plugin-root" 2>/dev/null
}

# Read the persisted plugin root. Falls back to CLAUDE_PLUGIN_ROOT env var.
remembrall_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
    return
  fi
  local f="/tmp/remembrall-meta/plugin-root"
  if [ -f "$f" ]; then
    cat "$f" 2>/dev/null
    return
  fi
  return 1
}

remembrall_publish_session_id() {
  local cwd="$1"
  local session_id="$2"
  [ -z "$session_id" ] && return
  local hash
  hash=$(remembrall_md5 "$cwd") || return
  local dir="/tmp/remembrall-sessions"
  mkdir -p "$dir" 2>/dev/null
  printf '%s' "$session_id" > "$dir/$hash" 2>/dev/null
}

# Read the published session_id for a CWD.
# Used by handoff-create.sh when CLAUDE_SESSION_ID env var isn't available.
remembrall_read_session_id() {
  local cwd="$1"
  local hash
  hash=$(remembrall_md5 "$cwd") || return 1
  local f="/tmp/remembrall-sessions/$hash"
  [ -f "$f" ] && cat "$f" 2>/dev/null
}

# ─── Autonomous Mode ─────────────────────────────────────────────

# Autonomous mode marker — set by skills that run unattended (ralph loop,
# swarm agents, etc.) so Remembrall uses the automatic path (handoff +
# compaction) instead of plan mode (which needs a human click).
#
# Any skill can signal autonomous mode:
#   remembrall_set_autonomous "$SESSION_ID" "ralph-loop"
#
# The marker is checked by context-monitor.sh at <=30% to decide:
#   autonomous → write /handoff (automatic, no human needed)
#   attended   → EnterPlanMode (human clicks "clear context")

REMEMBRALL_AUTONOMOUS_DIR="/tmp/remembrall-autonomous"

remembrall_set_autonomous() {
  local session_id="$1"
  local skill_name="${2:-unknown}"
  [ -z "$session_id" ] && return
  mkdir -p "$REMEMBRALL_AUTONOMOUS_DIR" 2>/dev/null
  printf '%s' "$skill_name" > "$REMEMBRALL_AUTONOMOUS_DIR/$session_id" 2>/dev/null
}

remembrall_clear_autonomous() {
  local session_id="$1"
  [ -z "$session_id" ] && return
  rm -f "$REMEMBRALL_AUTONOMOUS_DIR/$session_id" 2>/dev/null
}

# Returns 0 (true) if autonomous, 1 (false) if attended.
# Outputs the skill name on stdout if autonomous.
remembrall_is_autonomous() {
  local session_id="$1"
  [ -z "$session_id" ] && return 1
  local f="$REMEMBRALL_AUTONOMOUS_DIR/$session_id"
  if [ -f "$f" ]; then
    cat "$f" 2>/dev/null
    return 0
  fi
  return 1
}

# ─── Handoff Chains ──────────────────────────────────────────────

# Find the most recent handoff session_id for chaining.
# Returns the session_id from the newest handoff file, or empty if none.
remembrall_previous_session() {
  local cwd="$1"
  local current_session="$2"
  local handoff_dir
  handoff_dir=$(remembrall_handoff_dir "$cwd") || return 1

  [ -d "$handoff_dir" ] || return 1

  local newest="" newest_file=""
  for f in "$handoff_dir"/handoff-*.md; do
    [ -f "$f" ] || continue
    # Skip our own session's handoff
    local basename
    basename=$(basename "$f" .md)
    local sid="${basename#handoff-}"
    [ "$sid" = "$current_session" ] && continue
    if [ -z "$newest_file" ] || [ "$f" -nt "$newest_file" ]; then
      newest_file="$f"
      newest="$sid"
    fi
  done

  # Also check claimed files (in-progress resumes)
  for f in "$handoff_dir"/handoff-*.md.claimed-*; do
    [ -f "$f" ] || continue
    local basename
    basename=$(basename "$f")
    # Extract session id: handoff-SESSID.md.claimed-PID
    local sid="${basename#handoff-}"
    sid="${sid%.md.claimed-*}"
    [ "$sid" = "$current_session" ] && continue
    if [ -z "$newest_file" ] || [ "$f" -nt "$newest_file" ]; then
      newest_file="$f"
      newest="$sid"
    fi
  done

  echo "$newest"
}

# ─── Pensieve Directory ──────────────────────────────────────────

# Compute Pensieve persistence directory for a given CWD
# Mirrors remembrall_handoff_dir() pattern for consistency
# e.g., ~/.remembrall/pensieve/ai-buddies-8f9a0596/
remembrall_pensieve_dir() {
  local cwd="$1"
  local full_hash
  full_hash=$(remembrall_md5 "$cwd") || return 1
  local project_name
  project_name=$(basename "$cwd")
  project_name=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | sed 's/^\.*//' | sed 's/[^a-z0-9_-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  [ -z "$project_name" ] && project_name="default"
  local short_hash
  short_hash=$(printf '%s' "$full_hash" | cut -c1-8)
  echo "$HOME/.remembrall/pensieve/${project_name}-${short_hash}"
}

# Pensieve temp directory for raw JSONL tracking data
# e.g., /tmp/remembrall-pensieve/
remembrall_pensieve_tmp() {
  echo "/tmp/remembrall-pensieve"
}

# ─── Frontmatter ──────────────────────────────────────────────────

# Parse frontmatter value from a handoff file.
# Supports both JSON frontmatter (new format) and YAML frontmatter (legacy).
# Usage: remembrall_frontmatter_get "file.md" "key"
remembrall_frontmatter_get() {
  local file="$1"
  local key="$2"

  # Extract content between the first pair of --- markers only
  local block
  block=$(awk '/^---$/ { if (++c == 2) exit; next } c == 1 { print }' "$file" 2>/dev/null) || return

  # Try JSON parse first (new format)
  local val
  val=$(printf '%s' "$block" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    echo "$val"
    return
  fi

  # Legacy YAML fallback — simple key: value lines only
  # Use `|| true` to ensure non-zero exit from grep (no match) doesn't propagate
  # when caller has set -euo pipefail
  printf '%s\n' "$block" | grep "^${key}:" | sed "s/^${key}: *//" | head -1 || true
}

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

# Check if Patrol is installed (for status display)
# Usage: remembrall_patrol_detected
remembrall_patrol_detected() {
  # Check common Patrol installation paths
  [ -d "$HOME/.claude/plugins/cache/cukas/patrol" ] && return 0
  [ -d "$HOME/.claude/plugins/patrol" ] && return 0
  command -v patrol >/dev/null 2>&1 && return 0
  return 1
}
