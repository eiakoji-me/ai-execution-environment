#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=platform/repositories/lib.sh
source "$ROOT/platform/repositories/lib.sh"

usage() {
  cat <<'EOF' >&2
usage:
  platform/workspace-scaffolder/resolve.sh <issue-url-or-ref> [--project <project-id>] [--json]

formats supported:
  - Full GitHub URL: https://github.com/owner/repo/issues/123
  - Domain path:     wiki.eiakoji.me/issues/123
  - Shorthand:       wiki-eiakoji-me#123 or wiki-eiakoji-me:123
  - Number & flag:   123 --project wiki-eiakoji-me
EOF
}

validate_projects

issue_input=""
project_arg=""
output_json=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -p|--project)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      project_arg="$2"
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
      usage
      exit 2
      ;;
    *)
      if [[ -z "$issue_input" ]]; then
        issue_input="$1"
      elif [[ -z "$project_arg" ]]; then
        # Handle positional: <project-or-workspace> <issue-number>
        project_arg="$issue_input"
        issue_input="$1"
      fi
      shift
      ;;
  esac
done

[[ -n "$issue_input" ]] || { usage; exit 2; }

# Strip leading protocols and trailing slashes
clean_ref="$(printf '%s' "$issue_input" | sed -E 's|^https?://||; s|/+$||')"

owner_hint=""
repo_hint=""
number=""
project_hint="$project_arg"

# 1. Full GitHub URL or github.com path: github.com/owner/repo/issues/123
if [[ "$clean_ref" =~ ^github\.com/([^/]+)/([^/]+)/issues/([0-9]+)$ ]]; then
  owner_hint="${BASH_REMATCH[1]}"
  repo_hint="${BASH_REMATCH[2]}"
  number="${BASH_REMATCH[3]}"

# 2. Custom domain path: e.g. wiki.eiakoji.me/issues/123
elif [[ "$clean_ref" =~ ^([^/]+)/issues/([0-9]+)$ ]]; then
  domain="${BASH_REMATCH[1]}"
  number="${BASH_REMATCH[2]}"
  if [[ -z "$project_hint" ]]; then
    project_hint="$(printf '%s' "$domain" | tr '.' '-')"
  fi

# 3. Shorthand: e.g. wiki-eiakoji-me#123 or wiki-eiakoji-me:123
elif [[ "$clean_ref" =~ ^([^#/:]+)[#:]([0-9]+)$ ]]; then
  project_hint="${BASH_REMATCH[1]}"
  number="${BASH_REMATCH[2]}"

# 4. Pure issue number: e.g. 123
elif [[ "$clean_ref" =~ ^[0-9]+$ ]]; then
  number="$clean_ref"
  [[ -n "$project_hint" ]] || die "pass --project <id> when providing a bare issue number"

else
  die "unable to parse issue reference: $issue_input"
fi

# Find project in PROJECTS_MANIFEST
matched_project=""

if [[ -n "$owner_hint" && -n "$repo_hint" ]]; then
  matched_project="$(jq -e \
    --arg o "$owner_hint" \
    --arg r "$repo_hint" '
    .projects[] | select(
      ((.repository.owner | ascii_downcase) == ($o | ascii_downcase) and (.repository.name | ascii_downcase) == ($r | ascii_downcase)) or
      ((.issues.owner | ascii_downcase) == ($o | ascii_downcase) and (.issues.repository | ascii_downcase) == ($r | ascii_downcase))
    )' "$PROJECTS_MANIFEST" 2>/dev/null || true)"
fi

if [[ -z "$matched_project" && -n "$project_hint" ]]; then
  # Match by exact id, exact workspace, or repository name/domain
  matched_project="$(jq -e \
    --arg h "$project_hint" '
    [ .projects[] | select(
      .id == $h or
      .workspace == $h or
      .repository.name == $h or
      (.repository.url | endswith("/" + $h)) or
      (.repository.url | endswith("/" + $h + ".git")) or
      (.id | contains($h)) or
      (.id as $id | $h | contains($id))
    ) ][0] // empty' "$PROJECTS_MANIFEST" 2>/dev/null || true)"
fi

[[ -n "$matched_project" ]] || die "no matching project found for issue reference: $issue_input (check config/projects.json)"

project_id="$(jq -r '.id' <<<"$matched_project")"
workspace="$(jq -r '.workspace' <<<"$matched_project")"
provider="$(jq -r '.issues.provider // .repository.provider' <<<"$matched_project")"

if [[ "$output_json" -eq 1 ]]; then
  jq -n \
    --arg projectId "$project_id" \
    --arg workspace "$workspace" \
    --arg provider "$provider" \
    --arg issueRef "$number" \
    '{
      projectId: $projectId,
      workspace: $workspace,
      provider: $provider,
      issueRef: $issueRef
    }'
else
  printf '%s\t%s\t%s\t%s\n' "$project_id" "$workspace" "$provider" "$number"
fi
