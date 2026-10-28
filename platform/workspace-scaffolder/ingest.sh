#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
usage:
  aee ingest <issue-url-or-ref> [options]

options:
  -p, --project <project-id>   Explicit project ID override
  -e, --engine <engine>        AI engine: claude, agy, gemini, codex (default: auto-detected)
  -t, --type <FEAT|FIX|TASK>   Work-item type override
  --no-refine                  Scaffold only; skip automatic headless refinement
  --no-start                   Do not start the container/worktree during scaffolding
  --start-point <ref>          Git upstream start point for branch creation
  -h, --help                   Show this help message
EOF
}

issue_ref=""
project_arg=""
engine_arg=""
type_arg=""
no_refine=0
no_start=0
start_point=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -p|--project)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      project_arg="$2"
      shift 2
      ;;
    -e|--engine)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      engine_arg="$2"
      shift 2
      ;;
    -t|--type)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      type_arg="$2"
      shift 2
      ;;
    --no-refine)
      no_refine=1
      shift
      ;;
    --no-start)
      no_start=1
      shift
      ;;
    --start-point)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      start_point="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$issue_ref" ]]; then
        issue_ref="$1"
      fi
      shift
      ;;
  esac
done

[[ -n "$issue_ref" ]] || { usage >&2; exit 2; }

# 1. Resolve issue reference into project and workspace
resolve_args=("$issue_ref")
if [[ -n "$project_arg" ]]; then
  resolve_args+=(--project "$project_arg")
fi

resolved="$("$ROOT/platform/workspace-scaffolder/resolve.sh" "${resolve_args[@]}")"
IFS=$'\t' read -r resolved_project resolved_workspace resolved_provider resolved_number <<<"$resolved"

printf '==> Resolved issue to project %s (%s, provider: %s, #%s)\n' "$resolved_project" "$resolved_workspace" "$resolved_provider" "$resolved_number"

# 2. Scaffold work item
scaffold_cmd=("$ROOT/platform/workspace-scaffolder/scaffold.sh" "$resolved_workspace" "$resolved_number")
if [[ -n "$type_arg" ]]; then
  scaffold_cmd+=(--type "$type_arg")
fi
if [[ "$no_start" -eq 1 ]]; then
  scaffold_cmd+=(--no-start)
fi
if [[ -n "$start_point" ]]; then
  scaffold_cmd+=(--start-point "$start_point")
fi

scaffold_output="$("${scaffold_cmd[@]}")"
printf '%s\n' "$scaffold_output"

# Derive work item ID from scaffold output: "workspace ready: <workspace>/<work-item>"
work_item="$(sed -n 's|workspace ready: [^/]*/\(.*\)|\1|p' <<<"$scaffold_output" | tail -n 1)"
[[ -n "$work_item" ]] || { printf 'error: unable to determine scaffolded work-item id\n' >&2; exit 1; }

item_dir="$ROOT/workspaces/$resolved_workspace/$work_item"
meta_file="$item_dir/meta.json"
[[ -f "$meta_file" ]] || { printf 'error: meta.json not found: %s\n' "$meta_file" >&2; exit 1; }

# 3. Headless issue-refinement stage
if [[ "$no_refine" -eq 0 ]]; then
  printf '==> Executing headless issue-refinement stage for %s/%s...\n' "$resolved_workspace" "$work_item"

  refine_prompt="You are executing the 'issue-refinement' pipeline stage in this execution environment. Read ticket.json, meta.json, session-state.md, and the worktree. Analyze the issue requirements, scope, exclusions, acceptance criteria, and edge cases. Produce a comprehensive refined issue specification in Markdown. Return your refined issue specification clearly."

  exec_cmd=("$ROOT/platform/agents/exec.sh" --record "$resolved_workspace" "$work_item" "$refine_prompt")
  if [[ -n "$engine_arg" ]]; then
    exec_cmd+=(--engine "$engine_arg")
  fi

  refine_response="$("${exec_cmd[@]}")"

  # Save refined issue artifact
  mkdir -p "$item_dir/artifacts"
  printf '%s\n' "$refine_response" > "$item_dir/artifacts/refined-issue.md"

  # Advance lifecycleStage in meta.json
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  jq \
    --arg ts "$timestamp" \
    '.lifecycleStage = "refined"
     | .gates.definitionOfReadyMet = true
     | .resume.nextAgent = "solution-designer"
     | .resume.lastUpdatedBy = "agent-ingest"
     | .resume.lastUpdatedAt = $ts' \
    "$meta_file" > "$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"

  # Overwrite session-state.md narrative checkpoint
  cat <<EOF > "$item_dir/session-state.md"
# Session State: $work_item

- **Work Item**: $work_item
- **Current Stage**: refined
- **Next Recommended Action**: Execute solution-designer to produce the architecture design plan.

## Narrative Checkpoint
Issue refinement completed headlessly via \`aee ingest\`. Scope, exclusions, and acceptance criteria recorded in \`artifacts/refined-issue.md\`.
EOF

  printf '\n==> Ingestion and refinement complete!\n'
  printf '  Work Item:    %s/%s\n' "$resolved_workspace" "$work_item"
  printf '  Stage:        refined\n'
  printf '  Artifact:     workspaces/%s/%s/artifacts/refined-issue.md\n' "$resolved_workspace" "$work_item"
  printf '  Next Agent:   solution-designer\n'
else
  printf '==> Work item scaffolded (refinement skipped via --no-refine): %s/%s\n' "$resolved_workspace" "$work_item"
fi
