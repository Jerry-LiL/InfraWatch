# shellcheck shell=bash
# Pure checks. Each prints one detail line and returns 0 (ok), 1 (breach),
# or 2 (the inputs cannot be evaluated). Callers pass the numbers in so the
# decisions can be tested without /proc or systemd.

classify_load() {
  local load=$1 cores=$2 threshold=$3
  if ! is_decimal "$load" || ! is_uint "$cores" || ! is_decimal "$threshold"; then
    printf 'load=%s cores=%s threshold=%s detail=bad-input\n' "$load" "$cores" "$threshold"
    return 2
  fi
  awk -v load="$load" -v cores="$cores" -v threshold="$threshold" 'BEGIN {
    if (cores < 1) cores = 1
    per = load / cores
    printf "load=%.2f per_core=%.2f cores=%d threshold=%.2f\n", load, per, cores, threshold
    if (per > threshold) exit 1
    exit 0
  }'
}

# total_kb and avail_kb come from MemTotal and MemAvailable.
# Available is what the kernel can hand out without heavy reclaim, so it is
# the pressure signal. MemFree alone is noisy because of cache.
classify_memory() {
  local total_kb=$1 avail_kb=$2 threshold=$3
  awk -v total="$total_kb" -v avail="$avail_kb" -v threshold="$threshold" 'BEGIN {
    if (total+0 <= 0 || threshold+0 < 0) {
      printf "detail=bad-input total_kb=%s available_kb=%s threshold=%s\n", total, avail, threshold
      exit 2
    }
    if (avail+0 < 0) avail = 0
    if (avail+0 > total+0) avail = total
    used = (total - avail) / total * 100
    printf "used_percent=%.1f available_kb=%d total_kb=%d threshold=%s\n", used, avail, total, threshold
    if (used > threshold) exit 1
    exit 0
  }'
}

classify_disk() {
  local path=$1 pct=$2 threshold=$3
  awk -v path="$path" -v pct="$pct" -v threshold="$threshold" 'BEGIN {
    if (pct !~ /^[0-9]+$/ || threshold !~ /^[0-9]+$/) {
      printf "path=%s used_percent=%s threshold=%s detail=bad-input\n", path, pct, threshold
      exit 2
    }
    printf "path=%s used_percent=%s threshold=%s\n", path, pct, threshold
    if (pct + 0 > threshold + 0) exit 1
    exit 0
  }'
}

# state is the first word systemctl is-active prints: active, inactive, failed, ...
classify_service() {
  local unit=$1 state=$2
  printf 'unit=%s state=%s\n' "$unit" "$state"
  case "$state" in
    active) return 0 ;;
    inactive | failed | activating | deactivating | reloading | maintenance) return 1 ;;
    *) return 2 ;;
  esac
}

classify_query_count() {
  local count=$1 seconds=$2
  printf 'running=%s threshold_seconds=%s\n' "$count" "$seconds"
  if ! is_uint "$count" || ! is_uint "$seconds"; then
    return 2
  fi
  if ((count > 0)); then
    return 1
  fi
  return 0
}
