#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROUTER="$ROOT/platform/orchestrator/router.sh"
COMPOSE="$ROOT/platform/prompts/compose.sh"
EXEC="$ROOT/platform/agents/exec.sh"

usage() {
  cat <<'EOF'
usage:
  aee orchestrate <workspace-id> <work-item-id> [options]
  aee loop <workspace-id> <work-item-id> [options]

options:
  -n, --max-turns <N>   Maximum loop turns before stopping (default: 10)
  -e, --engine <name>   Engine override: claude, agy, gemini, codex (default: auto)
  -t, --tier <tier>     Tier override: fast, balanced, deep (default: stage-routed)
  --auto-pr             Automatically create pull request when review passes
  --dry-run             Inspect stage routing without running worker agents
  -v, --verbose         Print verbose execution details
  -h, --help            Show this help message
EOF
}

workspace=""
work_item=""
max_turns=10
engine="auto"
tier_override=""
auto_pr=0
dry_run=0
verbose=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -n|--max-turns)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      max_turns="$2"
      shift 2
      ;;
    -e|--engine)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      engine="$2"
      shift 2
      ;;
    -t|--tier)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      tier_override="$2"
      shift 2
      ;;
    --auto-pr)
      auto_pr=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -v|--verbose)
      verbose=1
      shift
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
      if [[ -z "$workspace" ]]; then
        workspace="$1"
      elif [[ -z "$work_item" ]]; then
        work_item="$1"
      fi
      shift
      ;;
  esac
done

# If no arguments provided, check context inference from working directory
if [[ -z "$workspace" && -n "${AEE_WORKSPACE:-}" ]]; then
  workspace="$AEE_WORKSPACE"
fi
if [[ -z "$work_item" && -n "${AEE_WORK_ITEM:-}" ]]; then
  work_item="$AEE_WORK_ITEM"
fi

[[ -n "$workspace" && -n "$work_item" ]] || { usage >&2; exit 2; }

item_dir="$ROOT/workspaces/$workspace/$work_item"
meta_file="$item_dir/meta.json"
session_file="$item_dir/session-state.md"
history_file="$item_dir/history.log"
artifacts_dir="$item_dir/artifacts"

[[ -f "$meta_file" ]] || { printf 'error: meta.json not found: %s\n' "$meta_file" >&2; exit 1; }
mkdir -p "$artifacts_dir"

log() {
  printf '==> [orchestrator] %s\n' "$*"
}

log_verbose() {
  if [[ "$verbose" -eq 1 ]]; then
    printf '    [debug] %s\n' "$*"
  fi
}

append_history() {
  local entry="$1"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '[%s] orchestrator: %s\n' "$ts" "$entry" >>"$history_file"
}

update_narrative() {
  local current_stage="$1"
  local summary="$2"
  local next_action="$3"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  cat <<EOF >"$session_file"
# Session State: $work_item

- **Workspace**: $workspace
- **Work Item**: $work_item
- **Current Stage**: $current_stage
- **Last Updated**: $ts by orchestrator-loop
- **Next Recommended Action**: $next_action

## Narrative Checkpoint
$summary
EOF
}

wt_rel="$(jq -r '.runtime.worktree // empty' "$meta_file")"
if [[ -z "$wt_rel" ]]; then
  wt_rel="worktrees/$(printf '%s-%s' "$workspace" "$work_item" | tr '[:upper:]' '[:lower:]')"
fi
abs_worktree="$ROOT/$wt_rel"

log "Starting autonomous orchestration for $workspace/$work_item (max turns: $max_turns)"

