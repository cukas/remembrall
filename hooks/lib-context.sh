#!/usr/bin/env bash
# sourced by lib.sh
# lib-context.sh — Context estimation, calibration, growth tracking, gauge

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

# ─── Context Window Detection ─────────────────────────────────────
# Detect the actual context window size (in tokens) for the current session.
# Reads the model display name from the bridge directory, parses window size.
# Returns token count on stdout (e.g., 200000, 1000000, 2000000).
# Falls back to 200000 if undetectable.
# Future-proof: parses any "<N>K" or "<N>M" pattern from display name.
remembrall_context_window() {
  local session_id="${1:-}"
  [ -z "$session_id" ] && { echo 200000; return; }
  local bridge_model="/tmp/claude-context-pct/${session_id}.model"
  if [ -f "$bridge_model" ]; then
    local display
    display=$(cat "$bridge_model" 2>/dev/null)
    # Parse "<N>M context" or "<N>K context" — e.g., "Opus 4.6 (1M context)"
    local num
    num=$(printf '%s' "$display" | grep -oiE '[0-9]+[MK]\b' | head -1)
    if [ -n "$num" ]; then
      local digits suffix
      digits=$(printf '%s' "$num" | sed 's/[^0-9]//g')
      suffix=$(printf '%s' "$num" | sed 's/[0-9]//g' | tr '[:lower:]' '[:upper:]')
      case "$suffix" in
        M) echo $(( digits * 1000000 )); return ;;
        K) echo $(( digits * 1000 )); return ;;
      esac
    fi
  fi
  echo 200000
}

# Scale a percentage threshold based on actual context window size.
# Uses fourth-root scaling for a gentle curve: bigger windows get
# proportionally more headroom without making thresholds unreachably low.
#   scaled = threshold × (200K / window) ^ 0.25
# Results: 200K=65%, 500K=51%, 1M=42%, 2M=35% (for journal=65%).
# Base window is 200K — thresholds are calibrated for that size.
# Previous sqrt scaling made 1M thresholds so low (journal=28%, TT=13%)
# that features like Time-Turner and Phoenix never triggered.
remembrall_scale_threshold() {
  local threshold="$1"
  local window_tokens="${2:-200000}"
  if [ "$window_tokens" -le 200000 ] 2>/dev/null; then
    echo "$threshold"
    return
  fi
  # Fourth root via two Newton's method passes: sqrt(sqrt(ratio))
  # Step 1: ratio = (200K / window) × 10000 for precision
  local ratio=$(( 200000 * 10000 / window_tokens ))
  # Step 2: first sqrt — Newton's method for isqrt(ratio)
  local x=$ratio
  local y=$(( (x + 1) / 2 ))
  while [ "$y" -lt "$x" ]; do
    x=$y
    y=$(( (x + ratio / x) / 2 ))
  done
  # x = sqrt(ratio) ≈ sqrt(200K/window) × 100
  # Step 3: second sqrt — fourth root. Scale x to preserve precision.
  local ratio2=$(( x * 100 ))
  local x2=$ratio2
  local y2=$(( (x2 + 1) / 2 ))
  while [ "$y2" -lt "$x2" ]; do
    x2=$y2
    y2=$(( (x2 + ratio2 / x2) / 2 ))
  done
  # x2 = sqrt(x * 100) = sqrt(sqrt(200K/window) × 10000) ≈ (200K/window)^0.25 × 100
  local scaled=$(( threshold * x2 / 100 ))
  # Floor at 5%
  [ "$scaled" -lt 5 ] 2>/dev/null && scaled=5
  echo "$scaled"
}

# ─── Model Default Content Max ────────────────────────────────────
# Derives content_max from window size using empirical ratio.
# Calibration data shows: content_max ≈ window_tokens × 1.68
# (e.g., 200K × 1.68 = 336K ≈ 337920 observed default).
# Accepts optional window_tokens parameter — any size works.
# Falls back to model-specific per-token tuning for 200K (legacy compat).
remembrall_default_content_max() {
  local model_name="${1:-unknown}"
  local window_tokens="${2:-200000}"

  # For non-default windows, use formula: window × bpt × overhead_ratio
  # bpt varies by model, overhead_ratio ≈ 0.42 (content vs total context)
  if [ "$window_tokens" -gt 200000 ] 2>/dev/null; then
    local bpt_x10=40  # default 4.0
    case "$model_name" in
      claude-opus-4-6*|claude-opus-4*)     bpt_x10=42 ;;
      claude-sonnet-4-6*|claude-sonnet-4*) bpt_x10=40 ;;
      claude-haiku-4-5*|claude-haiku-4*)   bpt_x10=38 ;;
    esac
    # content_max = window_tokens × (bpt/10) × 0.42
    # Simplified: window_tokens × bpt_x10 × 42 / 1000
    echo $(( window_tokens * bpt_x10 * 42 / 1000 ))
    return
  fi

  # Legacy 200K defaults (exact values preserved for calibration stability)
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

  # Lookup table: model → bytes_per_token (only model-specific constant)
  # window_tokens and max_transcript_kb are derived from optional $2 param.
  # $2 = actual window tokens (e.g., 200000, 1000000). Default: 200000.
  local window_tokens="${2:-200000}"
  [[ "$window_tokens" =~ ^[0-9]+$ ]] || window_tokens=200000

  local bpt="4.0"
  case "$model" in
    claude-opus-4-6*|claude-opus-4*)     bpt="4.2" ;;
    claude-sonnet-4-6*|claude-sonnet-4*) bpt="4.0" ;;
    claude-haiku-4-5*|claude-haiku-4*)   bpt="3.8" ;;
  esac

  # Derive max_transcript_kb from window size: window × bpt × overhead / 1024
  # Overhead factor ~2.0 accounts for JSON structure wrapping content
  local bpt_x10
  bpt_x10=$(printf '%s' "$bpt" | sed 's/\.//')
  local max_kb
  max_kb=$(( window_tokens * bpt_x10 * 2 / 10240 ))
  # Floor at 1500 for sanity
  [ "$max_kb" -lt 1500 ] && max_kb=1500

  printf '%s\t%d\t%s\t%d\n' "$model" "$window_tokens" "$bpt" "$max_kb"
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
