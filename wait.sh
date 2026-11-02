#!/usr/bin/env bash
# Waits for the turn of this run among the active runs of the same workflow.
#
# The turn is held by the run that created the newest lock ref
# refs/priority-boarding/<workflow>/<n>. It is released when that run completes.
# The next run takes the turn by creating ref <n+1>. Creating a ref fails if it
# already exists, so only one run can take the turn.
#
# Waiting runs are ordered by the summed weight of their pull request labels
# (highest first), then by start time. Runs without a pull request, for example
# of a push to main, have the weight no-pull-request-weight. A run of a pull request that has a newer
# run is left out, and fails if the newer run is of another commit. Only the
# first waiting run takes the turn. It checks often, the others check less often
# to save API requests, except while the turn is free: the first run may never
# take it.
#
# When the holder succeeded and its pull request has auto-merge enabled, the
# pull request is merged a few seconds after the run completes. A run taking the
# turn in between would test a branch that is outdated right after. The turn
# stays held until the pull request is merged or can't be merged, for example
# because a required check failed, or a new commit was pushed to it: auto-merge
# waits for the run of the new commit, which waits for the turn.
#
# After a merge, the branches of the other pull requests are behind and their
# runs fail as outdated. A pull request updated right away, for example a
# release pull request, would then be the only waiting run and take the turn,
# although the pull requests updated a few minutes later have a higher weight.
# So before taking the turn, a run lets open pull requests with auto-merge
# enabled and a higher weight go first while they are about to be tested: their
# head commit has no run yet. A pull request whose head commit was tested and is
# behind gets no new run until its branch is updated. With
# update-pending-branches, the run rebases it and lets the new commit go first.
#
# The status filter of the list-runs API (?status=in_progress) is backed by a
# search index that can be stale and return no runs although runs are active.
# The unfiltered list is correct, so active runs are filtered client-side.
#
# A run of a pull request from a fork gets a read-only token and can't create
# lock refs. It waits like any other run, but when it is first in line and the
# turn is free, it waits for another run to take the turn on its behalf: the
# turn belongs to the run named in the lock commit, whoever created it. That
# other run is started by a workflow_run event, which has a writable token, and
# is given the id of the fork run with run-id. It waits as if it were that run,
# from the same queue, and ends once the turn is taken or the fork run ended.
# The run ids of the runs list don't name the pull request of a fork run, so
# runs are matched to pull requests by head repository and branch. A read-only
# run never writes, not even with update-token.
set -euo pipefail

repo="repos/$GITHUB_REPOSITORY"

