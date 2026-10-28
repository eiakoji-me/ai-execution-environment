#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
aee - Unified CLI for the AI Execution Environment

Usage:
  aee <command> [subcommand] [arguments...]

Commands:
  runtime       Manage runtime lifecycle, containers, slots, and worktrees
    start       Start or resume a work-item worktree and runtime container
    stop        Stop a running container (preserves worktree and slot)
    close       Close work-item runtime (verifies clean worktree, removes container and worktree)
    list        List all work items, their runtime slots, worktrees, and container statuses
    slots       Manage container-pool capacity and slot assignments
    worktrees   Inspect, repair, and clean up worktrees

  slots         Manage container-pool capacity and slot assignments (shortcut for 'runtime slots')
  worktrees     Inspect, repair, and clean up worktrees (shortcut for 'runtime worktrees')

  repos         Manage canonical repository checkouts and provider synchronization
    status      Show status of canonical checkouts
    ensure      Ensure canonical checkout exists and print default branch
    clone       Clone canonical repository for a project
    fetch       Fetch latest remote refs for a project

  work-items    Inspect and scaffold work items
    list        List work items across workspaces
    scaffold    Scaffold a new work item from an issue source
    status      Show detailed status of a work item

  identity      Manage isolated identity profiles
    list        List configured identity profiles
    init        Initialize a new identity profile
    check       Verify identity profile prerequisites and credentials
    env         Print shell export environment for an identity
    run         Execute a command under a work item or project identity

  context       Manage session context, memory partitions, and snapshots
    init        Initialize context memory structure for a work item
    hydrate     Hydrate the prompt context window for an active session
    append      Append an event to the context WAL
    compact     Trigger context compaction
    snapshot    Manage context snapshots (create, list, restore, switch)

  exec          Execute a single-turn prompt against a work item or context file
  setup         Run environment setup and configuration (plan, apply)
  doctor        Run diagnostic health checks on host tools and configuration
  validate      Run platform portability, shellcheck, and manifest validations
  completion    Generate shell autocompletion script (zsh, bash)
  version       Display CLI and platform version

Options:
  -h, --help    Show this help message
  -v, --version Show version
EOF
}

cmd_repos_usage() {
  cat <<'EOF' >&2
usage:
  aee repos status [project-id]
  aee repos ensure <project-id>
  aee repos clone <project-id>
  aee repos fetch <project-id>
EOF
}

cmd_work_items_usage() {
  cat <<'EOF' >&2
usage:
  aee work-items list
  aee work-items scaffold <source> <key> [--project <project-id>] [--no-start-runtime]
  aee work-items status <workspace-id> <work-item-id>
EOF
}

cmd_context_usage() {
  cat <<'EOF' >&2
usage:
  aee context init <workspace-id> <work-item-id>
  aee context hydrate <workspace-id> <work-item-id> [partition]
  aee context append <workspace-id> <work-item-id> [partition] <message>
  aee context compact <workspace-id> <work-item-id> [partition] [--force]
  aee context snapshot <workspace-id> <work-item-id> <create|list|restore|switch> [args...]
EOF
}

