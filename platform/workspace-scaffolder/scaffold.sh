#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=platform/identity/lib.sh
source "$ROOT/platform/identity/lib.sh"

usage() {
  printf 'usage: %s <workspace-id> <issue-ref> [--type FEAT|FIX|TASK] [--no-start] [--start-point <ref>]\n' "$0" >&2
}

[[ "$#" -ge 2 ]] || { usage; exit 2; }
workspace="$1"
issue_ref="$2"
shift 2
type_override=''
start_runtime=1
start_point=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --type) type_override="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
    --no-start) start_runtime=0; shift ;;
    --start-point) start_point="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

validate_projects
project="$(project_by_workspace "$workspace")" || die "unknown workspace: $workspace"
project_id="$(jq -r '.id' <<<"$project")"
source_name="$(jq -r '.issues.provider' <<<"$project")"
owner="$(jq -r '.issues.owner' <<<"$project")"
repository="$(jq -r '.issues.repository' <<<"$project")"
adapter="$ROOT/platform/workspace-scaffolder/sources/$source_name.sh"
[[ -x "$adapter" ]] || die "unsupported issue provider: $source_name"
repository_identity="$(project_identity "$project" repository)"
issues_identity="$(project_identity "$project" issues)"

ticket_json="$(identity_exec "$issues_identity" "$adapter" "$issue_ref" --repo "$owner/$repository")"
number="$(jq -r '.number' <<<"$ticket_json")"
item_type="${type_override:-$(jq -r '.type // empty' <<<"$ticket_json")}"
item_type="${item_type:-TASK}"
case "$item_type" in FEAT|FIX|TASK) ;; *) die "unable to determine type; pass --type FEAT, FIX, or TASK" ;; esac

if [[ -z "$type_override" && -d "$ROOT/workspaces/$workspace" ]]; then
  existing_dir="$(find "$ROOT/workspaces/$workspace" -maxdepth 1 -type d -name "[A-Z]*-${number}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$existing_dir" ]]; then
    existing_name="$(basename "$existing_dir")"
    existing_type="${existing_name%%-*}"
    case "$existing_type" in
      FEAT|FIX|TASK) item_type="$existing_type" ;;
    esac
  fi
fi

work_item="${item_type}-${number}"
title="$(jq -r '.title' <<<"$ticket_json")"
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-50 | sed -E 's/-+$//')"
[[ -n "$slug" ]] || slug="issue-$number"
branch="$(printf '%s' "$item_type" | tr '[:upper:]' '[:lower:]')/${number}-${slug}"
worktree="worktrees/$(printf '%s-%s' "$workspace" "$work_item" | tr '[:upper:]' '[:lower:]')"
target="$ROOT/workspaces/$workspace/$work_item"
timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

mkdir -p "$target/artifacts"
jq \
  --arg workspace "$workspace" \
  --arg work_item "$work_item" \
  --arg project "$project_id" \
  --arg branch "$branch" \
  '. + {workspace: $workspace, workItem: $work_item, project: $project, branch: $branch}' \
  <<<"$ticket_json" >"$target/ticket.json"

if [[ ! -f "$target/meta.json" ]]; then
  jq \
    --arg workspace "$workspace" \
    --arg work_item "$work_item" \
    --arg project "$project_id" \
    --arg source "$source_name" \
    --arg key "$(jq -r '.key' <<<"$ticket_json")" \
    --arg url "$(jq -r '.url' <<<"$ticket_json")" \
    --arg branch "$branch" \
    --arg timestamp "$timestamp" \
    --arg repository_identity "$repository_identity" \
    --arg issues_identity "$issues_identity" \
    '.workspace = $workspace
     | .workItem = $work_item
     | .project = $project
     | .identity = {repository: $repository_identity, issues: $issues_identity}
     | .source = {provider: $source, key: $key, url: $url}
     | .design.branch = $branch
     | .resume.lastUpdatedAt = $timestamp' \
    "$ROOT/platform/state/templates/meta.json" >"$target/meta.json"
fi

if [[ ! -f "$target/session-state.md" ]]; then
  # shellcheck disable=SC2016
  WORK_ITEM="$work_item" TIMESTAMP="$timestamp" \
    envsubst '$WORK_ITEM,$TIMESTAMP' \
    <"$ROOT/platform/state/templates/session-state.md" >"$target/session-state.md"
fi
if [[ ! -f "$target/README.md" ]]; then
  # shellcheck disable=SC2016
  WORK_ITEM="$work_item" TITLE="$title" SOURCE="$source_name" \
    URL="$(jq -r '.url' <<<"$ticket_json")" WORKTREE="$worktree" \
    envsubst '$WORK_ITEM,$TITLE,$SOURCE,$URL,$WORKTREE' \
    <"$ROOT/platform/state/templates/README.md" >"$target/README.md"
fi
touch "$target/history.log"
"$ROOT/platform/context/scripts/init.sh" "$workspace" "$work_item"

default_branch="$("$ROOT/platform/repositories/ensure.sh" "$project_id")"
if [[ "$start_runtime" -eq 1 ]]; then
  start_args=("$workspace" "$work_item")
  start_args+=(--start-point "${start_point:-origin/$default_branch}")
  "$ROOT/platform/runtime/scripts/start.sh" "${start_args[@]}"
fi

printf 'workspace ready: %s/%s\n' "$workspace" "$work_item"
