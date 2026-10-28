#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
usage:
  aee exec [options] <workspace-id> <work-item-id> <instruction>
  aee exec [options] --context <file> <instruction>

options:
  -e, --engine <engine>   Engine to use: claude, agy, gemini, codex (default: auto-detected)
  -c, --context <file>    Path to an external context file (Markdown or text)
  -r, --record            Record this turn into the work item's Context WAL and history log
  -h, --help              Show this help message
EOF
}

engine=""
context_file=""
record_turn=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -e|--engine)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      engine="$2"
      shift 2
      ;;
    -c|--context)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      context_file="$2"
      shift 2
      ;;
    -r|--record)
      record_turn=1
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
      break
      ;;
  esac
done

workspace=""
work_item=""
instruction=""

if [[ -n "$context_file" ]]; then
  [[ -f "$context_file" ]] || { printf 'error: context file not found: %s\n' "$context_file" >&2; exit 1; }
  [[ "$#" -ge 1 ]] || { usage >&2; exit 2; }
  instruction="$*"
else
  [[ "$#" -ge 3 ]] || { usage >&2; exit 2; }
  workspace="$1"
  work_item="$2"
  shift 2
  instruction="$*"
fi

# Detect default engine if unspecified
if [[ -z "$engine" ]]; then
  if [[ -n "${AEE_AGENT_ENGINE:-}" ]]; then
    engine="$AEE_AGENT_ENGINE"
  elif command -v claude >/dev/null 2>&1; then
    engine="claude"
  elif command -v agy >/dev/null 2>&1; then
    engine="agy"
  elif command -v gemini >/dev/null 2>&1; then
    engine="gemini"
  elif command -v codex >/dev/null 2>&1; then
    engine="codex"
  else
    printf 'error: no supported AI CLI engine found (installed: claude, agy, gemini, codex)\n' >&2
    exit 1
  fi
fi

temp_context="$(mktemp /tmp/aee-turn-XXXXXX.md)"
cleanup() {
  rm -f "$temp_context"
}
trap cleanup EXIT

if [[ -n "$context_file" ]]; then
  cat "$context_file" > "$temp_context"
else
  item_dir="$ROOT/workspaces/$workspace/$work_item"
  if [[ ! -d "$item_dir" ]]; then
    printf 'error: work item directory not found: %s\n' "$item_dir" >&2
    exit 1
  fi

  # Hydrate context state from aee memory model
  hydrated_json="$("$ROOT/platform/context/scripts/hydrate.sh" "$workspace" "$work_item")"

  {
    printf '# AI Execution Environment Session Context\n\n'
    printf '## Work Item: %s/%s\n\n' "$workspace" "$work_item"

    if [[ -f "$item_dir/ticket.json" ]]; then
      printf '### Ticket Details\n'
      jq -r '
        "- **Title**: " + (.title // "-"),
        "- **Type**: " + (.type // "-"),
        "- **Key**: " + (.key // "-"),
        "- **URL**: " + (.url // "-"),
        "\n**Description**:\n" + (.body // "No description provided.")
      ' "$item_dir/ticket.json"
      printf '\n\n'
    fi

    if [[ -f "$item_dir/meta.json" ]]; then
      printf '### Pipeline State\n'
      jq -r '
        "- **Lifecycle Stage**: " + (.lifecycleStage // "-"),
        "- **Next Agent**: " + (.resume.nextAgent // "-"),
        "- **Blocked**: " + (if .blocked.isBlocked then ("yes (" + (.blocked.reason // "unknown") + ")") else "no" end)
      ' "$item_dir/meta.json"
      printf '\n'
    fi

    printf '### Memory & Active State (from aee Context Engine)\n'
    active_count="$(jq -r '.activeState | length' <<<"$hydrated_json")"
    if [[ "$active_count" -gt 0 ]]; then
      jq -r '.activeState[] | "- **" + .key + "**: " + (.value | tostring)' <<<"$hydrated_json"
    else
      printf '*(No active memory entries in MemTable/SSTables)*\n'
    fi
    printf '\n'

    if [[ -f "$item_dir/session-state.md" ]]; then
      printf '### Recent Session Narrative\n'
      cat "$item_dir/session-state.md"
      printf '\n'
    fi
  } > "$temp_context"
fi

response_output=""

case "$engine" in
  claude)
    response_output="$(claude -p --append-system-prompt "$(cat "$temp_context")" "$instruction")"
    ;;
  agy)
    combined_prompt="$(printf 'Context:\n%s\n\nInstruction:\n%s\n' "$(cat "$temp_context")" "$instruction")"
    response_output="$(agy -p "$combined_prompt")"
    ;;
  gemini)
    response_output="$(gemini -p "$instruction" < "$temp_context")"
    ;;
  codex)
    combined_prompt="$(printf 'Context:\n%s\n\nInstruction:\n%s\n' "$(cat "$temp_context")" "$instruction")"
    response_output="$(codex exec "$combined_prompt")"
    ;;
  *)
    printf 'error: unsupported engine: %s (supported: claude, agy, gemini, codex)\n' "$engine" >&2
    exit 2
    ;;
esac

printf '%s\n' "$response_output"

if [[ "$record_turn" -eq 1 && -n "$workspace" && -n "$work_item" ]]; then
  item_dir="$ROOT/workspaces/$workspace/$work_item"
  # Record to Context WAL
  turn_key="exec-$(date +%s)"
  "$ROOT/platform/context/scripts/append.sh" "$workspace" "$work_item" --kind turn --key "$turn_key" --value "Instruction: $instruction"
  # Append to history.log
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '[%s] agent-exec (%s): %s\n' "$timestamp" "$engine" "$instruction" >> "$item_dir/history.log"
fi