show_work_item_status() {
  local workspace="$1"
  local work_item="$2"
  local meta="$ROOT/workspaces/$workspace/$work_item/meta.json"

  if [[ ! -f "$meta" ]]; then
    printf 'error: work item not found: %s/%s\n' "$workspace" "$work_item" >&2
    exit 1
  fi

  printf 'Work Item: %s/%s\n' "$workspace" "$work_item"
  jq -r '
    "  Project:        " + (.project // "-"),
    "  Stage:          " + (.lifecycleStage // "-"),
    "  Resume Agent:   " + (.resume.nextAgent // "-"),
    "  Runtime Status: " + (.runtime.status // "-"),
    "  Pool Slot:      " + ((.runtime.poolSlot // "-") | tostring),
    "  Worktree:       " + (.runtime.worktree // "-"),
    "  Container ID:   " + (.runtime.containerId // "-"),
    "  Repo Identity:  " + (.identity.repository // "-"),
    "  Issue Identity: " + (.identity.issues // "-"),
    "  Blocked:        " + (if .blocked.isBlocked then ("yes (" + (.blocked.reason // "unknown") + ")") else "no" end)
  ' "$meta"

  printf '  Gates:\n'
  jq -r '.gates | to_entries[] | "    " + .key + ": " + (if .value then "met" else "unmet" end)' "$meta"
}

generate_zsh_completion() {
  cat <<'EOF'
#compdef aee ./bin/aee platform/cli.sh ./platform/cli.sh

_aee() {
  local -a commands
  commands=(
    'runtime:Manage runtime lifecycle, containers, slots, and worktrees'
    'slots:Manage container-pool capacity and slot assignments'
    'worktrees:Inspect, repair, and clean up worktrees'
    'repos:Manage canonical repository checkouts and provider synchronization'
    'work-items:Inspect and scaffold work items'
    'identity:Manage isolated identity profiles'
    'context:Manage session context, memory partitions, and snapshots'
    'exec:Execute a single-turn prompt against a work item or context file'
    'setup:Run environment setup and configuration'
    'doctor:Run diagnostic health checks on host tools'
    'validate:Run platform portability and manifest validations'
    'completion:Generate shell autocompletion script'
    'version:Display CLI and platform version'
    'help:Show help message'
  )

  _arguments -C \
    '(-h --help)'{-h,--help}'[Show help message]' \
    '(-v --version)'{-v,--version}'[Show version]' \
    '1:command:->command' \
    '*::arguments:->args'

  case "$state" in
    command)
      _describe -t commands 'aee command' commands
      ;;
    args)
      case "$words[1]" in
        runtime)
          local -a runtime_subcmds
          runtime_subcmds=(
            'start:Start or resume a work-item worktree and runtime container'
            'stop:Stop a running container'
            'close:Close work-item runtime and release slot'
            'list:List work items and runtime statuses'
            'slots:Manage container-pool slots'
            'worktrees:Inspect, repair, and clean up worktrees'
          )
          _describe -t runtime_subcmds 'runtime subcommand' runtime_subcmds
          ;;
        slots)
          local -a slots_subcmds
          slots_subcmds=(
            'status:Show pool capacity and slot assignments'
            'resize:Resize pool capacity'
            'add:Add slots to the pool'
            'allocate:Allocate a slot to a work item'
            'release:Release a slot from a work item'
            'recreate:Recreate a slot container'
            'cleanup:Clean up orphaned or stale slots'
          )
          _describe -t slots_subcmds 'slots subcommand' slots_subcmds
          ;;
        worktrees)
          local -a worktrees_subcmds
          worktrees_subcmds=(
            'list:List worktrees across workspaces'
            'inspect:Inspect link health and git administrative paths'
            'repair:Repair relative Git paths'
            'cleanup:Prune orphaned or clean inactive worktrees'
          )
          _describe -t worktrees_subcmds 'worktrees subcommand' worktrees_subcmds
          ;;
        repos|repo)
          local -a repos_subcmds
          repos_subcmds=(
            'status:Show status of canonical checkouts'
            'ensure:Ensure canonical checkout exists and print default branch'
            'clone:Clone canonical repository for a project'
            'fetch:Fetch latest remote refs for a project'
            'list:Show status of canonical checkouts'
          )
          _describe -t repos_subcmds 'repos subcommand' repos_subcmds
          ;;
        work-items|work-item|workitem|tasks|task)
          local -a work_items_subcmds
          work_items_subcmds=(
            'list:List work items across workspaces'
            'scaffold:Scaffold a new work item from an issue source'
            'status:Show detailed status of a work item'
          )
          _describe -t work_items_subcmds 'work-items subcommand' work_items_subcmds
          ;;
        identity)
          local -a identity_subcmds
          identity_subcmds=(
            'list:List configured identity profiles'
            'init:Initialize a new identity profile'
            'check:Verify identity profile prerequisites and credentials'
            'env:Print shell export environment for an identity'
            'run:Execute a command under a work item or project identity'
          )
          _describe -t identity_subcmds 'identity subcommand' identity_subcmds
          ;;
        context)
          local -a context_subcmds
          context_subcmds=(
            'init:Initialize context memory structure for a work item'
            'hydrate:Hydrate the prompt context window for an active session'
            'append:Append an event to the context WAL'
            'compact:Trigger context compaction'
            'snapshot:Manage context snapshots'
          )
          _describe -t context_subcmds 'context subcommand' context_subcmds
          ;;
        setup)
          local -a setup_subcmds
          setup_subcmds=(
            'plan:Display setup plan and inspect detected prerequisites'
            'apply:Apply workspace directories, templates, and preferences'
          )
          _describe -t setup_subcmds 'setup subcommand' setup_subcmds
          ;;
        completion)
          local -a completion_subcmds
          completion_subcmds=(
            'zsh:Generate Zsh autocompletion script'
            'bash:Generate Bash autocompletion script'
          )
          _describe -t completion_subcmds 'shell' completion_subcmds
          ;;
      esac
      ;;
  esac
}

compdef _aee aee
compdef _aee ./bin/aee
compdef _aee platform/cli.sh
compdef _aee ./platform/cli.sh
EOF
}

generate_bash_completion() {
  cat <<'EOF'
_aee_completions() {
  local cur prev words cword
  if declare -F _init_completion >/dev/null 2>&1; then
    _init_completion || return
  else
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword="$COMP_CWORD"
  fi

  local commands="runtime slots worktrees repos work-items identity context exec setup doctor validate version completion help"

  if [[ "$cword" -eq 1 ]]; then
    # shellcheck disable=SC2207
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return
  fi

  case "${words[1]}" in
    runtime)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "start stop close list slots worktrees" -- "$cur") )
      ;;
    slots)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "status resize add allocate release recreate cleanup list" -- "$cur") )
      ;;
    worktrees)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "list inspect repair cleanup" -- "$cur") )
      ;;
    repos|repo)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "status ensure clone fetch list" -- "$cur") )
      ;;
    work-items|work-item|workitem|tasks|task)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "list scaffold status" -- "$cur") )
      ;;
    identity)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "list init check env run" -- "$cur") )
      ;;
    context)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "init hydrate append compact snapshot" -- "$cur") )
      ;;
    setup)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "plan apply" -- "$cur") )
      ;;
    completion)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") )
      ;;
  esac
}

