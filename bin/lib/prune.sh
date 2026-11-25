# shellcheck shell=bash
# Delete dumps older than `days`, but always keep the newest `min_keep` files.
# Prints the basename of each deleted dump. Sidecar .manifest files go with them.

prune_backups() {
  local dir=$1 days=$2 min_keep=$3
  [[ -d "$dir" ]] || return 0

  local now cutoff
  now=$(date +%s)
  cutoff=$((now - days * 86400))

  local -a lines=()
  local f mtime
  shopt -s nullglob
  for f in "$dir"/*.dump; do
    mtime=$(stat -c %Y "$f")
    lines+=("${mtime} ${f}")
  done
  shopt -u nullglob

  if ((${#lines[@]} == 0)); then
    return 0
  fi

  local i=0 line path
  i=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    i=$((i + 1))
    mtime=${line%% *}
    path=${line#* }
    if ((i <= min_keep)); then
      continue
    fi
    if ((mtime < cutoff)); then
      rm -f -- "$path" "${path%.dump}.manifest"
      basename -- "$path"
    fi
  done < <(printf '%s\n' "${lines[@]}" | sort -k1,1 -nr)
}

latest_dump() {
  local newest="" f
  shopt -s nullglob
  for f in "$BACKUP_DIR"/*.dump; do
    if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
      newest=$f
    fi
  done
  shopt -u nullglob
  [[ -n "$newest" ]] || return 1
  printf '%s\n' "$newest"
}
