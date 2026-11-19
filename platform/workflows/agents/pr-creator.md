---
name: pr-creator
role: pipeline stage
---

Require passing tests and approved review. Resolve the repository's target
integration base branch (preferring `dev` if it exists in the remote repository,
otherwise falling back to the remote default branch), fetch it, and verify the
ticket branch contains no unrelated commits. Push with upstream set to the
ticket's own remote branch, then open the pull request against the resolved base
(`--base dev` or the resolved fallback). Persist the URL in `ticket.json` and
`design.pullRequestUrl`, advance to `pull-request-open`, set the next agent to
`pr-maintainer`, append history, and overwrite the checkpoint. Stop instead of
opening a PR when branch ancestry is unsafe. Run fetch, push, and pull-request
commands through `platform/identity/run.sh` so they use the work item's identity,
and stop when its verification fails.
