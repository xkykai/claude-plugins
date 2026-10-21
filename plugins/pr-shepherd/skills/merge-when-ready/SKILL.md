---
name: merge-when-ready
description: Shepherd one GitHub PR to merge, deciding each iteration whether to update the branch, rerun flaky CI, stop for the user, or merge. Use only when the user runs /pr-shepherd:merge-when-ready or explicitly asks to shepherd or merge-when-ready a specific PR, usually under /loop.
argument-hint: <pr-number|pr-url> [--checks required|all|<name,name>] [--then-release] [--allow-admin-override] [--dry-run]
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/pr_state.sh *), Bash(gh pr view *), Bash(gh pr diff *), Bash(gh run view *), Bash(gh run list *), Bash(gh api repos/*/rules/branches/*), Bash(gh api repos/*/compare/*), Bash(git fetch *)
---

# merge-when-ready

Arguments: `$ARGUMENTS`

- First argument: PR number or URL.
- `--checks required|all|<name,name>`: checks that must pass. Default `required`. The set always includes the PR's required checks. If the base branch has no required checks, `required` means all checks.
- `--then-release`: after the merge, invoke the `pr-shepherd:release` skill instead of stopping.
- `--allow-admin-override`: allows `gh pr merge --admin` past a chronic required failure. Off by default.
- `--dry-run`: for each decision, print the decision and the command you would run. Change nothing: no push, rerun, merge, auto-merge, or state-file write.

Designed to run as `/loop /pr-shepherd:merge-when-ready <PR> ...` (self-paced). Without `/loop`, run one iteration and report.

## Rules

- Never rebase, force-push, or push to the base branch.
- Do local git work (merging base, resolving conflicts, preparing fixes) in a separate worktree of the PR branch: `git worktree add <tmp-dir> <pr-head>`. Never change the user's current checkout. If the current directory isn't a clone of the PR's repo, do only API work, and notify the user when local work is needed.
- Log one line per state change, for example `head 1a2b3c: buildkite/oceananigans/pr pending (12/40 min typical)`.
- Use PushNotification only when the user must decide something, and for the final merge. Keep it to one line.
- To stop the loop, call ScheduleWakeup with `stop: true`. Before you stop for a blocker, disable auto-merge if you enabled it (`gh pr merge <PR> --disable-auto`).

## State

Keep one JSON file per PR at `${CLAUDE_PLUGIN_DATA}/merge-when-ready/<owner>__<repo>__<number>.json`. Read it at the start of each iteration and write it when something changes. It holds:

- `behind`: `{head, base, decision: "update"|"merge-as-is", reason}` for the last BEHIND decision
- `reruns`: `{"<head-sha>": {"<check>": count}}`
- `retriggers`: number of empty commits pushed to retrigger CI
- `durations`: `{"<check>": typical minutes}`
- `ignored`: `{"<check>": "failing on <base> since <date/PR>, same signature"}`
- `lastStatus`: the last logged one-line status, so you log only changes

## Each iteration

1. Run `bash ${CLAUDE_SKILL_DIR}/scripts/pr_state.sh <PR>`. It prints one JSON object: `state`, `isDraft`, `mergeable`, `mergeStateStatus`, `reviewDecision`, `viewerPermission`, `head {repo, ref, sha}`, `base {ref, sha, behindBy, aheadBy}`, `autoMerge {allowed, enabled, method}`, `mergeMethods {default, allowed}`, and `checks {rollup, total, required[], passed[], other[]}`. `other` has full detail (`state`, `required`, `provider`, `url`, `run`, `job`, `started`) for every check that is failing or pending.
2. If `state` is `MERGED`, notify the user and stop. If it is `CLOSED`, stop.
3. Go through the decision table below, top to bottom. Act on the first row that matches.

## Decision table

### UNKNOWN

`mergeStateStatus` or `mergeable` is `UNKNOWN`: GitHub is still computing it. Schedule the next wakeup in about 60–90 s.

### Blocked on a person

Draft, `reviewDecision` is `CHANGES_REQUESTED` or `REVIEW_REQUIRED`, or `viewerPermission` is below `WRITE`: notify the user with the reason and stop.

### DIRTY (conflicts)

Merge `origin/<base>` into the PR branch in the worktree.

- If all conflicts are trivial (lockfiles, version lines, whitespace), resolve them, commit the merge, and push.
- For a committed `Manifest.toml`, take base's version and run `julia --project -e 'using Pkg; Pkg.resolve()'`. Don't merge it by hand.
- Otherwise, abort the merge, notify the user with the conflicting files, and stop.

### Behind base

Use `base.behindBy > 0` to decide if the head is behind. `mergeStateStatus` shows `BEHIND` only when the base requires up-to-date branches, and `BLOCKED` or `UNKNOWN` can hide it. If `state.behind` already has a decision for this head and base SHA, use it and go to the next row.

1. Find out if the base requires up-to-date branches:
   - `mergeStateStatus == "BEHIND"` means yes.
   - `gh api repos/{owner}/{repo}/rules/branches/{base} --jq '[.[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy]'`: `true` means yes.
   - `gh api repos/{owner}/{repo}/branches/{base}/protection/required_status_checks --jq .strict` (needs admin; a 404 means unknown).
   - If none of these answers, the rule is unknown.
2. Required: run `gh pr update-branch <PR>`. If that fails, run `git merge origin/<base>` in the worktree and push. Record `decision: "update"`. Wait for CI.
3. Not required, or unknown: assess the risk of merging as-is. Use `gh api repos/{owner}/{repo}/compare/{merge-base}...{base-sha}` for the base commits since the merge-base, and `gh pr diff <PR> --name-only` for the PR's files. Look for:
   - overlap: files or modules changed on both sides, or base changes to code the PR calls, extends or tests
   - shared infrastructure: `Project.toml`, `Manifest.toml`, `[compat]` bounds, CI config, test utilities, `ext/` and package-extension loading
   - API drift: renames or signature changes on base that the PR's new code depends on
   - scale: how many commits and days behind, and whether base's own CI is green now (`gh run list --branch <base> --limit 5`)

   Low risk (parallel changes, disjoint files, no shared infrastructure): record `decision: "merge-as-is"`. If the rule was unknown and GitHub rejects the merge because the branch is out of date, do step 2.
   Medium or high risk: do step 2.

   Record a one-line `reason`. It goes in the final merge notification.

### Failing check in the selected set

Spawn the `pr-shepherd:ci-triage` agent with the repo, PR, head SHA and the failing check (name, provider, URL, run and job ids). Then:

- **Caused by the PR**: do NOT push. Put the proposed fix on a local branch in the worktree. Notify the user with the failing check, the root cause, a summary of the proposed diff, and the options (apply and push, edit, ignore). Stop.
- **Chronic flake** (fails on base with the same signature):
  - Not required: ignore it. Don't rerun it, and don't let it block, even under `--checks all`. Record it in `ignored`.
  - Required: GitHub won't merge past it. Rerun it once, the same way as a one-off flake below (counts toward its limits). If it fails again: with `--allow-admin-override`, merge with `--admin`; otherwise notify the user with the evidence and stop.
- **One-off flake** (not failing on base recently): rerun only the failed jobs, at most 2 times per check per head SHA.
  - Actions: `gh run rerun <run> --failed`.
  - Buildkite with `$BUILDKITE_API_TOKEN` set: `PUT https://api.buildkite.com/v2/organizations/{org}/pipelines/{pipeline}/builds/{number}/jobs/{job}/retry` for each failed job.
  - Otherwise (Buildkite without a token, another external CI, or the rerun call fails): push an empty commit to retrigger all CI, at most 2 per PR, counted in `retriggers`. In the worktree, check out the PR branch (`gh pr checkout <PR>`), then run `git commit --allow-empty -m "Retrigger CI"` and `git push`. If you can't push to the head branch (a fork without maintainer edits), notify the user with the link and stop.
  - At either limit: notify the user and stop.
- If the failure's signature differs from the check's chronic pattern (a different test, a real assertion error), treat it as possibly caused by the PR.

### Checks pending

Schedule the next wakeup from how long the pending checks usually take, not a fixed short interval. Use `state.durations`. If a check has no entry, look at its recent successful runs on base (`gh run list --workflow <workflow> --branch <base> --status success --limit 5 --json createdAt,updatedAt`, or the Buildkite build times) and store the typical value. Wake up at about the expected finish of the earliest pending check, measured from its `started` time, within 60–3600 s.

If auto-merge is allowed and not enabled, and the behind decision covers the current head and base, enable it now with the repo's default method: `gh pr merge <PR> --auto --<method>`. Then keep polling, because GitHub can merge while you wait.

### Mergeable

`mergeStateStatus` is `CLEAN` or `HAS_HOOKS`, or `UNSTABLE` where every failing check is outside the selected set or in `ignored`, and the behind decision covers the current head and base SHAs:

1. Merge with the repo's default method (`mergeMethods.default`, which must be in `mergeMethods.allowed`): `gh pr merge <PR> --<squash|merge|rebase>`.
2. Run pr_state.sh again and confirm `state == "MERGED"`.
3. Notify the user: PR merged, merge commit, behind `reason`, and any ignored checks.
4. Without `--then-release`, stop the loop. With it, invoke the `pr-shepherd:release` skill, which continues the loop or stops it.

If the base moved since the behind decision, decide again before you merge. If the new decision is "update" and auto-merge is enabled, disable it first.

### Anything else

For example, `BLOCKED` with the selected checks green and no review blocker (unresolved conversations, a merge queue, a rule you can't read): notify the user with the state and stop.
