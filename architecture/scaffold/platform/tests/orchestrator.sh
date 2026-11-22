#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Mirror required platform files into isolated TEST_ROOT
cp -R "$SOURCE_ROOT/platform" "$TEST_ROOT/platform"
cp -R "$SOURCE_ROOT/bin" "$TEST_ROOT/bin"
cp "$SOURCE_ROOT/aee-workspace.yaml" "$TEST_ROOT/aee-workspace.yaml"
if [[ -d "$SOURCE_ROOT/config" ]]; then
  cp -R "$SOURCE_ROOT/config" "$TEST_ROOT/config"
fi
mkdir -p "$TEST_ROOT/workspaces/test-ws/TASK-1"
mkdir -p "$TEST_ROOT/worktrees/test-ws-task-1"

AEE="$TEST_ROOT/bin/aee"
ROUTER="$TEST_ROOT/platform/orchestrator/router.sh"
LOOP="$TEST_ROOT/platform/orchestrator/loop.sh"

[[ -x "$AEE" ]] || fail "bin/aee is not executable"
[[ -x "$ROUTER" ]] || fail "router.sh is not executable"
[[ -x "$LOOP" ]] || fail "loop.sh is not executable"

# 1. CLI help flag verification
"$AEE" orchestrate --help >/dev/null || fail "aee orchestrate --help failed"
"$AEE" loop --help >/dev/null || fail "aee loop --help failed"
"$AEE" route --help >/dev/null || fail "aee route --help failed"

# 2. Router unit tests: stage to tier & strategy mapping
read -r stage tier strat _ _ < <("$ROUTER" issue-refinement)
[[ "$stage" == "issue-refinement" ]] || fail "expected issue-refinement, got $stage"
[[ "$tier" == "balanced" ]] || fail "expected balanced tier, got $tier"
[[ "$strat" == "single-turn" ]] || fail "expected single-turn strategy, got $strat"

read -r stage tier strat _ _ < <("$ROUTER" solution-designer)
[[ "$stage" == "solution-designer" ]] || fail "expected solution-designer, got $stage"
[[ "$tier" == "deep" ]] || fail "expected deep tier, got $tier"
[[ "$strat" == "reasoning-turn" ]] || fail "expected reasoning-turn strategy, got $strat"

read -r stage tier strat _ _ < <("$ROUTER" testing)
[[ "$stage" == "testing" ]] || fail "expected testing, got $stage"
[[ "$tier" == "fast" ]] || fail "expected fast tier, got $tier"
[[ "$strat" == "deterministic-first" ]] || fail "expected deterministic-first strategy, got $strat"

# 3. Router JSON output and flag overrides
json_out="$("$ROUTER" solution-designer --tier fast --engine codex --json)"
jq -e '
  .stage == "solution-designer" and
  .tier == "fast" and
  .strategy == "reasoning-turn" and
  .engine == "codex"
' <<<"$json_out" >/dev/null || fail "router json output or overrides failed: $json_out"

# 4. Router stage inference from meta.json
meta_test="$TEST_ROOT/workspaces/test-ws/TASK-1/meta.json"
cat <<'EOF' > "$meta_test"
{
  "schemaVersion": 1,
  "lifecycleStage": "designed",
  "resume": {
    "nextAgent": null
  }
}
EOF

read -r stage tier strat _ _ < <("$ROUTER" --meta "$meta_test")
[[ "$stage" == "implementation" ]] || fail "expected implementation from designed stage, got $stage"

# Update nextAgent in meta.json
jq '.resume.nextAgent = "code-reviewer"' "$meta_test" > "$meta_test.tmp" && mv "$meta_test.tmp" "$meta_test"
read -r stage tier strat _ _ < <("$ROUTER" --meta "$meta_test")
[[ "$stage" == "code-reviewer" ]] || fail "expected code-reviewer from nextAgent, got $stage"
[[ "$tier" == "deep" ]] || fail "expected deep tier for code-reviewer, got $tier"

