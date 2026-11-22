# Platform

The executable control plane:

- `cli.sh` (`bin/aee`): unified CLI dispatcher across runtime, slots, worktrees, repositories, work items, identities, context, orchestrator, fleet, setup, and diagnostics
- `install/`: materialize and diagnose a local instance
- `repositories/`: canonical repository inventory and provider adapters
- `identity/`: named credential profiles every Git and provider command runs under
- `workspace-scaffolder/`: normalized issue intake and work-item creation
- `state/`: lifecycle schema and cross-stage memory protocol
- `runtime/`: disposable worktrees, runtime CLI (`runtime.sh`), and an exclusive per-worktree container pool
- `workflows/`: tool-neutral pipeline-stage definitions
- `interfaces/`: agent-interface adapters that enforce existing policy
- `orchestrator/`: autonomous loop harness (`loop.sh`) and stage-to-model router (`router.sh`)
- `prompts/`: context-hydrated prompt composition (`compose.sh`)
- `agents/`: CLI-native gateway and headless agent execution (`exec.sh`)
- `fleet/`: multi-agent concurrent dispatch and queue management
- `jobs/`: background Long-Running Operations (LROs) and executive morning briefings
