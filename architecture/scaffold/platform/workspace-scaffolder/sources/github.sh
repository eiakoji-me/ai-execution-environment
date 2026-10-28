#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'usage: %s <issue-url-or-number> [--repo <owner/repository>]\n' "$0" >&2
}

issue_ref=''
repository_arg=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo) repository_arg="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      [[ -z "$issue_ref" ]] || { usage; exit 2; }
      issue_ref="$1"
      shift
      ;;
  esac
done

if [[ "$issue_ref" =~ ^https://github\.com/([^/]+)/([^/]+)/issues/([0-9]+)/?$ ]]; then
  owner="${BASH_REMATCH[1]}"
  repository="${BASH_REMATCH[2]}"
  number="${BASH_REMATCH[3]}"
elif [[ "$issue_ref" =~ ^[0-9]+$ ]] && [[ "$repository_arg" =~ ^([^/]+)/([^/]+)$ ]]; then
  owner="${BASH_REMATCH[1]}"
  repository="${BASH_REMATCH[2]}"
  number="$issue_ref"
else
  printf 'error: pass a GitHub issue URL or a number with --repo owner/repository\n' >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || {
  printf 'error: required command not found: gh\n' >&2
  exit 1
}

raw="$(gh issue view "$number" \
  --repo "$owner/$repository" \
  --json issueType,labels,title,body,number,url,state)"
native_type="$(jq -r '.issueType.name // empty | ascii_downcase' <<<"$raw")"
case "$native_type" in
  bug) item_type=FIX ;;
  feature) item_type=FEAT ;;
  task) item_type=TASK ;;
  *) item_type='' ;;
esac

if [[ -z "$item_type" ]]; then
  labels=",$(jq -r '[.labels[].name | ascii_downcase] | join(",")' <<<"$raw"),"
  if [[ "$labels" == *',bug,'* ]]; then
    item_type=FIX
  elif [[ "$labels" == *',feature,'* || "$labels" == *',enhancement,'* ]]; then
    item_type=FEAT
  elif [[ "$labels" == *',task,'* || "$labels" == *',chore,'* ]]; then
    item_type=TASK
  fi
fi

if [[ -z "$item_type" ]]; then
  title_lower="$(jq -r '.title // "" | ascii_downcase' <<<"$raw")"
  if [[ "$title_lower" =~ (fix|bug|patch|resolv|correct|crash|broken) ]]; then
    item_type=FIX
  elif [[ "$title_lower" =~ (feat|add|support|new|implement|replac|redesign|enhanc) ]]; then
    item_type=FEAT
  else
    item_type=TASK
  fi
fi

jq -n \
  --arg source github \
  --arg key "$number" \
  --arg owner "$owner" \
  --arg repository "$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')" \
  --argjson number "$number" \
  --arg type "$item_type" \
  --argjson raw "$raw" \
  '{
    source: $source,
    key: $key,
    owner: $owner,
    repository: $repository,
    number: $number,
    url: $raw.url,
    title: $raw.title,
    body: $raw.body,
    type: (if $type == "" then null else $type end),
    labels: [$raw.labels[].name],
    raw: $raw
  }'