# 5. Orchestrator Loop: Dry run verification
cat <<'EOF' > "$meta_test"
{
  "schemaVersion": 1,
  "lifecycleStage": "scaffolded",
  "identity": { "id": "test-id" },
  "runtime": { "worktree": "worktrees/test-ws-task-1" },
  "blocked": { "isBlocked": false },
  "loops": {
    "implementation": { "attempts": 0, "maxAttempts": 3 },
    "testing": { "attempts": 0, "maxAttempts": 3 },
    "review": { "attempts": 0, "maxAttempts": 3 }
  },
  "resume": { "nextAgent": "issue-refinement" }
}
EOF
cat <<'EOF' > "$TEST_ROOT/workspaces/test-ws/TASK-1/ticket.json"
{
  "title": "TASK-1: Autonomous Loop Test",
  "body": "Test ticket description."
}
EOF
printf '# Session State\n\n- Phase: scaffolded\n' > "$TEST_ROOT/workspaces/test-ws/TASK-1/session-state.md"

dry_run_out="$(cd "$TEST_ROOT" && "$AEE" loop test-ws TASK-1 --dry-run)"
grep -Fq '[dry-run] Would execute '\''issue-refinement'\''' <<<"$dry_run_out" || fail "dry-run output missing expected execution note: $dry_run_out"

# 6. Deterministic Pre-Flight Test Bypass (zero token spend)
# Set meta.json to stage "implemented", nextAgent "testing"
jq '
  .lifecycleStage = "implemented" |
  .resume.nextAgent = "testing" |
  .gates.testsPassing = false
' "$meta_test" > "$meta_test.tmp" && mv "$meta_test.tmp" "$meta_test"

# Create mock test suite in worktree that succeeds
cat <<'EOF' > "$TEST_ROOT/worktrees/test-ws-task-1/package.json"
{
  "name": "test-pkg",
  "scripts": {
    "test": "echo 'mock unit tests: PASS'"
  }
}
EOF

(
  cd "$TEST_ROOT"
  "$AEE" loop test-ws TASK-1 --max-turns 1
)

# Verify stage advanced deterministically to "tested" and nextAgent is "code-reviewer"
jq -e '
  .lifecycleStage == "tested" and
  .gates.testsPassing == true and
  .resume.nextAgent == "code-reviewer" and
  .resume.lastUpdatedBy == "orchestrator-deterministic"
' "$meta_test" >/dev/null || fail "deterministic test bypass failed to update meta.json: $(cat "$meta_test")"

[[ -f "$TEST_ROOT/workspaces/test-ws/TASK-1/artifacts/test-results.md" ]] || fail "missing test-results.md artifact"

# 7. Bounded cycle guard: max attempts exceeded blocks work item
jq '
  .lifecycleStage = "implemented" |
  .resume.nextAgent = "testing" |
  .blocked.isBlocked = false |
  .loops.testing.attempts = 3 |
  .loops.testing.maxAttempts = 3
' "$meta_test" > "$meta_test.tmp" && mv "$meta_test.tmp" "$meta_test"

set +e
(cd "$TEST_ROOT" && "$AEE" loop test-ws TASK-1 >/dev/null 2>&1)
exit_code=$?
set -e

[[ "$exit_code" -eq 1 ]] || fail "expected exit code 1 for blocked loop, got $exit_code"
jq -e '
  .blocked.isBlocked == true and
  .blocked.reason == "testing attempts limit exceeded"
' "$meta_test" >/dev/null || fail "loop counter guard did not block work item properly: $(cat "$meta_test")"

# 8. Terminal state handling: closed work item exits 0
jq '
  .blocked.isBlocked = false |
  .lifecycleStage = "closed" |
  .closed = { "isClosed": true, "reason": "completed" }
' "$meta_test" > "$meta_test.tmp" && mv "$meta_test.tmp" "$meta_test"

(cd "$TEST_ROOT" && "$AEE" loop test-ws TASK-1 >/dev/null 2>&1) || fail "closed work item should exit 0"

printf 'orchestrator test passed\n'