# The run that waits for the turn: this run, or the run given with run-id.
self="$GITHUB_RUN_ID"
run_id="${INPUT_RUN_ID:-}"
this="This run"
if [ -n "$run_id" ]; then
  if ! [[ "$run_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::Invalid run-id: $run_id. Expected a workflow run id."
    exit 1
  fi
  self=$run_id
  this="Run $run_id"
  # The path goes last: read gives the last variable the rest of the line, so
  # a workflow file name with spaces stays whole.
  target_query='"\(.head_sha) \(.head_repository.full_name // ""):\(.head_branch // "") \(.event) \(.pull_requests[0].number // "-") \(.path)"'
  if ! target=$(gh api "$repo/actions/runs/$run_id" --jq "$target_query"); then
    echo "::error::Reading run $run_id failed."
    exit 1
  fi
  read -r HEAD_SHA target_head target_event target_pr target_path <<<"$target"
  HEAD_REPO=${target_head%:*}
  if [ -z "${INPUT_WORKFLOW:-}" ]; then
    INPUT_WORKFLOW=${target_path##*/}
  fi
  # The pull request the run tests: the one the run names, otherwise for a
  # pull_request or pull_request_target run the one of its head repository and
  # branch, which stay the same when the pull request gets new commits. The run
  # of a fork doesn't name it. Empty for a run without a pull request, or when
  # the branch has several.
  [ "$target_pr" != "-" ] || target_pr=""
  if [ -n "$target_pr" ] || ! [[ "$target_event" =~ ^pull_request(_target)?$ ]] || [ -z "$HEAD_REPO" ]; then target_head=""; fi
  if ! target_prs=$(gh api --paginate "$repo/pulls?state=open&per_page=100" --jq '.[] | "\(.head.repo.full_name // ""):\(.head.ref) \(.number) \(.base.ref) \(.head.sha)"'); then
    echo "::error::Listing pull requests failed."
    exit 1
  fi
  # shellcheck disable=SC2016 # awk variables
  target_match='($2 == pr || $1 == head) { n++; found = $2 " " $3 " " $4 } END { if (n == 1) print found }'
  read -r PR_NUMBER BASE_REF pr_head_sha <<<"$(awk -v pr="$target_pr" -v head="$target_head" "$target_match" <<<"$target_prs")"
  if [ -n "$PR_NUMBER" ] && [ "$pr_head_sha" != "$HEAD_SHA" ]; then
    echo "Run $run_id tests an outdated commit of pull request #$PR_NUMBER, nothing to do."
    exit 0
  fi
  echo "Waiting for the turn on behalf of run $run_id${PR_NUMBER:+ of pull request #$PR_NUMBER}."
fi

workflow="${INPUT_WORKFLOW:-}"
if [ -z "$workflow" ]; then
  # GITHUB_WORKFLOW_REF: owner/repo/.github/workflows/file.yml@refs/...
  workflow_path="${GITHUB_WORKFLOW_REF%%@*}"
  workflow="${workflow_path##*/}"
fi
interval="${INPUT_POLL_INTERVAL:-30}"
queued_interval="${INPUT_QUEUED_POLL_INTERVAL:-300}"
timeout_minutes="${INPUT_TIMEOUT_MINUTES:-0}"
require_up_to_date="${INPUT_REQUIRE_UP_TO_DATE:-false}"
merge_wait="${INPUT_MERGE_WAIT:-10}"
yield_minutes="${INPUT_YIELD_MINUTES:-10}"
update_pending="${INPUT_UPDATE_PENDING:-false}"
if [ "$update_pending" = "true" ] && [ -z "${UPDATE_TOKEN:-}" ]; then
  echo "::warning::update-pending-branches needs update-token, not updating pending pull requests."
  update_pending=false
fi
no_pr_weight="${INPUT_NO_PR_WEIGHT:-0}"
if ! [[ "$no_pr_weight" =~ ^-?(0|[1-9][0-9]*)$ ]]; then
  echo "::error::Invalid no-pull-request-weight: $no_pr_weight. Expected an integer."
  exit 1
fi
lock_prefix="priority-boarding/$workflow"

# read-only: wait for another run to take the turn on behalf of this run, see
# above. "auto" for pull_request runs of forks, whose token is read-only.
read_only="${INPUT_READ_ONLY:-auto}"
if ! [[ "$read_only" =~ ^(auto|true|false)$ ]]; then
  echo "::error::Invalid read-only: $read_only. Expected auto, true or false."
  exit 1
fi
if [ "$read_only" = "auto" ]; then
  read_only=false
  if [ -z "$run_id" ] && [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ -n "${HEAD_REPO:-}" ] && [ "$HEAD_REPO" != "$GITHUB_REPOSITORY" ]; then
    read_only=true
  fi
fi
if [ "$read_only" = "true" ] && [ -n "$run_id" ]; then
  echo "::error::read-only and run-id can't be combined: a run with run-id takes the turn for another run."
  exit 1
fi
# A read-only run writes nothing, not even with update-token.
if [ "$read_only" = "true" ]; then
  UPDATE_TOKEN=""
  update_pending=false
fi
# Minutes a read-only run that is first in line waits for another run to take
# the turn on its behalf, before it fails.
handoff_minutes=5
handoff_deadline=0

if [ "$require_up_to_date" = "true" ] && { [ -z "${BASE_REF:-}" ] || [ -z "${HEAD_SHA:-}" ]; }; then
  echo "::notice::require-up-to-date only applies to pull_request events, skipping the check."
  require_up_to_date=false
fi

# label-weights: one "label=weight" per line, e.g. "renovate=-5".
weights=$(printf '%s\n' "${INPUT_LABEL_WEIGHTS:-}" | jq -R -s '
  split("\n") | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0))
  | map(capture("^(?<label>.+?)\\s*=\\s*(?<weight>[+-]?[0-9]+)$")
        // error("Invalid label-weights line: \(.). Expected label=weight."))
  | map({(.label): (.weight | tonumber)}) | add // {}')

# Commit status that shows the place in the queue, visible live in the pull
# request's checks. The log of a composite action is not shown live. Set on the
# pull request's head commit, not the merge commit.
# A read-only run can't set it, the run taking the turn for it does.
status_context="${INPUT_STATUS_CONTEXT:-}"
if [ "$read_only" = "true" ]; then
  status_context=""
  echo "The token is read-only: this run waits for the turn, and another run takes it on its behalf when it is first in line."
fi
status_sha="${HEAD_SHA:-$GITHUB_SHA}"
status_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$self"
last_status=""
status_final=false
fail_state=failure
fail_description="Waiting for the turn failed, see the log."
# Sets the commit status if it changed. Descriptions are limited to 140
# characters. A failing request stops further updates but not the waiting.
set_status() {
  local state=$1 description=${2:0:140} out fields
  [ -n "$status_context" ] || return 0
  [ "$state $description" != "$last_status" ] || return 0
  fields=(-f state="$state" -f context="$status_context" -f description="$description" -f target_url="$status_url")
  if ! out=$(gh api "$repo/statuses/$status_sha" "${fields[@]}" --silent 2>&1); then
    echo "::warning::Setting commit status $status_context failed, no longer updating it. The token needs statuses: write permission. $out"
    status_context=""
    return 0
  fi
  last_status="$state $description"
}
on_exit() {
  local code=$?
  if [ "$code" -ne 0 ] && [ "$status_final" != "true" ]; then
    set_status "$fail_state" "$fail_description"
  fi
}
trap on_exit EXIT
trap 'fail_state=error; fail_description="Cancelled while waiting for the turn."; exit 130' INT TERM

# Sleeps in the background and waits for it. Bash runs the INT/TERM trap only
# after a foreground command returns, and the runner kills the step a few
# seconds after cancelling it, long before a poll interval ends.
pause() {
  sleep "$1" &
  wait "$!"
}

# Fails the run if the branch is behind the base branch. Testing an outdated
# branch is wasted time: it has to be updated and tested again anyway.
# With "strict", a failing API request fails the run as well.
check_up_to_date() {
  [ "$require_up_to_date" = "true" ] || return 0
  local behind
  if ! behind=$(gh api "$repo/compare/$BASE_REF...$HEAD_SHA" --jq .behind_by); then
    if [ "${1:-}" = "strict" ]; then
      echo "::error::Comparing with $BASE_REF failed."
      exit 1
    fi
    echo "Comparing with $BASE_REF failed, retrying later."
    return 0
  fi
  if [ "$behind" -gt 0 ]; then
    update_branch "$behind"
    fail_description="Branch is $behind commit(s) behind $BASE_REF."
    echo "::error::Branch is $behind commit(s) behind $BASE_REF. Update the branch to run the tests."
    exit 1
  fi
}

# Rebases the pull request branch onto the base branch with update-token, then
# fails the run: its commit is outdated, the new commit starts a new run.
# Returns without doing anything when no update-token is set or the branch is
# in a fork.
update_branch() {
  local behind=$1 output
  [ -n "${UPDATE_TOKEN:-}" ] || return 0
  if [ "${HEAD_REPO:-}" != "$GITHUB_REPOSITORY" ]; then
    echo "::notice::The branch is in another repository and can't be updated."
    return 0
  fi
  if ! output=$(GH_TOKEN="$UPDATE_TOKEN" gh pr update-branch "$PR_NUMBER" --rebase -R "$GITHUB_REPOSITORY" 2>&1); then
    echo "::error::Branch is $behind commit(s) behind $BASE_REF and rebasing it failed: $output"
    exit 1
  fi
  fail_description="Branch was behind $BASE_REF and was rebased. The new commit starts a new run."
  echo "::notice::Branch was $behind commit(s) behind $BASE_REF and was rebased. The new commit starts a new run."
  exit 1
}

# Prints "<n> <commit sha>" of all lock refs, sorted by n.
list_locks() {
  gh api --paginate "$repo/git/matching-refs/$lock_prefix/" \
    --jq ".[] | (.ref | ltrimstr(\"refs/$lock_prefix/\")) as \$n
      | select(\$n | test(\"^[0-9]+$\")) | \"\(\$n) \(.object.sha)\"" | sort -n
}

# Run ids and pull request numbers of lock commits, by commit sha. Lock commits
# never change. Sets holder to the run id and holder_pr to the pull request
# number of the lock commit. Lock commits of runs without a pull request, and
# of older versions, have no pull request number.
declare -A lock_runs=() lock_prs=()
read_holder() {
  local sha=$1 message
  if [ -z "${lock_runs[$sha]:-}" ]; then
    message=$(gh api "$repo/git/commits/$sha" --jq .message)
    lock_runs[$sha]=$(jq -rn --arg m "$message" '$m | capture("run (?<id>[0-9]+)").id')
    lock_prs[$sha]=$(jq -rn --arg m "$message" '$m | capture("pull request (?<pr>[0-9]+)").pr // ""')
  fi
  holder=${lock_runs[$sha]}
  holder_pr=${lock_prs[$sha]}
}

# Conclusions and head commits of holder runs known to have completed, by run
# id.
declare -A completed_runs=() completed_shas=()
is_active() {
  local id=$1
  [ -z "${completed_runs[$id]:-}" ] || return 1
  if echo "$active" | jq -e --argjson id "$id" 'any(.[]; .id == $id)' >/dev/null; then
    return 0
  fi
  # Not in the list of recent active runs. Ask for the run itself before
  # releasing its turn.
  # Only a missing run counts as completed, other errors keep the turn held.
  local run status conclusion head_sha
  if ! run=$(gh api "$repo/actions/runs/$id" --jq '"\(.status) \(.conclusion) \(.head_sha)"' 2>&1); then
    [[ "$run" == *"HTTP 404"* ]] || return 0
    run="completed missing"
  fi
  read -r status conclusion head_sha <<<"$run"
  if [ "$status" != "completed" ]; then
    return 0
  fi
  completed_runs[$id]=$conclusion
  completed_shas[$id]=${head_sha:-}
  return 1
}

# Required checks of the head commit of a pull request that failed, from the
# GraphQL API: the REST API doesn't tell which checks are required.
# shellcheck disable=SC2016 # GraphQL variables, not shell
failed_checks_query='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
        ... on CheckRun { name conclusion isRequired(pullRequestNumber: $number) }
        ... on StatusContext { context state isRequired(pullRequestNumber: $number) }
      } } } } } }
    }
  }
}'
failed_checks_jq='[.data.repository.pullRequest.commits.nodes[].commit.statusCheckRollup.contexts.nodes[]?
  | select(.isRequired and ((.conclusion // .state) | IN("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE")))
  | .name // .context] | join(", ")'
failed_checks_args=(-f query="$failed_checks_query" -f owner="${GITHUB_REPOSITORY%/*}" -f name="${GITHUB_REPOSITORY#*/}" --jq "$failed_checks_jq")
checks_warned=false

# Returns 0 while the pull request of a completed holder run is about to be
# merged: the run succeeded, it tested the current head commit, and the pull
# request is open with auto-merge enabled. A pull request that is blocked by a
# failed required check is not merged. Gives up after merge_wait minutes, for
# example when the checks can't be read or a review is missing.
declare -A merge_deadlines=()
merge_pending() {
  local id=$1 pr=$2 pull head_sha failed
  [ -n "$pr" ] && [ "$merge_wait" -gt 0 ] || return 1
  [ "${completed_runs[$id]:-}" = "success" ] || return 1
  if [ -z "${merge_deadlines[$id]:-}" ]; then
    merge_deadlines[$id]=$((SECONDS + merge_wait * 60))
  fi
  if [ "$SECONDS" -ge "${merge_deadlines[$id]}" ]; then
    return 1
  fi
  if ! pull=$(gh api "$repo/pulls/$pr" --jq '"\(.state) \(.auto_merge != null) \(.mergeable_state) \(.head.sha)"'); then
    echo "Reading pull request #$pr failed, retrying."
    return 0
  fi
  head_sha=${pull##* }
  pull=${pull% *}
  # A new commit was pushed after the holder run started. Auto-merge waits for
  # the run of the new commit, which may be waiting for this turn.
  if [ -n "${completed_shas[$id]:-}" ] && [ "$head_sha" != "${completed_shas[$id]}" ]; then
    return 1
  fi
  case $pull in
    # A branch that is behind or has conflicts is not merged until it is
    # updated, which starts a new run.
    "open true behind" | "open true dirty") return 1 ;;
    "open true blocked")
      if ! failed=$(gh api graphql "${failed_checks_args[@]}" -F number="$pr"); then
        if [ "$checks_warned" = "false" ]; then
          echo "::warning::Reading the checks of #$pr failed, waiting for its merge up to merge-wait-minutes."
          checks_warned=true
        fi
        return 0
      fi
      if [ -n "$failed" ]; then
        echo "Required checks of #$pr failed, it won't be merged: $failed."
        return 1
      fi
      return 0
      ;;
    "open true "*) return 0 ;;
  esac
  return 1
}

# States of pull request head commits. "tested" when the commit has a run of
# this workflow, so no new run is about to start for it. "updated" when this run
# rebased the branch, the new commit starts a new run. With
# update-pending-branches, tested commits are checked again after
# queued_interval, as the base branch may have moved on.
declare -A head_states=() head_checked=()
# Sets the state of head commit $2 of pull request $1, with base branch $3 and
# head repository $4. Without a state the commit has no run yet, or a request
# failed: unknown counts as pending, the wait is limited anyway.
check_head() {
  local number=$1 sha=$2 base=$3 head_repo=$4 count behind output
  unset "head_states[$sha]"
  count=$(gh api "$repo/actions/workflows/$workflow/runs?head_sha=$sha&per_page=1" --jq .total_count </dev/null) || return 0
  [ "$count" -gt 0 ] || return 0
  head_states[$sha]=tested
  head_checked[$sha]=$SECONDS
  [ "$update_pending" = "true" ] && [ "$head_repo" = "$GITHUB_REPOSITORY" ] || return 0
  behind=$(gh api "$repo/compare/$base...$sha" --jq .behind_by </dev/null) || return 0
  [ "$behind" -gt 0 ] || return 0
  if ! output=$(GH_TOKEN="$UPDATE_TOKEN" gh pr update-branch "$number" --rebase -R "$GITHUB_REPOSITORY" </dev/null 2>&1); then
    echo "::warning::Pull request #$number is $behind commit(s) behind $base and rebasing it failed: $output"
    return 0
  fi
  echo "Pull request #$number was $behind commit(s) behind $base and was rebased, letting its new commit go first."
  head_states[$sha]=updated
}
# Returns 0 when head commit $1 has no state yet, or is tested and due to be
# checked again.
head_unchecked() {
  [ -n "${head_states[$1]:-}" ] || return 0
  [ "${head_states[$1]}" = "tested" ] && [ "$update_pending" = "true" ] && [ "$SECONDS" -ge "$((head_checked[$1] + queued_interval))" ]
}
# Sets pending to the open pull requests with auto-merge enabled and a weight
# higher than $1 that have no active run but are about to be tested: their head
# commit has no run of this workflow yet, or this run rebased their branch.
# Pull requests whose head commit was tested, successfully or not, are not
# pending: nothing starts a new run for them.
# shellcheck disable=SC2016 # jq variables
pending_query='
  .[] | select(.auto_merge and (.number | tostring) != $self)
  | select(.number as $n | all($runs[]; .pr != $n))
  | select(([.labels[] | $w[.] // 0] | add // 0) > $weight)
  | "\(.number) \(.sha) \(.base) \(.head_repo)"'
pending_args=(--argjson w "$weights" --arg self "${PR_NUMBER:-}")
find_pending() {
  local weight=$1 number sha base head_repo
  pending=""
  while read -r number sha base head_repo; do
    if head_unchecked "$sha"; then
      check_head "$number" "$sha" "$base" "$head_repo"
    fi
    if [ "${head_states[$sha]:-}" != "tested" ]; then
      pending="$pending #$number"
    fi
  done < <(echo "$prs" | jq -r "${pending_args[@]}" --argjson weight "$weight" --argjson runs "$active" "$pending_query")
  pending=${pending# }
}

# Returns 0 while this run lets pending pull requests with a higher weight go
# first. Gives up yield_minutes after it started, for example when a branch is
# never updated.
yield_deadline=0
yielding() {
  [ "$yield_minutes" -gt 0 ] || return 1
  if [ "$yield_deadline" -gt 0 ] && [ "$SECONDS" -ge "$yield_deadline" ]; then
    return 1
  fi
  find_pending "$1"
  [ -n "$pending" ] || return 1
  if [ "$yield_deadline" -eq 0 ]; then
    yield_deadline=$((SECONDS + yield_minutes * 60))
  fi
  return 0
}

tree=""
# Tries to take the turn by creating lock ref n. Returns 1 if another run was
# faster.
take_turn() {
  local n=$1 commit out
  if [ -z "$tree" ]; then
    tree=$(gh api "$repo/git/commits/$GITHUB_SHA" --jq .tree.sha) || return 1
  fi
  local message="priority-boarding: run $self"
  if [ -n "${PR_NUMBER:-}" ]; then
    message="$message, pull request $PR_NUMBER"
  fi
  # Without contents: write, retrying would only block the queue until the
  # timeout. Other errors may be temporary, also rate limits, which can be
  # HTTP 403 as well.
  if ! commit=$(gh api "$repo/git/commits" -f message="$message" -f tree="$tree" --jq .sha 2>&1); then
    if [[ "$commit" == *"Resource not accessible by integration"* ]]; then
      echo "::error::Creating the lock commit failed: $commit"
      echo "::error::The token needs contents: write permission."
      exit 1
    fi
    echo "Creating the lock commit failed: $commit"
    return 1
  fi
  if ! out=$(gh api "$repo/git/refs" -f ref="refs/$lock_prefix/$n" -f sha="$commit" --silent 2>&1); then
    if [[ "$out" == *"HTTP 422"* ]]; then
      return 1
    fi
    echo "::error::Creating lock ref refs/$lock_prefix/$n failed: $out"
    echo "::error::The token needs contents: write permission."
    exit 1
  fi
  # A run that saw an older lock may have recreated an old, already deleted ref
  # number. The newest ref wins.
  local newest
  newest=$(list_locks | tail -n 1 | cut -d ' ' -f 1)
  if [ "$newest" != "$n" ]; then
    gh api -X DELETE "$repo/git/refs/$lock_prefix/$n" --silent || true
    return 1
  fi
  # Remove released locks.
  local old _
  list_locks | while read -r old _; do
    if [ "$old" -lt "$n" ]; then
      gh api -X DELETE "$repo/git/refs/$lock_prefix/$old" --silent || true
    fi
  done
  return 0
}

runs_url="$repo/actions/workflows/$workflow/runs?per_page=100"
runs_query='[.workflow_runs[] | select(.status != "completed")
  | {id, event, run_started_at, html_url, head_sha, pr: (.pull_requests[0].number // null),
     head: "\(.head_repository.full_name // ""):\(.head_branch // "")"}]'
prs_url="$repo/pulls?state=open&per_page=100"
prs_query='.[] | {number, labels: [.labels[].name], auto_merge: (.auto_merge != null),
  sha: .head.sha, base: .base.ref, head_repo: (.head.repo.full_name // ""),
  head: "\(.head.repo.full_name // ""):\(.head.ref)"}'
# Runs of pull requests from forks have no pull requests in the runs list. Their
# pull_request and pull_request_target runs are matched to the open pull
# request by head repository and branch, so runs
# of older commits still belong to it. A branch with several open pull
# requests, to different base branches, matches none: its runs don't say which.
# shellcheck disable=SC2016 # jq variables
match_query='($prs | map(select(.head_repo != "")) | group_by(.head) | map(select(length == 1) | .[0] | {key: .head, value: .number}) | from_entries) as $by_head
  | map(if .pr == null and (.event == "pull_request" or .event == "pull_request_target") then .pr = $by_head[.head] else . end)'
# A run of a pull request that has a newer run is left out: its commit is
# outdated, and it may still be active although it will never take the turn,
# for example while other jobs finish after it failed as outdated. This run
# stays in the queue: check_newer_run fails it if the newer run is of another
# commit, otherwise the newer run is a duplicate of the same commit.
# shellcheck disable=SC2016 # jq variables
queue_query='
  ($prs | map({key: (.number | tostring), value: ([.labels[] | $w[.] // 0] | add // 0)}) | from_entries) as $pw
  | ($runs | map(select(.pr != null)) | group_by(.pr)
    | map({key: (.[0].pr | tostring), value: (map(.id) | max)}) | from_entries) as $newest
  | $runs | map(select((.id | tostring) != $holder)
    | select(.id == $self or .pr == null or $newest[.pr | tostring] == .id)
    | . + {weight: (if .pr == null then $nopr else ($pw[.pr | tostring] // 0) end)})
  | sort_by(-.weight, .run_started_at, .id)'
queue_args=(--argjson w "$weights" --argjson self "$self" --argjson nopr "$no_pr_weight")
prs='[]'
next_refresh=0
last_state=""

deadline=0
if [ "$timeout_minutes" -gt 0 ]; then
  deadline=$((SECONDS + timeout_minutes * 60))
fi

# Fails the run when its pull request has a newer run of another commit. Its
# commit is outdated, and the other runs leave it out of their queue, so it
# could take the turn and test the outdated commit.
# shellcheck disable=SC2016 # jq variables
newer_query='[.[] | select(.pr == $pr and .id > $self and .head_sha != $sha)]
  | max_by(.id) | .html_url // empty'
check_newer_run() {
  local newer
  if [ -z "${PR_NUMBER:-}" ] || [ -z "${HEAD_SHA:-}" ]; then
    return 0
  fi
  newer=$(echo "$active" | jq -r --argjson pr "$PR_NUMBER" --argjson self "$self" --arg sha "$HEAD_SHA" "$newer_query")
  [ -n "$newer" ] || return 0
  fail_description="Outdated, a newer commit of #$PR_NUMBER is tested."
  echo "::error::A newer commit of pull request #$PR_NUMBER is tested in $newer. This commit is outdated."
  exit 1
}

# Marks the commit status as successful once this run has the turn.
took_turn() {
  local description="Took the turn."
  if [ "$SECONDS" -ge 60 ]; then
    description="Took the turn after $((SECONDS / 60)) min."
  fi
  set_status success "$description"
  status_final=true
}

# Fails a read-only run that is first in line while the turn is free, when no
# run took the turn on its behalf within handoff_minutes. It would hold up all
# runs behind it.
wait_for_handoff() {
  if [ "$handoff_deadline" -eq 0 ]; then
    handoff_deadline=$((SECONDS + handoff_minutes * 60))
    return 0
  fi
  [ "$SECONDS" -ge "$handoff_deadline" ] || return 0
  echo "::error::No run took the turn on behalf of this run within $handoff_minutes minutes. Runs with a read-only token, like pull requests from forks, need the workflow_run workflow described in the README of priority-boarding."
  exit 1
}

set_status pending "Waiting for the turn."

while true; do
  sleep_for=$queued_interval
  if ! active=$(gh api "$runs_url" --jq "$runs_query") || ! locks=$(list_locks); then
    echo "Listing runs or locks failed, retrying."
    sleep_for=$interval
  else
    holder=""
    holder_pr=""
    newest=0
    if [ -n "$locks" ]; then
      read -r newest sha <<<"$(echo "$locks" | tail -n 1)"
      read_holder "$sha"
    fi
    if [ "$holder" = "$self" ]; then
      # A re-run of the holder keeps the turn.
      echo "$this already has the turn."
      took_turn
      break
    fi
    if [ -n "$run_id" ] && ! is_active "$self"; then
      set_status error "Run ended before it took the turn."
      status_final=true
      echo "Run $self ended before it took the turn, nothing left to do."
      exit 0
    fi
    free=true
    held="Turn held by run $holder."
    # Short form of held for the commit status.
    held_by="run $holder"
    if [ -n "$holder_pr" ]; then
      held_by="#$holder_pr"
    fi
    held_status="Turn held by $held_by."
    if [ -n "$holder" ]; then
      if is_active "$holder"; then
        free=false
      elif merge_pending "$holder" "$holder_pr"; then
        free=false
        held="Run $holder completed, waiting for its pull request #$holder_pr to be merged."
        held_status="Waiting for #$holder_pr to be merged."
      fi
    fi

    if [ "$SECONDS" -ge "$next_refresh" ] || [ "$free" = "true" ]; then
      check_up_to_date
      if new_prs=$(gh api --paginate "$prs_url" --jq "$prs_query" | jq -s .); then
        prs=$new_prs
      else
        echo "Listing pull requests failed, using the last known labels."
      fi
      next_refresh=$((SECONDS + queued_interval))
    fi
    active=$(echo "$active" | jq --argjson prs "$prs" "$match_query")
    check_newer_run

    queue=$(jq -n "${queue_args[@]}" --argjson runs "$active" --argjson prs "$prs" --arg holder "$holder" "$queue_query")
    position=$(echo "$queue" | jq --argjson id "$self" 'map(.id) | index($id) // -1')

    if [ "$free" = "true" ] && [ "$position" = "0" ] && yielding "$(echo "$queue" | jq '.[0].weight')"; then
      free=false
      held="Letting pull requests with a higher weight go first, they are about to be tested: $pending."
      held_status="Letting $pending go first."
    fi

    if [ "$free" = "true" ] && [ "$position" = "0" ] && [ "$read_only" = "true" ]; then
      check_up_to_date strict
      wait_for_handoff
      free=false
      held="The turn is free, waiting for another run to take it on behalf of this run."
    else
      handoff_deadline=0
    fi

    if [ "$free" = "true" ] && [ "$position" = "0" ]; then
      check_up_to_date strict
      if take_turn $((newest + 1)); then
        echo "Took the turn."
        took_turn
        break
      fi
      echo "Could not take the turn, another run may have been faster. Retrying."
      pause "$interval"
      continue
    fi

    # The first run checks often. While the turn is free, so do all others: the
    # first run may never take it, for example when it fails as outdated.
    if [ "$position" = "0" ] || [ "$free" = "true" ]; then
      sleep_for=$interval
    fi
    if [ "$position" = "-1" ]; then
      state="$this is not in the list of active runs yet."
      status_description=$state
    else
      state=$(echo "$queue" | jq -r --argjson pos "$position" '
        "Position \($pos + 1) of \(length) (weight \(.[$pos].weight)). Queue: "
        + (map("\(.html_url) (weight \(.weight))") | join(", "))')
      status_description=$(echo "$queue" | jq -r --argjson pos "$position" '
        "Position \($pos + 1) of \(length) (weight \(.[$pos].weight))."')
      if [ "$free" = "true" ]; then
        state="$state. The turn is free, waiting for the first run to take it."
        status_description="$status_description The turn is free."
      else
        state="$state. $held"
        status_description="$status_description $held_status"
      fi
    fi
    set_status pending "$status_description"
    if [ "$state" != "$last_state" ]; then
      echo "$state"
      last_state=$state
    fi
  fi
  if [ "$deadline" -gt 0 ] && [ "$SECONDS" -ge "$deadline" ]; then
    fail_description="Timed out after $timeout_minutes minutes waiting for the turn."
    echo "::error::Timed out after $timeout_minutes minutes waiting for the turn."
    exit 1
  fi
  pause "$sleep_for"
done

if [ "$require_up_to_date" = "true" ]; then
  echo "Branch is up to date with $BASE_REF."
fi
