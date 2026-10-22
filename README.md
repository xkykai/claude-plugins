# xk-plugins

A Claude Code plugin marketplace with one plugin, `pr-shepherd`.

`pr-shepherd` gets a GitHub PR merged, then prepares a Julia package release:

| Component | Use |
| :- | :- |
| `/pr-shepherd:merge-when-ready` | Runs under `/loop`. Updates the branch when needed, triages failing CI, reruns flaky jobs, and merges when the PR is ready. It notifies you only when you must decide something, and when the PR merges. |
| `pr-shepherd:ci-triage` agent | Decides if a failing check is flaky or caused by the PR. It checks the base branch history for chronic failures and proposes a fix. It is read-only. |
| `/pr-shepherd:release` | Runs under `/loop`. Finds the open version-bump PR, or opens one in the repo's style, shepherds it to merge, then drafts release notes and the Registrator comment or Register workflow. It asks you before it posts anything. |

You need `gh` (authenticated) and bash. On Windows, use Git Bash. Optional: set `BUILDKITE_API_TOKEN` so the skill can rerun only the failed Buildkite jobs and read private Buildkite logs. Without the token, it retriggers a flaky Buildkite check by pushing an empty commit, which reruns all CI (at most 2 per PR).

## Install

```bash
claude plugin marketplace add xkykai/claude-plugins
claude plugin install pr-shepherd@xk-plugins
```

To test a local checkout, use `claude plugin marketplace add ./claude_plugins` instead.

## Usage

```text
/loop /pr-shepherd:merge-when-ready 6270
/loop /pr-shepherd:merge-when-ready https://github.com/CliMA/Oceananigans.jl/pull/6270 --checks all --then-release
/pr-shepherd:merge-when-ready 6270 --dry-run
/loop /pr-shepherd:release
/loop /pr-shepherd:release 0.114.1
/pr-shepherd:release --dry-run
```

Each run of `release` compares `Project.toml` on the default branch with the latest version in the General registry, then does the next step:

1. If the bump isn't merged yet, it picks the version from what is on the default branch: patch unless a PR merged since the last release is breaking. Open feature PRs are ignored, even ones that carry a bump. It reuses an open standalone bump PR to that version, or opens one, copying the title, branch and body style of the repo's recent bump PRs.
2. It runs `merge-when-ready` on the bump PR.
3. After the merge, it drafts release notes (`## Breaking changes` for breaking releases, in the style of earlier registrations) and the `@JuliaRegistrator register` comment. It shows you the text, stops the loop, and posts only after you say yes.

It handles repos that develop on a `-DEV` version: there the bump PR drops the suffix.

merge-when-ready flags:

- `--checks required|all|<name,name>`: the checks that must pass. Default `required`. If the base branch has no required checks, `required` means all checks.
- `--then-release`: runs `release` after the merge, and keeps the loop going for the bump PR.
- `--allow-admin-override`: allows `gh pr merge --admin` past a required check that also fails chronically on the base branch.
- `--dry-run`: prints each decision and the command it would run, and changes nothing.

Use `/loop` without an interval. Claude then sets the wait from how long the pending checks usually take. Neither skill sets `disable-model-invocation`, because `/loop` doesn't run skills that have it. Their descriptions restrict them to explicit requests.

The skill never rebases or force-pushes. It does local git work in a separate worktree. If a failure is caused by the PR, it prepares a fix locally and stops without pushing.

The skill keeps per-PR state (rerun counts, branch-update decisions, typical check run times) in `~/.claude/plugins/data/pr-shepherd-xk-plugins/`.

## Recommended permissions

Add this block to `~/.claude/settings.json`. It lets the loop run without prompts. Admin merges and `gh api` writes still ask first. Force pushes and branch deletes are blocked.

```json
{
  "permissions": {
    "allow": [
      "Bash(gh pr view *)",
      "Bash(gh pr checks *)",
      "Bash(gh pr diff *)",
      "Bash(gh pr list *)",
      "Bash(gh pr merge *)",
      "Bash(gh pr update-branch *)",
      "Bash(gh run view *)",
      "Bash(gh run list *)",
      "Bash(gh run rerun *)",
      "Bash(gh api repos/*/rules/branches/*)",
      "Bash(gh api repos/*/branches/*)",
      "Bash(gh api repos/*/compare/*)",
      "Bash(gh api repos/*/commits*)",
      "Bash(git fetch *)",
      "Bash(git merge *)",
      "Bash(gh pr checkout *)",
      "Bash(git commit --allow-empty *)",
      "Bash(git push *)",
      "Bash(git worktree *)"
    ],
    "ask": [
      "Bash(gh pr merge * --admin*)",
      "Bash(gh api * -X *)",
      "Bash(gh api * --method *)",
      "Bash(gh api * -f *)",
      "Bash(gh api * -F *)",
      "Bash(gh api * --field *)",
      "Bash(gh api * --raw-field *)",
      "Bash(gh api * --input *)"
    ],
    "deny": [
      "Bash(git push --force*)",
      "Bash(git push * --force*)",
      "Bash(git push -f*)",
      "Bash(git push * -f)",
      "Bash(git push * -f *)",
      "Bash(git push * +*)",
      "Bash(git push --delete*)",
      "Bash(git push * --delete*)",
      "Bash(git push * -d *)",
      "Bash(gh repo delete*)"
    ]
  }
}
```

These rules leave some gaps:

- `git push origin +main` force-pushes without a flag. The `* +*` deny rule blocks it.
- `gh api` with `-f`, `-F` or `--input` sends a POST even without `-X`, so those flags are under `ask`. The `release` skill posts the Registrator comment this way, after it asks you.
- `git push origin :branch` deletes a branch. A rule can't match it, because Claude Code reads `:*` at the end of a pattern as a wildcard.
- Bash rules match the command text, not the program. `git -C . push --force` gets past them. For a hard limit, use the [sandbox](https://code.claude.com/docs/en/sandboxing).

The skill's bundled `pr_state.sh` and its read-only `gh` calls are pre-approved through `allowed-tools`, so you don't need rules for them.
