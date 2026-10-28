#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

RESOLVE="$ROOT/platform/workspace-scaffolder/resolve.sh"
AEE="$ROOT/bin/aee"

[[ -x "$RESOLVE" ]] || fail "resolve.sh is not executable"
[[ -x "$AEE" ]] || fail "bin/aee is not executable"

# 1. Test help flag via bin/aee
help_out="$("$AEE" ingest --help)"
grep -Fq 'aee ingest <issue-url-or-ref>' <<<"$help_out" || fail "missing usage in aee ingest --help"
grep -Fq -- '--no-refine' <<<"$help_out" || fail "missing --no-refine in aee ingest --help"
grep -Fq -- '--engine' <<<"$help_out" || fail "missing --engine in aee ingest --help"

# 2. Test missing argument exits with 2
set +e
"$AEE" ingest >/dev/null 2>&1
no_arg_code=$?
set -e
[[ "$no_arg_code" -eq 2 ]] || fail "expected exit 2 on missing args, got $no_arg_code"

# 3. Test Full GitHub URL resolution
res1="$("$RESOLVE" https://github.com/eiakoji-me/wiki-eiakoji-me/issues/42 --json)"
[[ "$(jq -r '.projectId' <<<"$res1")" == "wiki-eiakoji-me" ]] || fail "unexpected projectId in res1: $res1"
[[ "$(jq -r '.workspace' <<<"$res1")" == "eiakoji-me-wiki-eiakoji-me" ]] || fail "unexpected workspace in res1: $res1"
[[ "$(jq -r '.issueRef' <<<"$res1")" == "42" ]] || fail "unexpected issueRef in res1: $res1"
[[ "$(jq -r '.provider' <<<"$res1")" == "github" ]] || fail "unexpected provider in res1: $res1"

# 4. Test Domain Path resolution (e.g. wiki.eiakoji.me/issues/42)
res2="$("$RESOLVE" wiki.eiakoji.me/issues/42 --json)"
[[ "$(jq -r '.projectId' <<<"$res2")" == "wiki-eiakoji-me" ]] || fail "unexpected projectId in res2: $res2"
[[ "$(jq -r '.issueRef' <<<"$res2")" == "42" ]] || fail "unexpected issueRef in res2: $res2"

# 5. Test Shorthand resolution (e.g. wiki-eiakoji-me#42)
res3="$("$RESOLVE" "wiki-eiakoji-me#42" --json)"
[[ "$(jq -r '.projectId' <<<"$res3")" == "wiki-eiakoji-me" ]] || fail "unexpected projectId in res3: $res3"
[[ "$(jq -r '.issueRef' <<<"$res3")" == "42" ]] || fail "unexpected issueRef in res3: $res3"

# 6. Test Bare Number with explicit --project flag
res4="$("$RESOLVE" 42 --project wiki-eiakoji-me --json)"
[[ "$(jq -r '.projectId' <<<"$res4")" == "wiki-eiakoji-me" ]] || fail "unexpected projectId in res4: $res4"
[[ "$(jq -r '.issueRef' <<<"$res4")" == "42" ]] || fail "unexpected issueRef in res4: $res4"

# 7. Test TSV default output
tsv_out="$("$RESOLVE" wiki.eiakoji.me/issues/42)"
[[ "$tsv_out" == "wiki-eiakoji-me"$'\t'"eiakoji-me-wiki-eiakoji-me"$'\t'"github"$'\t'"42" ]] \
  || fail "unexpected TSV output: $tsv_out"

# 8. Test work-items resolve subcommand through CLI
cli_res="$("$AEE" work-items resolve wiki.eiakoji.me/issues/42 --json)"
[[ "$(jq -r '.projectId' <<<"$cli_res")" == "wiki-eiakoji-me" ]] || fail "unexpected projectId from cli resolve: $cli_res"
[[ "$(jq -r '.issueRef' <<<"$cli_res")" == "42" ]] || fail "unexpected issueRef from cli resolve: $cli_res"

# 9. Test unresolvable reference exits with 1
set +e
"$RESOLVE" unknown-project.xyz/issues/999 >/dev/null 2>&1
bad_code=$?
set -e
[[ "$bad_code" -eq 1 ]] || fail "expected exit 1 on unresolvable reference, got $bad_code"

printf 'issue-resolution tests passed\n'
