#!/usr/bin/env bash
# Usage: pr_state.sh <pr-number|pr-url>
# Prints one compact JSON object with the PR's merge state and checks.
set -euo pipefail

pr=${1:?usage: pr_state.sh <pr-number|pr-url>}

if [[ $pr =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} number=${BASH_REMATCH[3]}
else
  number=${pr#\#}
  read -r owner repo < <(gh repo view --json owner,name --jq '"\(.owner.login) \(.name)"')
fi

query='
query($owner: String!, $repo: String!, $number: Int!, $headRef: String!) {
  repository(owner: $owner, name: $repo) {
    nameWithOwner viewerPermission viewerDefaultMergeMethod autoMergeAllowed
    mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
    pullRequest(number: $number) {
      number state isDraft mergeable mergeStateStatus reviewDecision mergedAt
      headRefName headRefOid headRepository { nameWithOwner }
      baseRefName
      baseRef { target { oid } compare(headRef: $headRef) { aheadBy behindBy } }
      autoMergeRequest { mergeMethod }
      mergeCommit { oid }
      commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) {
        totalCount
        nodes {
          __typename
          ... on CheckRun {
            name status conclusion detailsUrl databaseId startedAt
            isRequired(pullRequestNumber: $number)
            checkSuite { app { slug } workflowRun { databaseId } }
          }
          ... on StatusContext {
            context state targetUrl createdAt
            isRequired(pullRequestNumber: $number)
          }
        }
      } } } } }
    }
  }
}'

jq_filter='
.data.repository as $r | $r.pullRequest as $p
| ($p.commits.nodes[0].commit.statusCheckRollup // {contexts: {totalCount: 0, nodes: []}}) as $roll
| [$roll.contexts.nodes[] |
    if .__typename == "CheckRun" then {
      name,
      state: (.conclusion // .status),
      required: .isRequired,
      provider: (if .checkSuite.app.slug == "github-actions" then "actions" else .checkSuite.app.slug end),
      url: .detailsUrl,
      run: .checkSuite.workflowRun.databaseId,
      job: .databaseId,
      started: .startedAt
    } else {
      name: .context,
      state,
      required: .isRequired,
      provider: (if (.targetUrl // "") | test("buildkite\\.com") then "buildkite" else "status" end),
      url: .targetUrl,
      started: .createdAt
    } end
  | .bucket = (
      if .state == "SUCCESS" then "pass"
      elif .state == "NEUTRAL" or .state == "SKIPPED" then "skip"
      elif .state == "FAILURE" or .state == "ERROR" or .state == "TIMED_OUT" or .state == "CANCELLED"
        or .state == "STARTUP_FAILURE" or .state == "ACTION_REQUIRED" or .state == "STALE" then "fail"
      else "pending" end)
  ] | group_by(.name) | map(max_by(.started // "")) | . as $checks
| {
    repo: $r.nameWithOwner,
    number: $p.number,
    state: $p.state,
    isDraft: $p.isDraft,
    mergeable: $p.mergeable,
    mergeStateStatus: $p.mergeStateStatus,
    reviewDecision: $p.reviewDecision,
    viewerPermission: $r.viewerPermission,
    head: {repo: $p.headRepository.nameWithOwner, ref: $p.headRefName, sha: $p.headRefOid},
    base: {ref: $p.baseRefName, sha: $p.baseRef.target.oid,
           behindBy: $p.baseRef.compare.behindBy, aheadBy: $p.baseRef.compare.aheadBy},
    autoMerge: {allowed: $r.autoMergeAllowed, enabled: ($p.autoMergeRequest != null),
                method: $p.autoMergeRequest.mergeMethod},
    mergeMethods: {default: $r.viewerDefaultMergeMethod,
                   allowed: ([if $r.mergeCommitAllowed then "MERGE" else empty end,
                              if $r.squashMergeAllowed then "SQUASH" else empty end,
                              if $r.rebaseMergeAllowed then "REBASE" else empty end])},
    mergedAt: $p.mergedAt,
    mergeCommit: $p.mergeCommit.oid,
    checks: {
      rollup: $roll.state,
      total: $roll.contexts.totalCount,
      required: [$checks[] | select(.required) | .name],
      passed: [$checks[] | select(.bucket == "pass" or .bucket == "skip") | .name],
      other: [$checks[] | select(.bucket == "fail" or .bucket == "pending")
              | del(.bucket) | with_entries(select(.value != null))]
    }
  }'

gh api graphql \
  -f owner="$owner" -f repo="$repo" -F number="$number" -f headRef="refs/pull/$number/head" \
  -f query="$query" --jq "$jq_filter"
