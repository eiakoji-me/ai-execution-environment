# Orchestrator & Dynamic Model Router

The Orchestrator subsystem provides an autonomous, multi-turn supervisory loop and stage-to-model router for issue-driven work items.

## Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                      AEE Orchestrator Subsystem                        │
│                                                                        │
│   aee orchestrate <workspace> <work-item>                              │
│         │                                                              │
│         ▼                                                              │
│   ┌───────────────┐     Route Stage      ┌─────────────────────────┐   │
│   │    Loop       │ ───────────────────► │      Stage Router       │   │
│   │    Harness    │ ◄─────────────────── │ (tier: fast/bal/deep)   │   │
│   └───────┬───────┘     {tier, strategy} └─────────────────────────┘   │
│           │                                                            │
│   1. Deterministic Pre-Flight (Local Bash test/build: zero tokens)     │
│   2. Prompt Composition via platform/prompts/compose.sh                │
│   3. Headless Execution via CLI Gateway (platform/agents/exec.sh)      │
│   4. Bounded Loop Counter Enforcement (maxAttempts <= 3)               │
│   5. Durable Gate & Narrative Checkpoint State Mutation                │
└────────────────────────────────────────────────────────────────────────┘
```

## Stage Routing Matrix

The router assigns each lifecycle stage to its optimal cost/capability tier:

| Stage | Default Tier | Strategy | Engines / Model Tier Mapping |
|---|---|---|---|
| `issue-refinement` | `balanced` | `single-turn` | Claude 3.5 Sonnet / Gemini 3.8 Flash |
| `solution-designer`| `deep` | `reasoning-turn` | Claude 3.7 Thinking / Gemini 2.5 Pro / o3-mini |
| `implementation`   | `balanced` | `worktree-edit` | Claude 3.5 Sonnet / Gemini 3.8 Flash |
| `testing`          | `fast` | `deterministic-first` | Deterministic Bash first $\rightarrow$ Haiku / Flash-Lite |
| `code-reviewer`    | `deep` | `reasoning-turn` | Claude 3.7 Thinking / Gemini 2.5 Pro |
| `pr-creator`       | `fast` | `deterministic-git` | Local Git / Identity $\rightarrow$ Haiku / Flash-Lite |
| `pr-maintainer`    | `fast` | `verification` | Local Git / gh / glab / jira |

## CLI Commands

```bash
# Run orchestrator loop on a work item
aee orchestrate <workspace-id> <work-item-id> [options]

# Shortcut when inside a worktree (auto-detects workspace & work-item)
aee loop [options]

# Options:
#   -n, --max-turns <N>   Maximum loop turns before stopping (default: 10)
#   -e, --engine <name>   Engine override (claude, agy, gemini, codex)
#   -t, --tier <tier>     Tier override (fast, balanced, deep)
#   --auto-pr             Automatically create pull request when review passes
#   --dry-run             Inspect stage routing without running worker agents
```
