#!/usr/bin/env bash
# A pull request from a fork, labelled urgent, queues behind a holder next to a
# pull request of the repository that was opened before it.
#
# - pipeline.yml (pull_request): the fork's run has a read-only token. It waits,
#   and the run of forks.yml (workflow_run) takes the turn for it and sets its
#   commit status. Its pull request is found by fork and branch, so it gets the
#   weight of its label and goes first.
# - target.yml (pull_request_target, TARGET=true): the fork's run has a
#   writable token and takes the turn itself, also first.
#
# Needs E2E_FORK_TOKEN, see README.md.
# shellcheck disable=SC2016 # jq variables in single quotes
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

fork_setup
scenario_start 15-forks
configure DEPLOY_SECONDS=180 TARGET=true
holder=$(plain_pr holder)
wait_until "#$holder took the turn" 300 is_holder "$holder"
WORKFLOW=target.yml wait_until "#$holder took the turn of target.yml" 300 is_holder "$holder"

configure DEPLOY_SECONDS=20
a=$(plain_pr a)
sleep 3
fork=$(fork_pr fork)
add_label "$fork" urgent

wait_until "#$fork waits first in line" 300 fork_status_matches "$fork" '^pending Position 1 of 2 \(weight 10\)'
STATUS_CONTEXT=priority-boarding-target wait_until "#$fork waits first in line for target.yml" 300 fork_status_matches "$fork" '^pending Position 1 of 2 \(weight 10\)'
wait_settled 1200
scenario_finish

# The runs of the fork as the runs list shows them, to see what the action
# can rely on. Not a check.
log "runs of $FORK:"
jq -r --arg fork "$FORK" '.runs[] | select(.head_repo == $fork) | "  \(.event) \(.path | split("/") | last): pull request \(.pr // "none"), head \(.head_branch) \(.head_sha)"' "$RESULTS/final.json" >&2

expect_turn_order "$holder" "$fork" "$a"
expect_status "$fork" '^pending Position 1 of 2 \(weight 10\)\. Turn held by #[0-9]+\.$'
expect_status "$a" '^pending Position 2 of 2 \(weight 0\)'
expect_jq fork-final-status "the run of #$fork in pipeline.yml ended with status success" --arg pr "$fork" '[.runs[] | select(.workflow == "pipeline.yml" and (.pr | tostring) == $pr) | .statuses | last | .state] == ["success"]'
expect_jq companion "a run of forks.yml took the turn for the fork's run" '[.runs[] | select(.workflow == "forks.yml" and .wait_conclusion == "success")] | length >= 1'
# workflow_run sends in_progress again as the later jobs of the fork's run
# start. Those runs of forks.yml find the turn taken and leave the status alone.
expect_jq fork-status-stays "the status of #$fork stayed success once it took the turn" --arg pr "$fork" '[.runs[] | select(.workflow == "pipeline.yml" and (.pr | tostring) == $pr) | .statuses | map(.state) | last == "success" and (map(select(. == "success")) | length) == 1] == [true]'
expect_jq target-turns "the turns of target.yml went to #$holder, #$fork, #$a" --arg h "$holder" --arg f "$fork" --arg a "$a" '[.turns[] | select(.workflow == "target.yml") | .pr | tostring] == [$h, $f, $a]'
expect_jq target-fork-status "the run of #$fork in target.yml ended with status success" --arg pr "$fork" '[.runs[] | select(.workflow == "target.yml" and (.pr | tostring) == $pr) | .statuses | last | .state] == ["success"]'
scenario_end
