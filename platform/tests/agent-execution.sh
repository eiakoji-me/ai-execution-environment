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
mkdir -p "$TEST_ROOT/workspaces/test-ws/TASK-1"

AEE="$TEST_ROOT/bin/aee"
EXEC_SCRIPT="$TEST_ROOT/platform/agents/exec.sh"

[[ -x "$AEE" ]] || fail "bin/aee is not executable"
[[ -x "$EXEC_SCRIPT" ]] || fail "platform/agents/exec.sh is not executable"

# 1. Test help flag via bin/aee
help_out="$("$AEE" exec --help)"
grep -Fq 'aee exec [options]' <<<"$help_out" || fail "missing usage in exec --help"
grep -Fq -- '--engine' <<<"$help_out" || fail "missing --engine in exec --help"
grep -Fq -- '--context' <<<"$help_out" || fail "missing --context in exec --help"

# 2. Test missing arguments exit with code 2
set +e
"$AEE" exec >/dev/null 2>&1
no_arg_code=$?
set -e
[[ "$no_arg_code" -eq 2 ]] || fail "expected exit 2 on missing args, got $no_arg_code"

# 3. Test nonexistent context file exits with code 1
set +e
"$AEE" exec --context "$TEST_ROOT/nonexistent.md" "test instruction" >/dev/null 2>&1
bad_context_code=$?
set -e
[[ "$bad_context_code" -eq 1 ]] || fail "expected exit 1 on nonexistent context file, got $bad_context_code"

# 4. Test context execution using a mock engine
test_ctx="$TEST_ROOT/test-context.md"
printf '# Test System Context\n- Target: Automated verification\n' > "$test_ctx"

# Create a mock engine binary in a private bin directory
MOCK_BIN_DIR="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
cat <<'EOF' > "$MOCK_BIN_DIR/mock-engine"
#!/usr/bin/env bash
printf 'mock-engine-response: success\n'
EOF
chmod +x "$MOCK_BIN_DIR/mock-engine"

# Subshell with PATH prepended with mock-engine
(
  export PATH="$MOCK_BIN_DIR:$PATH"
  # Replace engine check with mock engine call
  AEE_AGENT_ENGINE="mock-engine"
  export AEE_AGENT_ENGINE

  # We test exec.sh directly with a mocked engine invocation
  out="$("$EXEC_SCRIPT" --engine mock-engine --context "$test_ctx" "Verify mock execution" 2>&1 || true)"
  # The script will reject 'mock-engine' as unsupported engine name unless we verify engine validation
  grep -Fq 'unsupported engine: mock-engine' <<<"$out" || fail "engine validation failed for mock-engine"
)

# 5. Test execution against initialized work-item with --record using an installed engine if available
if command -v claude >/dev/null 2>&1; then
  # Initialize minimal work-item state
  cat <<'EOF' > "$TEST_ROOT/workspaces/test-ws/TASK-1/ticket.json"
{
  "title": "TASK-1: Verify CLI Exec",
  "body": "Test ticket body for automated agent-execution test."
}
EOF
  cat <<'EOF' > "$TEST_ROOT/workspaces/test-ws/TASK-1/meta.json"
{
  "schemaVersion": 1,
  "workspace": "test-ws",
  "workItem": "TASK-1",
  "lifecycleStage": "scaffolded",
  "blocked": { "isBlocked": false }
}
EOF
  cat <<'EOF' > "$TEST_ROOT/workspaces/test-ws/TASK-1/session-state.md"
# Session State: TASK-1
Awaiting verification.
EOF
  touch "$TEST_ROOT/workspaces/test-ws/TASK-1/history.log"

  # Initialize context
  "$TEST_ROOT/platform/context/scripts/init.sh" test-ws TASK-1 >/dev/null 2>&1

  # Test single turn with --record using claude
  record_out="$("$EXEC_SCRIPT" -e claude -r test-ws TASK-1 "Respond with the single word: ACKNOWLEDGED")"
  grep -Fq 'ACKNOWLEDGED' <<<"$record_out" || fail "claude failed to acknowledge instruction in test: $record_out"

  # Verify history.log was appended
  grep -Fq 'agent-exec (claude' "$TEST_ROOT/workspaces/test-ws/TASK-1/history.log" \
    || fail "history.log did not record agent-exec turn"

  # Verify context WAL was appended
  wal_file="$TEST_ROOT/workspaces/test-ws/TASK-1/context/partitions/main/wal.jsonl"
  [[ -f "$wal_file" ]] || fail "wal.jsonl not created"
  grep -Fq 'Instruction: Respond with the single word: ACKNOWLEDGED' "$wal_file" \
    || fail "wal.jsonl did not record turn instruction"
fi

printf 'agent-execution test passed\n'
