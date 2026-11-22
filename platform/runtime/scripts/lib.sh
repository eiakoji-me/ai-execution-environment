#!/usr/bin/env bash

set -euo pipefail

RUNTIME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=platform/repositories/lib.sh
source "$RUNTIME_ROOT/platform/repositories/lib.sh"

utc_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

work_item_dir() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid workspace id: $1"
  [[ "$2" =~ ^[A-Z][A-Z0-9-]*$ ]] || die "invalid work-item id: $2"
  printf '%s/workspaces/%s/%s\n' "$RUNTIME_ROOT" "$1" "$2"
}

require_work_item() {
  local directory
  directory="$(work_item_dir "$1" "$2")"
  [[ -f "$directory/meta.json" ]] || die "work item not found: $1/$2"
  printf '%s\n' "$directory"
}

record_history() {
  local directory="$1"
  shift
  printf '%s  %s\n' "$(utc_now)" "$*" >>"$directory/history.log"
}

update_runtime_state() {
  local meta="$1"
  local status="$2"
  local worktree="$3"
  local container_id="$4"
  local pool_slot="$5"
  local actor="$6"
  local temporary="${meta}.tmp"
  local timestamp
  timestamp="$(utc_now)"
  jq \
    --arg status "$status" \
    --arg worktree "$worktree" \
    --arg container_id "$container_id" \
    --arg pool_slot "$pool_slot" \
    --arg actor "$actor" \
    --arg timestamp "$timestamp" \
    '.runtime.status = $status
     | .runtime.worktree = (if $worktree == "" then null else $worktree end)
     | .runtime.containerId = (if $container_id == "" then null else $container_id end)
     | .runtime.identity = (if $container_id == "" then null else .runtime.identity end)
     | .runtime.poolSlot = (if $pool_slot == "" then null else ($pool_slot | tonumber) end)
     | .resume.lastUpdatedBy = $actor
     | .resume.lastUpdatedAt = $timestamp' \
    "$meta" >"$temporary"
  mv "$temporary" "$meta"
}

runtime_pool_size() {
  local size="${RUNTIME_POOL_SIZE:-}"
  if [[ -z "$size" && -f "$RUNTIME_ROOT/.env" ]]; then
    size="$(sed -nE 's/^RUNTIME_POOL_SIZE=([0-9]+)$/\1/p' "$RUNTIME_ROOT/.env" | tail -n 1)"
  fi
  size="${size:-5}"
  [[ "$size" =~ ^[1-9][0-9]*$ ]] || die "RUNTIME_POOL_SIZE must be a positive integer"
  printf '%s\n' "$size"
}

acquire_pool_lock() {
  local lock_root="$RUNTIME_ROOT/.local/state/runtime"
  local lock="$lock_root/pool.lock"
  mkdir -p "$lock_root"
  if [[ -f "$lock/pid" ]]; then
    local lock_pid
    lock_pid="$(tr -d '[:space:]' <"$lock/pid" 2>/dev/null || true)"
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
      if [[ "$lock_pid" == "$$" || ( -n "${RUNTIME_POOL_LOCK_OWNER:-}" && "$lock_pid" == "$RUNTIME_POOL_LOCK_OWNER" ) ]]; then
        printf '\n'
        return 0
      fi
    fi
  fi
  local retries="${RUNTIME_POOL_LOCK_RETRIES:-50}"
  local i
  for ((i = 1; i <= retries; i++)); do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock/pid"
      printf '%s\n' "$lock"
      return 0
    fi
    sleep 0.1
  done
  die "runtime pool is busy; retry after the current start operation finishes"
}

release_pool_lock() {
  local lock="${1:-}"
  local expected_pid="${2:-$$}"
  [[ -n "$lock" && -d "$lock" ]] || return 0
  if [[ -f "$lock/pid" ]]; then
    local lock_pid
    lock_pid="$(tr -d '[:space:]' <"$lock/pid" 2>/dev/null || true)"
    if [[ -n "$lock_pid" && "$lock_pid" != "$expected_pid" ]]; then
      return 0
    fi
  fi
  rm -f "$lock/pid" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}

