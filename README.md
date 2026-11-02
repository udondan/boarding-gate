# priority-boarding

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/banner-dark.webp">
  <img alt="priority-boarding: Everyone waits. The gate decides who's next." src=".github/banner-light.webp">
</picture>

[![Release](https://img.shields.io/github/v/release/udondan/priority-boarding)](https://github.com/udondan/priority-boarding/releases/latest)
[![Marketplace](https://img.shields.io/badge/marketplace-priority--boarding-blue?logo=github)](https://github.com/marketplace/actions/priority-boarding)
[![Test](https://github.com/udondan/priority-boarding/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/udondan/priority-boarding/actions/workflows/test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/udondan/priority-boarding/graph/badge.svg)](https://codecov.io/gh/udondan/priority-boarding)
[![License](https://img.shields.io/github/license/udondan/priority-boarding)](LICENSE)

GitHub Action that queues the runs of a workflow so only one run at a time uses shared resources (test stacks, environments), without cancelling pending runs the way a `concurrency` group does. Runs are ordered by the labels of their pull requests, so for example your own pull requests are tested before dependency updates, and release pull requests last. See [Alternatives](#alternatives) for when merge queue fits better.

## How it works

The run that has the turn holds the lock ref `refs/priority-boarding/<workflow>/<n>`. The turn is released when that run completes, including all jobs after the wait, or, if its pull request is about to be auto-merged, after the merge (see [Outdated branches](#outdated-branches)). A failed or cancelled run releases it as well, so cancelling the run holding the turn frees it, also in the middle of a job after the wait. The next run takes the turn by creating ref `<n+1>`. Creating a ref fails if it already exists, so only one run can take the turn. Old lock refs are deleted.

Waiting runs are ordered by weight (highest first), then by start time. A re-run of the run holding the turn keeps it. A re-run of any other run queues by its new start time. A run of a pull request that has a newer run is left out of the queue: its commit is outdated, and it can stay active for a while after it stopped waiting, for example while other jobs finish after it failed as outdated. A waiting run fails as soon as its pull request has a newer run of another commit, so it never tests the outdated commit. To stop it right away instead of at its next check, add a `concurrency` group (see [Workflow setup](#workflow-setup)).

The run that is next in line checks every `poll-interval-seconds`, the other waiting runs every `queued-poll-interval-seconds`. This keeps the API requests low when many runs are waiting. While the turn is free, all waiting runs check every `poll-interval-seconds`, so the next run takes the turn quickly when the first one never does. Labels are read while waiting, so labelling a pull request moves its waiting run in the queue.

Active runs are read from the unfiltered run list. The `status` filter of the GitHub API is backed by a search index that can be stale and miss active runs (see [softprops/turnstyle#165](https://github.com/softprops/turnstyle/issues/165)).

Each waiting run repeats these steps until it has the turn:

```mermaid
flowchart TD
    start([Run starts]) --> poll[List active runs and lock refs]
    poll --> own{Newest lock ref created by this run?}
    own -- "yes (re-run)" --> done([Has the turn, next jobs run])
    own -- no --> newer{"PR has a newer run of another commit?"}
    newer -- yes --> stale([Fail: commit is outdated])
    newer -- no --> active{Holder run still active?}
    active -- yes --> held[Turn held]
    active -- no --> merge{"Holder succeeded and its PR has auto-merge enabled?"}
    merge -- "yes, up to merge-wait-minutes" --> held
    merge -- no --> free[Turn free]
    held --> uptodate{"Branch up to date? (require-up-to-date)"}
    free --> uptodate
    uptodate -- no --> outdated(["Fail: branch is behind (rebased first with update-token)"])
    uptodate -- yes --> queue["Order waiting runs by label weight, then start time, leaving out runs of PRs with a newer run"]
    queue --> first{Turn free and this run first?}
    first -- yes --> take[Create lock ref n+1]
    take -- created --> done
    take -- "already exists" --> poll
    first -- no --> timeout{timeout-minutes reached?}
    timeout -- yes --> timedout([Fail: timed out])
    timeout -- no --> sleep["Sleep poll-interval-seconds if first in line or the turn is free, else queued-poll-interval-seconds"]
    sleep --> poll
```

## Usage

```yaml
jobs:
  priority-boarding:
    runs-on: ubuntu-latest
    timeout-minutes: 180
    permissions:
      actions: read
      contents: write
      pull-requests: read
    concurrency:
      group: ${{ github.workflow }}-wait-${{ github.event.pull_request.number || github.ref }}
      cancel-in-progress: true
    steps:
      - uses: udondan/priority-boarding@v1
        with:
          require-up-to-date: true
          label-weights: |
            autorelease: pending=-10
            renovate=-5

  deploy:
    needs: priority-boarding
    if: ${{ !cancelled() }}
    runs-on: ubuntu-latest
    steps:
      - name: Check turn
        if: needs.priority-boarding.result != 'success'
        run: exit 1
      # ...
```

All runs of the workflow must use this action, otherwise they don't take part in the queue. The `concurrency` group and the `Check turn` step are explained in [Workflow setup](#workflow-setup).

## Reusable workflow

The wait job can also be called as a [reusable workflow](https://docs.github.com/en/actions/sharing-automations/reusing-workflows), so the job settings are kept in one place instead of in every repository:

```yaml
jobs:
  priority-boarding:
    permissions:
      actions: read
      contents: write
      pull-requests: read
      statuses: write
    uses: udondan/priority-boarding/.github/workflows/priority-boarding.yml@v1
    secrets:
      update-token: ${{ secrets.UPDATE_TOKEN }}

  deploy:
    needs: priority-boarding
    # ...
```

It runs the action with a `concurrency` group that cancels outdated waiting runs (see [Workflow setup](#workflow-setup)) and queues on the calling workflow. The action comes from the same commit as the workflow file, so `@v1` follows every release of both. The calling job can still have its own `needs` and `if`, but no `runs-on` or `steps`. Its permissions are the most the called job gets, so grant them there. `statuses: write` is only needed for `status-context`. In the checks of a pull request, the job is shown as `priority-boarding / Priority boarding`.

The inputs are the [inputs](#inputs) of the action, with the secrets `update-token` and `token`. Some defaults differ from the action's, to match the setup this README recommends:

| Name                     | Default of the workflow                                   |
| ------------------------ | --------------------------------------------------------- |
| `label-weights`          | `urgent=10`, `autorelease: pending=-10` and `renovate=-5` |
| `no-pull-request-weight` | `-100`                                                    |
| `timeout-minutes`        | `180`                                                     |
| `require-up-to-date`     | `true`                                                    |
| `status-context`         | `priority-boarding`                                       |

With these weights, label a pull request `urgent` to move its run to the front of the queue, also while it is waiting. Create the label in your repository first. Your own `label-weights` replace the defaults, so add `urgent=10` to them to keep it.

Pass `label-weights: ''` or `status-context: ''` under `with:` to turn them off.

## Inputs

| Name                           | Default                     | Description                                                                 |
| ------------------------------ | --------------------------- | --------------------------------------------------------------------------- |
| `workflow`                     | workflow of the current run | Workflow file name to queue on, e.g. `test.yml`.                            |
| `label-weights`                |                             | Priority by pull request label, one `label=weight` per line (see below).    |
| `no-pull-request-weight`       | `0`                         | Priority of runs without a pull request, e.g. a push to main (see below).   |
| `poll-interval-seconds`        | `30`                        | Seconds between checks of the run that is next in line.                     |
| `queued-poll-interval-seconds` | `300`                       | Seconds between checks of the other waiting runs while the turn is held.    |
| `timeout-minutes`              | `0`                         | Fail after waiting this many minutes. `0` waits indefinitely.               |
| `require-up-to-date`           | `false`                     | Fail if the PR branch is behind its base branch (see below).                |
| `merge-wait-minutes`           | `10`                        | Keep the turn held while the holder's PR is auto-merged (see below).        |
| `yield-to-pending-minutes`     | `10`                        | Let pending auto-merge PRs with a higher weight go first (see below).       |
| `update-pending-branches`      | `false`                     | Rebase pending auto-merge PRs with a higher weight that are behind (below). |
| `update-token`                 |                             | Token to rebase a PR branch that is behind (see below).                     |
| `status-context`               |                             | Context of a commit status showing the place in the queue (see below).      |
| `read-only`                    | `auto`                      | Wait for another run to take the turn for this run, `auto` for forks.       |
| `run-id`                       |                             | Run to take the turn for, see [forks](#pull-requests-from-forks).           |
| `token`                        | `github.token`              | Token with `actions: read`, `contents: write` and `pull-requests: read`.    |

## Workflow setup

**Cancel outdated waiting runs.** A new commit on a branch makes the waiting run of the previous commit outdated. The action fails it at its next check, but until then it takes a runner. A `concurrency` group per pull request with `cancel-in-progress` cancels it right away. Group by pull request number rather than branch name (`github.head_ref`): branches of forks can have the same name. Put the group on the wait job only, not on the workflow or the jobs after it: once a run has the turn, the wait job is done, so jobs that already use the shared resources are never cancelled and can always clean up.

**Fail the jobs after the wait when the wait fails.** When the wait fails, for example as outdated or on timeout, jobs that need it are skipped, and a skipped job counts as passed for required checks. Run them with `if: ${{ !cancelled() }}` and fail them in a first step when the wait didn't succeed, as in the example above. Or require a single job that checks all others:

```yaml
  required:
    needs: [priority-boarding, deploy]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
```

**Let other jobs wait as well.** Jobs that don't use the shared resources, like a build, can run without waiting. But then the runs of all open pull requests run them at once, and many are tested again after a rebase anyway. With few runners, let them wait for the turn as well.

## Priorities

A run's weight is the sum of the weights of its pull request's labels. Runs of pull requests without matching labels have weight 0. Runs without a pull request, for example of a push to main, have the weight `no-pull-request-weight`, 0 by default. Negative weights move runs to the back of the queue, positive weights to the front. With the example above, unlabelled pull requests are tested first, then Renovate updates (configure Renovate with `"labels": ["renovate"]`), and release-please pull requests (labelled `autorelease: pending`) last. A label like `urgent=10` lets you move a single pull request to the front, also while it is waiting. The [reusable workflow](#reusable-workflow) has it by default.

To test main as well, but only after the pull requests, give runs without a pull request the lowest weight:

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

# ...
      - uses: udondan/priority-boarding@v1
        with:
          label-weights: |
            autorelease: pending=-10
            renovate=-5
          no-pull-request-weight: -100
```

The run of main then also lets pending pull requests go first after a merge (see [Outdated branches](#outdated-branches)).

The run holding the turn is never interrupted: a higher weight only affects which waiting run is next.

## Outdated branches

With branch protection requiring branches to be up to date, testing a branch that is behind its base branch is wasted time: it has to be updated and tested again. With `require-up-to-date: true`, the action fails as soon as the branch is behind, while waiting and right before taking the turn. An outdated run stops right away and makes room for the run of the updated branch.

Not every branch gets updated after a merge. release-please, for example, leaves its pull request alone when the merged commit doesn't change the changelog, so its runs would fail forever. With `update-token`, the action rebases a branch that is behind onto the base branch before failing, and the new commit starts a new run. Pushes made with `github.token` don't start workflow runs, so `update-token` has to be a personal access token or a GitHub App token with `contents: write` and `pull-requests: write`. Branches of forks are never updated.

```yaml
      - uses: udondan/priority-boarding@v1
        with:
          require-up-to-date: true
          update-token: ${{ secrets.UPDATE_TOKEN }}
```

A successful run often gets its pull request merged by auto-merge, a few seconds after the run completes. A run taking the turn in between would pass the check and then test a branch that is outdated right after the merge. So when the run holding the turn succeeded and its pull request has auto-merge enabled, the turn stays held until the pull request is merged or closed, auto-merge is disabled, the branch turns out to be behind or conflicting, or a new commit was pushed to it. A new commit is merged only after its own run, which may be waiting for this turn. After the merge, the waiting runs fail as outdated. A pull request blocked by a failed required check is never merged by auto-merge, so the turn is released right away. The wait ends after `merge-wait-minutes`, for example when a review is missing or the checks can't be read. Pull requests you merge by hand can't be predicted: a run can still take the turn right before such a merge.

After a merge, the other pull requests are updated at different times. A release pull request, for example, is updated right away, while Renovate updates its branches a few minutes later. The run of the release pull request would be the only waiting run and take the turn, although it has the lowest weight. So before taking the turn, a run lets open pull requests with auto-merge enabled and a higher weight go first while they are about to be tested: their head commit has no run of the workflow yet. Pull requests whose head commit was already tested, successfully or not, don't hold up the queue, even when their branch is behind: nothing starts a new run for them until the branch is updated. The wait ends after `yield-to-pending-minutes`, for example when a run never starts.

With `update-pending-branches: true` and `update-token`, the waiting run also rebases such a pull request when its tested branch is behind, and lets the new commit go first. This keeps the order by weight after a merge, without waiting for the branch to be updated by someone else. It costs a run per rebase, also for a pull request whose tests fail: it is tested again each time its base branch moves on. Branches of forks are never updated.

```yaml
      - uses: udondan/priority-boarding@v1
        with:
          require-up-to-date: true
          update-pending-branches: true
          update-token: ${{ secrets.UPDATE_TOKEN }}
```

## Queue status

The log shows the queue, but GitHub doesn't show the log of a composite action live, only after the step completed. With `status-context`, the action sets a commit status with that context on the head commit, visible live in the pull request's checks. It links to the run.

- pending while waiting, e.g. `Position 2 of 4 (weight -5). Turn held by #123.`
- success once the run took the turn
- failure when waiting failed, e.g. on timeout or an outdated branch, and error when the run was cancelled

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/statuses-dark.webp">
  <img alt="Examples of the priority-boarding commit status: took the turn, waiting in line behind a running pull request, waiting for a pull request to be merged, letting a pull request with a higher weight go first, the turn is free, branch behind, outdated commit" src=".github/statuses-light.webp" width="862">
</picture>

The token needs `statuses: write`. Without it, the action logs a warning and waits without the status. A run killed before it can clean up leaves the status pending.

```yaml
    permissions:
      actions: read
      contents: write
      pull-requests: read
      statuses: write
    steps:
      - uses: udondan/priority-boarding@v1
        with:
          status-context: priority-boarding
```

## Alternatives

- **`concurrency` groups** run one run at a time, but keep only one pending run. A newer pending run cancels the older one, so pull requests that wait at the same time are not all tested. There is no order by priority.
- **[Merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)** solves outdated branches at the source: it tests each pull request together with the ones ahead of it and merges it itself, so nothing has to be rebased or waited for after a merge. Combined with a `concurrency` group on the `merge_group` workflow, it also tests one pull request at a time. It is only available for repositories owned by organizations and orders pull requests by the time they were added (or moved to the front by hand), not by labels. If you can use it, prefer it over `require-up-to-date`, `merge-wait-minutes` and `yield-to-pending-minutes`.
- **Other queue actions**, like [softprops/turnstyle](https://github.com/softprops/turnstyle) or [ben-z/gh-action-mutex](https://github.com/ben-z/gh-action-mutex), run one run at a time, first come, first served.

This action is for repositories without merge queue, for example ones owned by a user, where runs share resources and some pull requests should go first. It adds the order by labels and the handling of outdated branches and auto-merge.

## Pull requests from forks

Runs of pull requests from forks get a read-only token and can't create the lock ref. They still wait in the queue like any other run, ordered by the labels of their pull request. But when such a run is first in line and the turn is free, another run has to take the turn on its behalf. The turn belongs to the run named in the lock, not to the run that created it.

That other run is started by `workflow_run`, which runs the workflow of the default branch with a writable token, also for runs of forks. Add this workflow next to the one that waits, with the `name` of that workflow under `workflows`:

```yaml
name: Priority boarding for forks

on:
  workflow_run: # zizmor: ignore[dangerous-triggers] no code of the pull request is run
    workflows: [Test]
    types: [in_progress]

permissions: {}

jobs:
  priority-boarding:
    if: github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.head_repository.full_name != github.repository
    permissions:
      actions: read
      contents: write
      pull-requests: read
      statuses: write
    uses: udondan/priority-boarding/.github/workflows/priority-boarding.yml@v1
    with:
      run-id: ${{ format('{0}', github.event.workflow_run.id) }}
```

It starts when the run of the fork starts, waits in that run's place in the queue, takes the turn for it and ends. It also ends when the run of the fork ends first, for example when it is cancelled, or when it tests an outdated commit of its pull request. It never checks out the code of the pull request, so the writable token is not exposed to it. Pass it the same inputs as the waiting job, like `label-weights` and `require-up-to-date`, so both see the same queue. The commit status of the fork's run is set by this run, since the fork's run can't set it.

The run of the fork detects that it is from a fork (`read-only: auto`). It fails when no run took the turn on its behalf within 5 minutes after it was first in line and the turn was free, so a missing `workflow_run` workflow doesn't hold up the queue for long. `in_progress` is also sent for re-runs and when the run of a first-time contributor was approved, unlike `requested`. Branches of forks are never rebased, see [Outdated branches](#outdated-branches).

The list of runs doesn't name the pull request of a fork's run, so it is found by the fork and branch. When one branch of a fork has open pull requests to several base branches, its runs count as runs without a pull request, since they don't say which one they test.

Runs of forks get no secrets on `pull_request`. Only jobs that use the shared resources without secrets can run for them, like a test environment that needs no credentials. Skip the other jobs for forks. A read-only token doesn't make a runner safe for the code of a fork: on a self-hosted runner that is reused, that code can stay on the machine and read the credentials of later jobs, or reach internal services. Run forks only on GitHub-hosted runners or on isolated self-hosted runners that are used for one job and then discarded.

## Pull requests from Dependabot

Runs of Dependabot pull requests need nothing extra. Their token is read-only by default, but the `permissions` of the wait job raise it, as for any other run. Without `contents: write` the action fails right away instead of blocking the queue.

They only get [Dependabot secrets](https://docs.github.com/en/code-security/dependabot/troubleshooting-dependabot/troubleshooting-dependabot-on-github-actions#accessing-secrets), not the secrets of Actions. Store `update-token` and the secrets of the jobs after the wait there as well, or they are empty for these runs. Without `update-token`, a Dependabot pull request that is behind fails with `require-up-to-date` instead of being rebased.

## Testing

The [bats tests](test/) run the action against a fake GitHub API. The [end-to-end tests](test/e2e/README.md) run it for real in a test repository: bursts of parallel pull requests, priorities and relabelling, Renovate pull requests with auto-merge and rebases, yielding to pending pull requests, pushes to main, failed, cancelled, timed out and re-run runs, and the commit statuses. They check that only one run at a time uses the resource, in the right order, and that the turn is released when it should be.
