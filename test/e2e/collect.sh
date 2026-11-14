#!/usr/bin/env bash
# Collects what is still readable after a scenario: the runs since it started,
# the jobs of all their attempts, the annotations of the wait jobs (the
# ::error:: and ::warning:: lines of the action), the full history of the
# commit statuses of every tested commit, the pull requests and overlap markers.
#
# Usage: collect.sh <results dir>. Writes <results dir>/final.json.
set -euo pipefail

dir=$1
repo="repos/${E2E_REPO:-udondan/boarding-gate-e2e}"
start=$(cat "$dir/start")

# Runs are listed newest first. Unfiltered, as wait.sh does: the created filter
# is backed by the same search index as the status filter.
runs=$(gh api --paginate "$repo/actions/runs?per_page=100" --jq '.workflow_runs[]' | jq -s --arg s "$start" '[.[] | select(.created_at >= $s)]')
runs=$(jq '[.[] | {id, run_attempt, status, conclusion, path, event, head_sha, head_branch, head_repo: .head_repository.full_name,
  pr: (.pull_requests[0].number // null), run_started_at, created_at, updated_at, html_url}]' <<<"$runs")

jobs='{}'
annotations='{}'
for id in $(jq -r '.[].id' <<<"$runs"); do
  run_jobs=$(gh api --paginate "$repo/actions/runs/$id/jobs?filter=all&per_page=100" --jq '.jobs[] | {id, name, run_attempt, status, conclusion, created_at, started_at, completed_at,
    steps: [.steps[] | {name, conclusion, started_at, completed_at}]}' | jq -s .)
  jobs=$(jq --arg id "$id" --argjson j "$run_jobs" '. + {($id): $j}' <<<"$jobs")
  for job in $(jq -r '.[] | select(.name | startswith("boarding-gate")) | .id' <<<"$run_jobs"); do
    a=$(gh api --paginate "$repo/check-runs/$job/annotations" --jq '.[] | {level: .annotation_level, message}' | jq -s .)
    annotations=$(jq --arg id "$job" --argjson a "$a" '. + {($id): $a}' <<<"$annotations")
  done
done

statuses='{}'
for sha in $(jq -r '[.[].head_sha] | unique | .[]' <<<"$runs"); do
  s=$(gh api --paginate "$repo/commits/$sha/statuses?per_page=100" --jq '.[] | select(.context | startswith("boarding-gate")) | {id, context, state, description, target_url, created_at}' | jq -s 'sort_by(.id)')
  statuses=$(jq --arg sha "$sha" --argjson s "$s" '. + {($sha): $s}' <<<"$statuses")
done

prs=$(gh api "$repo/pulls?state=all&sort=updated&direction=desc&per_page=100" | jq --arg s "$start" '[.[] | select(.updated_at >= $s) | {number, title, state, merged_at, closed_at, head_ref: .head.ref, head_repo: .head.repo.full_name, head_sha: .head.sha, labels: [.labels[].name]}]')
overlaps=$(gh api "$repo/git/matching-refs/e2e-resource/overlap-" --jq '[.[].ref]')

# Through files, not --argjson: with many runs the JSON is longer than the
# argument list may be.
parts=$(mktemp -d)
trap 'rm -rf "$parts"' EXIT
printf '%s' "$runs" >"$parts/runs.json"
printf '%s' "$jobs" >"$parts/jobs.json"
printf '%s' "$annotations" >"$parts/annotations.json"
printf '%s' "$statuses" >"$parts/statuses.json"
printf '%s' "$prs" >"$parts/prs.json"
printf '%s' "$overlaps" >"$parts/overlaps.json"
jq -n --slurpfile runs "$parts/runs.json" --slurpfile jobs "$parts/jobs.json" --slurpfile annotations "$parts/annotations.json" \
  --slurpfile statuses "$parts/statuses.json" --slurpfile prs "$parts/prs.json" --slurpfile overlaps "$parts/overlaps.json" \
  '{runs: $runs[0], jobs: $jobs[0], annotations: $annotations[0], statuses: $statuses[0], prs: $prs[0], overlaps: $overlaps[0]}' >"$dir/final.json"