is_pool_lock_stale() {
  local lock="$1"
  [[ -d "$lock" ]] || return 1
  local pid_file="$lock/pid"
  local wait_i
  for ((wait_i = 1; wait_i <= 5; wait_i++)); do
    [[ -f "$pid_file" || ! -d "$lock" ]] && break
    sleep 0.05
  done
  [[ -d "$lock" ]] || return 1
  if [[ -f "$pid_file" ]]; then
    local lock_pid
    lock_pid="$(tr -d '[:space:]' <"$pid_file" 2>/dev/null || true)"
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

reclaim_stale_pool_lock() {
  local lock="$1"
  [[ -d "$lock" ]] || return 1
  local reclaim_lock="${lock}.reclaim"
  local i
  for ((i = 1; i <= 50; i++)); do
    if mkdir "$reclaim_lock" 2>/dev/null; then
      printf '%s\n' "$$" >"$reclaim_lock/pid"
      if is_pool_lock_stale "$lock"; then
        local claimed="${lock}.stale.$$"
        rm -rf "$claimed" 2>/dev/null || true
        if mv "$lock" "$claimed" 2>/dev/null; then
          rm -f "$claimed/pid" 2>/dev/null || true
          rmdir "$claimed" 2>/dev/null || true
          release_pool_lock "$reclaim_lock" "$$"
          return 0
        fi
      fi
      release_pool_lock "$reclaim_lock" "$$"
      return 1
    fi
    if is_pool_lock_stale "$reclaim_lock"; then
      local stale_reclaim="${reclaim_lock}.stale.$$"
      rm -rf "$stale_reclaim" 2>/dev/null || true
      if mv "$reclaim_lock" "$stale_reclaim" 2>/dev/null; then
        rm -f "$stale_reclaim/pid" 2>/dev/null || true
        rmdir "$stale_reclaim" 2>/dev/null || true
      fi
      continue
    fi
    sleep 0.05
  done
  return 1
}

is_valid_worktree_relpath() {
  [[ "${1:-}" =~ ^worktrees/[a-z0-9][a-z0-9-]*$ ]]
}

resolve_safe_worktree_abspath() {
  local wt_rel="${1:-}"
  is_valid_worktree_relpath "$wt_rel" || return 1
  local worktrees_root="$RUNTIME_ROOT/worktrees"
  [[ -d "$worktrees_root" && ! -L "$worktrees_root" ]] || return 1
  local target="$RUNTIME_ROOT/$wt_rel"
  [[ ! -L "$target" ]] || return 1
  local worktrees_real parent_real
  worktrees_real="$(cd "$worktrees_root" 2>/dev/null && pwd -P)" || return 1
  parent_real="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
  [[ "$parent_real" == "$worktrees_real" ]] || return 1
  printf '%s/%s\n' "$worktrees_real" "$(basename "$target")"
}

claim_pool_slot() {
  local current_meta="$1"
  local requested_slot="${2:-}"
  local current_slot
  local size
  local slot
  local meta
  local allocated
  current_slot="$(jq -r '.runtime.poolSlot // empty' "$current_meta")"
  size="$(runtime_pool_size)"

  if [[ -n "$requested_slot" ]]; then
    [[ "$requested_slot" =~ ^[1-9][0-9]*$ && "$requested_slot" -le "$size" ]] \
      || die "requested runtime pool slot $requested_slot is out of range (1..$size)"
    while IFS= read -r meta; do
      [[ "$meta" == "$current_meta" ]] && continue
      allocated="$(jq -r '.runtime.poolSlot // empty' "$meta")"
      if [[ "$allocated" == "$requested_slot" ]]; then
        die "runtime pool slot $requested_slot is already assigned to $(jq -r '"\(.workspace)/\(.workItem)"' "$meta")"
      fi
    done < <(find "$RUNTIME_ROOT/workspaces" -mindepth 3 -maxdepth 3 -name meta.json -type f -print 2>/dev/null)
    printf '%s\n' "$requested_slot"
    return 0
  fi

  if [[ -n "$current_slot" ]]; then
    [[ "$current_slot" =~ ^[1-9][0-9]*$ && "$current_slot" -le "$size" ]] \
      || die "work item has invalid runtime pool slot: $current_slot"
    while IFS= read -r meta; do
      [[ "$meta" == "$current_meta" ]] && continue
      allocated="$(jq -r '.runtime.poolSlot // empty' "$meta")"
      [[ "$allocated" != "$current_slot" ]] \
        || die "runtime pool slot $current_slot is assigned to multiple work items"
    done < <(find "$RUNTIME_ROOT/workspaces" -mindepth 3 -maxdepth 3 -name meta.json -type f -print 2>/dev/null)
    printf '%s\n' "$current_slot"
    return 0
  fi

  for ((slot = 1; slot <= size; slot++)); do
    allocated=0
    while IFS= read -r meta; do
      [[ "$(jq -r '.runtime.poolSlot // empty' "$meta")" == "$slot" ]] && allocated=1
    done < <(find "$RUNTIME_ROOT/workspaces" -mindepth 3 -maxdepth 3 -name meta.json -type f -print 2>/dev/null)
    if [[ "$allocated" -eq 0 ]]; then
      printf '%s\n' "$slot"
      return 0
    fi
  done

  die "runtime pool is full ($size containers); stop does not free a slot, close or release a work item first"
}

set_runtime_pool_size() {
  local new_size="$1"
  [[ "$new_size" =~ ^[1-9][0-9]*$ ]] || die "pool size must be a positive integer: $new_size"
  local meta
  local slot
  while IFS= read -r meta; do
    slot="$(jq -r '.runtime.poolSlot // empty' "$meta")"
    if [[ -n "$slot" && "$slot" =~ ^[0-9]+$ ]] && ((slot > new_size)); then
      die "cannot shrink pool size to $new_size: slot $slot is allocated to $(jq -r '"\(.workspace)/\(.workItem)"' "$meta")"
    fi
  done < <(find "$RUNTIME_ROOT/workspaces" -mindepth 3 -maxdepth 3 -name meta.json -type f -print 2>/dev/null)

  local env_file="$RUNTIME_ROOT/.env"
  local temporary="${env_file}.tmp.$$"
  if [[ ! -f "$env_file" && -f "$RUNTIME_ROOT/platform/install/templates/.env.example" ]]; then
    cp "$RUNTIME_ROOT/platform/install/templates/.env.example" "$env_file"
  fi
  if [[ -f "$env_file" ]] && grep -Eq '^RUNTIME_POOL_SIZE=' "$env_file"; then
    sed -E "s/^RUNTIME_POOL_SIZE=.*/RUNTIME_POOL_SIZE=$new_size/" "$env_file" >"$temporary"
    mv "$temporary" "$env_file"
  else
    printf 'RUNTIME_POOL_SIZE=%s\n' "$new_size" >>"$env_file"
  fi
}

inspect_container_status() {
  local container_id="${1:-}"
  if [[ -z "$container_id" ]]; then
    printf 'none\n'
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    printf 'unavailable\n'
    return 0
  fi
  local out err_file err
  err_file="$(mktemp)"
  if out="$(docker inspect -f '{{.State.Status}}' "$container_id" 2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s\n' "$out"
    return 0
  fi
  err="$(<"$err_file")"
  rm -f "$err_file"
  if grep -Eqi 'no such (object|container)' <<<"$err"; then
    printf 'missing\n'
  else
    printf 'unavailable\n'
  fi
}

worktree_git_state() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    printf 'missing\n'
    return 0
  fi
  if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'invalid\n'
    return 0
  fi
  local status_out
  if ! status_out="$(git -C "$path" status --porcelain 2>/dev/null)"; then
    printf 'error\n'
    return 0
  fi
  if [[ -n "$status_out" ]]; then
    printf 'dirty\n'
  else
    printf 'clean\n'
  fi
}

find_meta_by_slot() {
  local target_slot="$1"
  local found_meta=""
  local meta
  local slot
  while IFS= read -r meta; do
    slot="$(jq -r '.runtime.poolSlot // empty' "$meta")"
    if [[ "$slot" == "$target_slot" ]]; then
      [[ -z "$found_meta" ]] || die "runtime pool slot $target_slot is assigned to multiple work items"
      found_meta="$meta"
    fi
  done < <(find "$RUNTIME_ROOT/workspaces" -mindepth 3 -maxdepth 3 -name meta.json -type f -print 2>/dev/null | sort)
  [[ -n "$found_meta" ]] || return 1
  printf '%s\n' "$found_meta"
}