complete -F _aee_completions aee
complete -F _aee_completions ./bin/aee
complete -F _aee_completions platform/cli.sh
complete -F _aee_completions ./platform/cli.sh
EOF
}

action="${1:-}"
[[ "$#" -eq 0 ]] || shift

case "$action" in
  runtime)
    exec "$ROOT/platform/runtime/scripts/runtime.sh" "$@"
    ;;
  slots)
    exec "$ROOT/platform/runtime/scripts/slots.sh" "$@"
    ;;
  worktrees)
    exec "$ROOT/platform/runtime/scripts/worktrees.sh" "$@"
    ;;
  repos|repo)
    subcmd="${1:-}"
    [[ "$#" -eq 0 ]] || shift
    case "$subcmd" in
      status|list)
        exec "$ROOT/platform/repositories/status.sh" "$@"
        ;;
      ensure)
        [[ "$#" -ge 1 ]] || { cmd_repos_usage; exit 2; }
        exec "$ROOT/platform/repositories/ensure.sh" "$@"
        ;;
      clone)
        [[ "$#" -ge 1 ]] || { cmd_repos_usage; exit 2; }
        exec "$ROOT/platform/repositories/clone.sh" "$@"
        ;;
      fetch)
        [[ "$#" -ge 1 ]] || { cmd_repos_usage; exit 2; }
        exec "$ROOT/platform/repositories/fetch.sh" "$@"
        ;;
      help|--help|-h)
        cmd_repos_usage
        exit 0
        ;;
      "")
        cmd_repos_usage
        exit 2
        ;;
      *)
        printf 'error: unknown repos subcommand: %s\n' "$subcmd" >&2
        cmd_repos_usage
        exit 2
        ;;
    esac
    ;;
  work-items|work-item|workitem|tasks|task)
    subcmd="${1:-}"
    [[ "$#" -eq 0 ]] || shift
    case "$subcmd" in
      list)
        exec "$ROOT/platform/runtime/scripts/list.sh" "$@"
        ;;
      scaffold)
        [[ "$#" -ge 2 ]] || { cmd_work_items_usage; exit 2; }
        exec "$ROOT/platform/workspace-scaffolder/scaffold.sh" "$@"
        ;;
      status)
        [[ "$#" -eq 2 ]] || { cmd_work_items_usage; exit 2; }
        show_work_item_status "$1" "$2"
        ;;
      help|--help|-h)
        cmd_work_items_usage
        exit 0
        ;;
      "")
        cmd_work_items_usage
        exit 2
        ;;
      *)
        printf 'error: unknown work-items subcommand: %s\n' "$subcmd" >&2
        cmd_work_items_usage
        exit 2
        ;;
    esac
    ;;
  identity)
    if [[ "${1:-}" == "run" ]]; then
      shift
      exec "$ROOT/platform/identity/run.sh" "$@"
    fi
    exec "$ROOT/platform/identity/identity.sh" "$@"
    ;;
  context)
    subcmd="${1:-}"
    [[ "$#" -eq 0 ]] || shift
    case "$subcmd" in
      init)
        [[ "$#" -ge 2 ]] || { cmd_context_usage; exit 2; }
        exec "$ROOT/platform/context/scripts/init.sh" "$@"
        ;;
      hydrate)
        [[ "$#" -ge 2 ]] || { cmd_context_usage; exit 2; }
        exec "$ROOT/platform/context/scripts/hydrate.sh" "$@"
        ;;
      append)
        [[ "$#" -ge 3 ]] || { cmd_context_usage; exit 2; }
        exec "$ROOT/platform/context/scripts/append.sh" "$@"
        ;;
      compact)
        [[ "$#" -ge 2 ]] || { cmd_context_usage; exit 2; }
        exec "$ROOT/platform/context/scripts/compact.sh" "$@"
        ;;
      snapshot)
        [[ "$#" -ge 3 ]] || { cmd_context_usage; exit 2; }
        exec "$ROOT/platform/context/scripts/snapshot.sh" "$@"
        ;;
      help|--help|-h)
        cmd_context_usage
        exit 0
        ;;
      "")
        cmd_context_usage
        exit 2
        ;;
      *)
        printf 'error: unknown context subcommand: %s\n' "$subcmd" >&2
        cmd_context_usage
        exit 2
        ;;
    esac
    ;;
  exec)
    exec "$ROOT/platform/agents/exec.sh" "$@"
    ;;
  setup)
    exec "$ROOT/platform/install/setup.sh" "$@"
    ;;
  doctor)
    exec "$ROOT/platform/install/doctor.sh" "$@"
    ;;
  validate)
    exec "$ROOT/platform/validate.sh" "$@"
    ;;
  completion)
    target="${1:-zsh}"
    case "$target" in
      zsh) generate_zsh_completion ;;
      bash) generate_bash_completion ;;
      *)
        printf 'error: unsupported shell: %s (supported: zsh, bash)\n' "$target" >&2
        exit 2
        ;;
    esac
    exit 0
    ;;
  version|--version|-v)
    printf 'aee version 0.1.0 (ai-execution-environment)\n'
    exit 0
    ;;
  help|--help|-h)
    usage
    exit 0
    ;;
  "")
    usage
    exit 0
    ;;
  *)
    printf 'error: unknown command: %s\n' "$action" >&2
    usage >&2
    exit 2
    ;;
esac