turn=1
while [[ "$turn" -le "$max_turns" ]]; do
  log_verbose "Loop iteration $turn of $max_turns"

  # 1. Read machine state
  stage="$(jq -r '.lifecycleStage // "scaffolded"' "$meta_file")"
  is_blocked="$(jq -r '.blocked.isBlocked // false' "$meta_file")"
  block_reason="$(jq -r '.blocked.reason // empty' "$meta_file")"

  # 2. Check terminal and blocked conditions
  if [[ "$is_blocked" == "true" ]]; then
    log "Work item is BLOCKED: ${block_reason:-unspecified}"
    append_history "execution paused: work item is blocked (${block_reason:-unspecified})"
    exit 1
  fi

  if [[ "$stage" == "closed" ]]; then
    closed_reason="$(jq -r '.closed.reason // "completed"' "$meta_file")"
    log "Work item is CLOSED (reason: $closed_reason)"
    append_history "work item closed (reason: $closed_reason)"
    exit 0
  fi

  if [[ "$stage" == "pull-request-open" ]]; then
    pr_url="$(jq -r '.design.pullRequestUrl // .source.url // "open"' "$meta_file")"
    log "Pull request is open: $pr_url"
    append_history "orchestration complete: pull request is open ($pr_url)"
    exit 0
  fi

  # 3. Route stage via Router
  router_decision="$("$ROUTER" --meta "$meta_file" ${tier_override:+--tier "$tier_override"} ${engine:+--engine "$engine"} --json)"
  target_stage="$(jq -r '.stage' <<<"$router_decision")"
  target_tier="$(jq -r '.tier' <<<"$router_decision")"
  target_strategy="$(jq -r '.strategy' <<<"$router_decision")"
  target_engine="$(jq -r '.engine' <<<"$router_decision")"

  log "Turn $turn/$max_turns: Stage '$stage' ➔ executing '$target_stage' [tier: $target_tier, strategy: $target_strategy]"

  # 4. Gate / Prerequisite checks
  if [[ "$target_stage" == "pr-creator" && "$auto_pr" -eq 0 ]]; then
    log "Review approved! Work item is ready for PR creation (pass --auto-pr to open automatically)."
    append_history "paused before pr-creator: awaiting operator approval"
    exit 0
  fi

  # 5. Check loop counters for bounded cycle protection
  case "$target_stage" in
    implementation)
      attempts="$(jq -r '.loops.implementation.attempts // 0' "$meta_file")"
      max_attempts="$(jq -r '.loops.implementation.maxAttempts // 3' "$meta_file")"
      if [[ "$attempts" -ge "$max_attempts" ]]; then
        log "Implementation loop counter exceeded ($attempts/$max_attempts). Blocking work item."
        ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        jq --arg ts "$ts" '.blocked = {isBlocked: true, reason: "implementation attempts limit exceeded", since: $ts}' \
          "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
        append_history "blocked: implementation loop limit ($attempts/$max_attempts)"
        exit 1
      fi
      ;;
    testing)
      attempts="$(jq -r '.loops.testing.attempts // 0' "$meta_file")"
      max_attempts="$(jq -r '.loops.testing.maxAttempts // 3' "$meta_file")"
      if [[ "$attempts" -ge "$max_attempts" ]]; then
        log "Testing loop counter exceeded ($attempts/$max_attempts). Blocking work item."
        ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        jq --arg ts "$ts" '.blocked = {isBlocked: true, reason: "testing attempts limit exceeded", since: $ts}' \
          "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
        append_history "blocked: testing loop limit ($attempts/$max_attempts)"
        exit 1
      fi
      ;;
    code-reviewer)
      attempts="$(jq -r '.loops.review.attempts // 0' "$meta_file")"
      max_attempts="$(jq -r '.loops.review.maxAttempts // 3' "$meta_file")"
      if [[ "$attempts" -ge "$max_attempts" ]]; then
        log "Review loop counter exceeded ($attempts/$max_attempts). Blocking work item."
        ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        jq --arg ts "$ts" '.blocked = {isBlocked: true, reason: "review attempts limit exceeded", since: $ts}' \
          "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
        append_history "blocked: review loop limit ($attempts/$max_attempts)"
        exit 1
      fi
      ;;
  esac

  # 6. Dry run early exit
  if [[ "$dry_run" -eq 1 ]]; then
    log "[dry-run] Would execute '$target_stage' via $target_engine (tier: $target_tier)"
    exit 0
  fi

  # 7. Deterministic Pre-Flight Bypass (Zero Token Spend Optimization)
  if [[ "$target_stage" == "testing" && -d "$abs_worktree" ]]; then
    log "Running deterministic test pre-flight check in $wt_rel..."
    test_passed=0
    test_output=""

    # Try detecting project test command
    if [[ -f "$abs_worktree/package.json" ]] && grep -q '"test":' "$abs_worktree/package.json"; then
      set +e
      if command -v pnpm >/dev/null 2>&1; then
        test_output="$(cd "$abs_worktree" && pnpm test 2>&1)"
      else
        test_output="$(cd "$abs_worktree" && npm test 2>&1)"
      fi
      local_rc=$?
      set -e
      if [[ "$local_rc" -eq 0 ]]; then
        test_passed=1
      fi
    elif [[ -f "$abs_worktree/platform/validate.sh" ]]; then
      set +e
      test_output="$(cd "$abs_worktree" && ./platform/validate.sh 2>&1)"
      local_rc=$?
      set -e
      if [[ "$local_rc" -eq 0 ]]; then
        test_passed=1
      fi
    fi

    if [[ "$test_passed" -eq 1 ]]; then
      log "Deterministic test suite PASSED. Advancing without calling LLM (zero tokens spent)."
      # shellcheck disable=SC2016
      printf '# Test Results\n\nDeterministic verification passed successfully.\n\n```\n%s\n```\n' "$test_output" \
        >"$artifacts_dir/test-results.md"
      
      ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      jq --arg ts "$ts" \
        '.lifecycleStage = "tested"
         | .gates.testsPassing = true
         | .resume.nextAgent = "code-reviewer"
         | .resume.lastUpdatedBy = "orchestrator-deterministic"
         | .resume.lastUpdatedAt = $ts' \
        "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
      
      update_narrative "tested" "Deterministic tests passed in worktree." "Execute code-reviewer to review code diffs."
      append_history "stage testing: passed deterministically without LLM"
      turn=$((turn + 1))
      continue
    fi
  fi

  # 8. Compose stage prompt
  log "Composing prompt for stage '$target_stage'..."
  stage_prompt="$("$COMPOSE" -r "$target_stage" -w "$workspace" -i "$work_item" -t "$target_tier" \
    --instruction "Execute the $target_stage pipeline stage. Adhere strictly to the role directives, update deliverables, and report your progress.")"

  # 9. Execute worker via CLI Gateway
  log "Invoking worker via CLI Gateway [tier: $target_tier]..."
  exec_args=("$workspace" "$work_item" "$stage_prompt" --record -t "$target_tier")
  if [[ "$target_engine" != "auto" ]]; then
    exec_args+=(-e "$target_engine")
  fi

  set +e
  worker_output="$("$EXEC" "${exec_args[@]}")"
  exec_status=$?
  set -e

  if [[ "$exec_status" -ne 0 ]]; then
    log "Worker execution failed with exit code $exec_status"
    append_history "stage $target_stage: execution error ($exec_status)"
    exit "$exec_status"
  fi

  # 10. Advance state based on stage results
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  case "$target_stage" in
    issue-refinement)
      printf '%s\n' "$worker_output" >"$artifacts_dir/refined-issue.md"
      jq --arg ts "$ts" \
        '.lifecycleStage = "refined"
         | .gates.definitionOfReadyMet = true
         | .resume.nextAgent = "solution-designer"
         | .resume.lastUpdatedBy = "orchestrator-loop"
         | .resume.lastUpdatedAt = $ts' \
        "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
      update_narrative "refined" "Issue refinement completed. Deliverables recorded in artifacts/refined-issue.md." "Execute solution-designer."
      append_history "stage issue-refinement: completed"
      ;;

    solution-designer)
      printf '%s\n' "$worker_output" >"$artifacts_dir/design-plan.md"
      jq --arg ts "$ts" \
        '.lifecycleStage = "designed"
         | .gates.designApproved = true
         | .resume.nextAgent = "implementation"
         | .resume.lastUpdatedBy = "orchestrator-loop"
         | .resume.lastUpdatedAt = $ts' \
        "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
      update_narrative "designed" "Technical architecture plan designed in artifacts/design-plan.md." "Execute implementation."
      append_history "stage solution-designer: completed"
      ;;

    implementation)
      # Increment implementation attempts
      jq --arg ts "$ts" \
        '.lifecycleStage = "implemented"
         | .gates.implementationComplete = true
         | .loops.implementation.attempts = ((.loops.implementation.attempts // 0) + 1)
         | .resume.nextAgent = "testing"
         | .resume.lastUpdatedBy = "orchestrator-loop"
         | .resume.lastUpdatedAt = $ts' \
        "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
      update_narrative "implemented" "Implementation changes committed to task branch." "Execute testing."
      append_history "stage implementation: completed (attempt $(jq -r '.loops.implementation.attempts' "$meta_file"))"
      ;;

    testing)
      printf '%s\n' "$worker_output" >"$artifacts_dir/test-results.md"
      jq --arg ts "$ts" \
        '.lifecycleStage = "tested"
         | .gates.testsPassing = true
         | .loops.testing.attempts = ((.loops.testing.attempts // 0) + 1)
         | .resume.nextAgent = "code-reviewer"
         | .resume.lastUpdatedBy = "orchestrator-loop"
         | .resume.lastUpdatedAt = $ts' \
        "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
      update_narrative "tested" "Test verification completed and recorded in artifacts/test-results.md." "Execute code-reviewer."
      append_history "stage testing: completed"
      ;;

    code-reviewer)
      printf '%s\n' "$worker_output" >"$artifacts_dir/review-verdict.md"
      # Check if verdict contains approval
      is_approved=0
      if grep -Eqi "(approved|verdict: approved|lgtm|accepted)" <<<"$worker_output"; then
        is_approved=1
      fi

      if [[ "$is_approved" -eq 1 ]]; then
        jq --arg ts "$ts" \
          '.lifecycleStage = "reviewed"
           | .gates.reviewApproved = true
           | .review.verdict = "approved"
           | .resume.nextAgent = "pr-creator"
           | .resume.lastUpdatedBy = "orchestrator-loop"
           | .resume.lastUpdatedAt = $ts' \
          "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
        update_narrative "reviewed" "Automated peer review approved." "Execute pr-creator."
        append_history "stage code-reviewer: approved"
      else
        jq --arg ts "$ts" \
          '.lifecycleStage = "review-rejected"
           | .gates.reviewApproved = false
           | .review.verdict = "rejected"
           | .loops.review.attempts = ((.loops.review.attempts // 0) + 1)
           | .resume.nextAgent = "implementation"
           | .resume.lastUpdatedBy = "orchestrator-loop"
           | .resume.lastUpdatedAt = $ts' \
          "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
        update_narrative "review-rejected" "Review requested changes. Returning to implementation." "Execute implementation."
        append_history "stage code-reviewer: rejected (returning to implementation)"
      fi
      ;;

    pr-creator)
      # Pull request creation
      if [[ "$auto_pr" -eq 1 ]]; then
        branch_name="$(jq -r '.design.branch // empty' "$meta_file")"
        pr_title="$(jq -r '.title // "feat: resolve work item"' "$item_dir/ticket.json" 2>/dev/null || echo "feat: $work_item")"
        pr_body="$(cat <<EOF
## Description
Resolves work item \`$work_item\`.

## Artifacts
- Refined Issue: \`artifacts/refined-issue.md\`
- Design Plan: \`artifacts/design-plan.md\`
- Test Results: \`artifacts/test-results.md\`
- Review Verdict: \`artifacts/review-verdict.md\`

Generated autonomously by AEE Orchestrator Loop.
EOF
)"
        repo_identity="$(jq -r '.identity.repository // "default"' "$meta_file")"

        log "Opening Pull Request against dev for branch $branch_name..."
        pr_url="$("$ROOT/platform/identity/run.sh" --identity "$repo_identity" -- gh pr create \
          --base dev \
          --head "$branch_name" \
          --title "$pr_title" \
          --body "$pr_body" 2>/dev/null || true)"

        if [[ -n "$pr_url" ]]; then
          jq --arg ts "$ts" --arg url "$pr_url" \
            '.lifecycleStage = "pull-request-open"
             | .design.pullRequestUrl = $url
             | .resume.nextAgent = "pr-maintainer"
             | .resume.lastUpdatedBy = "orchestrator-loop"
             | .resume.lastUpdatedAt = $ts' \
            "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
          log "Pull request successfully created: $pr_url"
          append_history "stage pr-creator: pull request created ($pr_url)"
        fi
      fi
      ;;
  esac

  turn=$((turn + 1))
done

log "Reached maximum loop turns ($max_turns). Orchestrator paused."
exit 0
