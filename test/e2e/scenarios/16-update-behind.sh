#!/usr/bin/env bash
# A pull request without auto-merge passed, then another pull request is
# merged and it falls behind. Nothing waits for it, so nothing would update it.
# With update-behind-branches, the push run of main rebases it before it waits,
# and the new commit is tested again.
# shellcheck source=test/e2e/lib.sh
source "$(dirname "$0")/../lib.sh"

# The newest run of the pull request's head commit passed.
run_passed() {
  local id
  id=$(pr_run "$1")
  [ -n "$id" ] && [ "$(gh api "$R/actions/runs/$id" --jq '"\(.status) \(.conclusion)"')" = "completed success" ]
}
head_changed() { [ "$(head_sha "$1")" != "$2" ]; }

scenario_start 16-update-behind
configure DEPLOY_SECONDS=20 TEST_MAIN=true USE_UPDATE_TOKEN=true UPDATE_BEHIND=true
manual=$(plain_pr manual)
wait_until "#$manual passed" 900 run_passed "$manual"
tested=$(head_sha "$manual")

merged=$(plain_pr merged)
auto_merge "$merged"
wait_until "#$merged is merged" 900 is_merged "$merged"
wait_until "#$manual was rebased" 600 head_changed "$manual" "$tested"
wait_until "the rebased #$manual passed" 900 run_passed "$manual"
wait_settled 1200
scenario_finish

expect_turn_pattern "$manual $merged (main $manual|$manual main)"
expect_merged "$merged"
# shellcheck disable=SC2016 # jq variables
expect_jq push-rebase "the push run rebased #$manual" --arg re "^notice Pull request #$manual passed but was 1 commit\\(s\\) behind main and was rebased\\." '[.runs[] | select(.event == "push") | .annotations[] | "\(.level) \(.message)" | test($re)] | any'
expect_final_status "$manual" '^success Took the turn'
scenario_end
