#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  router.sh <stage-name> [options]
  router.sh --meta <path-to-meta.json> [options]

options:
  -e, --engine <name>   Engine override (claude, agy, gemini, codex)
  -t, --tier <name>     Tier override (fast, balanced, deep)
  -m, --meta <file>     Extract next stage from meta.json
  --json                Output decision in JSON format
  -h, --help            Show this help message
EOF
}

stage=""
meta_file=""
engine_override=""
tier_override=""
output_json=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -e|--engine)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      engine_override="$2"
      shift 2
      ;;
    -t|--tier)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      tier_override="$2"
      shift 2
      ;;
    -m|--meta)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      meta_file="$2"
      shift 2
      ;;
    --json)
      output_json=1
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
      if [[ -z "$stage" ]]; then
        stage="$1"
      fi
      shift
      ;;
  esac
done

if [[ -n "$meta_file" ]]; then
  [[ -f "$meta_file" ]] || { printf 'error: meta file not found: %s\n' "$meta_file" >&2; exit 1; }
  current_stage="$(jq -r '.lifecycleStage // empty' "$meta_file")"
  next_agent="$(jq -r '.resume.nextAgent // empty' "$meta_file")"
  
  if [[ -n "$next_agent" && "$next_agent" != "null" ]]; then
    stage="$next_agent"
  else
    case "$current_stage" in
      scaffolded) stage="issue-refinement" ;;
      refined)    stage="solution-designer" ;;
      designed)   stage="implementation" ;;
      implemented) stage="testing" ;;
      tested)     stage="code-reviewer" ;;
      reviewed)   stage="pr-creator" ;;
      pull-request-open) stage="pr-maintainer" ;;
      *)          stage="ticket-coordinator" ;;
    esac
  fi
fi

[[ -n "$stage" ]] || { usage >&2; exit 2; }

# Canonical stage to default tier and strategy mapping
resolved_tier=""
strategy=""
preflight=""

case "$stage" in
  issue-refinement)
    resolved_tier="balanced"
    strategy="single-turn"
    preflight="none"
    ;;
  solution-designer)
    resolved_tier="deep"
    strategy="reasoning-turn"
    preflight="none"
    ;;
  implementation)
    resolved_tier="balanced"
    strategy="worktree-edit"
    preflight="none"
    ;;
  testing)
    resolved_tier="fast"
    strategy="deterministic-first"
    preflight="local-test-runner"
    ;;
  code-reviewer)
    resolved_tier="deep"
    strategy="reasoning-turn"
    preflight="none"
    ;;
  pr-creator)
    resolved_tier="fast"
    strategy="deterministic-git"
    preflight="check-prerequisites"
    ;;
  pr-maintainer)
    resolved_tier="fast"
    strategy="verification"
    preflight="check-upstream-pr"
    ;;
  *)
    resolved_tier="balanced"
    strategy="general"
    preflight="none"
    ;;
esac

# Apply explicit tier override if supplied
if [[ -n "$tier_override" ]]; then
  case "$tier_override" in
    fast|balanced|deep) resolved_tier="$tier_override" ;;
    *) printf 'error: unsupported tier: %s (choose fast, balanced, or deep)\n' "$tier_override" >&2; exit 2 ;;
  esac
fi

resolved_engine="${engine_override:-auto}"

if [[ "$output_json" -eq 1 ]]; then
  jq -n \
    --arg stage "$stage" \
    --arg tier "$resolved_tier" \
    --arg strategy "$strategy" \
    --arg preflight "$preflight" \
    --arg engine "$resolved_engine" \
    '{
      stage: $stage,
      tier: $tier,
      strategy: $strategy,
      preflight: $preflight,
      engine: $engine
    }'
else
  printf '%s\t%s\t%s\t%s\t%s\n' "$stage" "$resolved_tier" "$strategy" "$preflight" "$resolved_engine"
fi
