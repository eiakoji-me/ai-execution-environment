# AI execution environment

## Purpose

This repository is an agentic execution platform for issue-driven work across
independent personal projects. It is a workspace control plane, not an
application monorepo.

## Boundaries

- Treat every checkout under `repos/` as an independent Git repository.
- Never add files from `repos/`, `workspaces/`, `worktrees/`, `.local/`, or
  `.env` to this repository.
- Keep code, credentials, and data outside this workspace when they belong to a
  different trust domain than the one selected by the workspace operator.
- Do not clone, fetch, push, publish, deploy, or authenticate unless the user
  requests it or the command is the explicit subject of the task.
- Do not store credentials in tracked files. Keep them in host-local identity
  profiles under `.local/state/identities/`.
- Run Git and provider commands for a project or work item under its identity
  with `platform/identity/run.sh`. Never switch accounts, log in, or fall back to
  host credentials on an identity's behalf.

## Working conventions

- `config/projects.json` maps each project to one canonical checkout, one
  project-specific workspace, and one issue source.
- Canonical repository paths must remain below `repos/`.
- Work items live directly under `workspaces/<workspace-id>/<work-item-id>/`.
- Worktrees are flat, disposable, and direct children of `worktrees/`.
- Each container-pool slot is assigned exclusively to one worktree until its
  work item is closed. Stopping a runtime preserves the slot and container.
- Persistent work-item state must survive worktree and runtime disposal.
- Executable infrastructure belongs under `platform/`.
- `architecture/` is the portable blueprint and must stay synchronized with the
  generic tracked implementation.
- Every workflow stage must use `meta.json`, `session-state.md`, and
  `history.log` as its durable handoff rather than conversation memory.
- Runtime branch creation must resolve an explicit upstream start point and
  must not depend on the canonical checkout's current `HEAD`.
- Run `./architecture/sync-scaffold.sh` after changing portable structure or
  behavior.
- Run `./platform/validate.sh` after platform changes.

## Documentation and diagrams

- Architectural overviews and workflow pipelines must be visualized as rich
  Excalidraw-style wireframe SVGs under `documentation/assets/` rather than raw
  ASCII diagrams or unstyled boxes.
- Wireframe SVGs must adhere to the hand-drawn aesthetic: sketchy borders,
  readable handwriting fonts with sans-serif fallbacks (`Virgil`, `Caveat`,
  `Patrick Hand`, sans-serif), soft pastel fills, explicit flow arrows, and
  bounded subsystem containers.
- Existing high-density technical schematics (such as `aee-architecture.svg`)
  are preserved alongside wireframe overviews as deep-dive blueprints.

## Setup protocol

When asked to set up or onboard this workspace:

1. Read `architecture/setup-guide.md` and run
   `./platform/install/setup.sh plan` before changing the environment.
2. Ask the operator to choose `devcontainer`, `host`, or `guidance` mode when
   the choice is not already explicit. Explain the credential-isolation
   consequence of the choice.
3. Ask which Git provider is primary and which agent interface or orchestrator
   they prefer. Treat these as recommendations, not mandatory dependencies.
4. Run `./platform/install/setup.sh apply` only after the execution mode is
   confirmed. This may create ignored local directories and preferences, but
   it must not authenticate, clone, install global tools, or change Git
   remotes.
5. Guide authentication and repository registration as separate, explicit
   steps. Never assume that the currently active account is the intended one.
6. Tailor optional recommendations to detected tools and saved preferences.
   Keep the portable setup path functional when optional integrations are
   absent.

## Verification

- Shell scripts must pass `bash -n` and ShellCheck.
- JSON files must parse successfully.
- Repository-management commands must not rewrite canonical checkouts.
- Bulk operations must report the repository they are acting on and fail
  visibly rather than hiding errors.

Project-specific instructions belong in each project's own `AGENTS.md`.
Operator-wide rules belong in `~/.codex/AGENTS.md` (or `~/.gemini/` for
Antigravity, `~/.claude/CLAUDE.md` for Claude Code) inside the VM because nested
repositories have their own repository roots.
