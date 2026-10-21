---
name: release
description: Release a Julia package - find or open the version-bump PR, shepherd it to merge, then draft release notes and the registration comment. Use only when the user runs /pr-shepherd:release, explicitly asks for a release, or merge-when-ready was given --then-release.
argument-hint: [patch|minor|major|<version>] [--dry-run]
allowed-tools: Bash(gh pr list *), Bash(gh pr view *), Bash(gh pr diff *), Bash(gh release list *), Bash(gh api repos/*/pulls/*), Bash(gh api repos/*/contents/*), Bash(gh api repos/*/tags*), Bash(gh api repos/*/commits*), Bash(git fetch *), Bash(git tag *), Bash(git log *), Bash(git show *)
---

# release

Arguments: `$ARGUMENTS`

- `patch`, `minor`, `major`, or an explicit version: the release to make. Otherwise use the open bump PR's version, or infer one.
- `--dry-run`: print each decision and the command you would run. Change nothing. Pass it on to merge-when-ready.

Designed to run as `/loop /pr-shepherd:release [version]`. Each run works out where the release stands and does the next step. Never push to the default branch: the bump always goes through a PR.

Work out the repo's conventions from its history. Don't assume them.

## Where the release stands

1. `git fetch origin --tags`. Read `name` and `version` from `Project.toml` on the default branch (`git show origin/<default>:Project.toml`). Call that version `main`.
2. Find the latest registered version in the General registry: `gh api repos/JuliaRegistries/General/contents/<N>/<name>/Versions.toml -H "Accept: application/vnd.github.raw"`, where `<N>` is the first letter of `name`, in uppercase. Call it `registered`.
3. Pick the phase:
   - `main` has a prerelease suffix such as `0.1.9-DEV`: the repo develops on the next version. Go to **Find or open the bump PR**. The bump PR drops the suffix (`0.1.9-DEV` → `0.1.9`), so for **Find**, match PRs that bump from `main`.
   - `main` > `registered`: the bump is merged. Go to **Register**.
   - `main` == `registered`: the next release needs a bump PR. Go to **Find or open the bump PR**.

## Find or open the bump PR

### Find

An open PR is a bump PR if its `Project.toml` diff changes `version` **from `main`** to a higher version. PRs that bump from an older version are stale; ignore them.

```bash
gh pr list -R <owner>/<repo> --limit 100 --json number,title,files \
  --jq '.[] | select(any(.files[]; .path=="Project.toml")) | "\(.number) \(.title)"'
gh api repos/<owner>/<repo>/pulls/<number>/files --jq '.[] | select(.filename=="Project.toml") | .patch'
```

The bump PR may be a standalone bump ("Bump version from 0.113.5 to 0.113.6", "(0.8.2) Bump revision") or a feature PR that carries the bump, usually with a `(0.x.y)` title prefix.

- One bump PR, and no version argument or the argument matches its version: use it. Go to **Merge**.
- More than one, or a version argument that differs from the bump PR's version: notify the user with the candidates and stop.
- None: go to **Open**.

### Choose the version

Use the argument if given. Otherwise infer the bump from the PRs merged since `registered` (find the date from tag `v<registered>`, or from the General registration PR): labels (`breaking`), titles, breaking markers (`!:`, "BREAKING", a `(0.x.0)` prefix).

Julia semver: for `0.x.y`, a minor bump (`0.x+1.0`) is breaking and a patch bump is anything else. For `>= 1.0`, use normal semver. For `0.0.x`, every bump is breaking.

### Open

Read the last 3–5 merged standalone bump PRs: the PRs behind recent `Project.toml` commits on the default branch (`gh api 'repos/<owner>/<repo>/commits?path=Project.toml&per_page=40'`) that change only `version`. Copy their title format, branch naming, body, labels, and whether they also update `NEWS.md`/`CHANGELOG.md`.

In a worktree of `origin/<default>`: set `version` in `Project.toml`, update the changelog if the repo keeps one, commit, push the branch, and open the PR. Go to **Merge**.

The bump PR is meant to merge as soon as CI passes, so open it ready for review (not a draft) with the repo's title format and no `[WIP]` prefix, and skip the pre-PR code review for a version-only diff. Keep the user's branch prefix (for example `xk/`) in front of the repo's branch name.

## Merge

Invoke the `pr-shepherd:merge-when-ready` skill with `<bump PR> --then-release` (plus `--dry-run` if given). It handles CI, branch updates, reviews and the merge, and it invokes this skill again after the merge, which lands in **Register**.

## Register

1. If an open PR in JuliaRegistries/General is titled `New version: <name> v<main>`, the registration is already pending. Report its link and stop the loop.
2. Find the commit on the default branch that set `version = "<main>"` (`git log -S'version = "<main>"' --format=%H origin/<default> -- Project.toml | tail -1`), usually the bump PR's merge commit.
3. Find how the repo registers:
   - a workflow in `.github/workflows/` that uses `JuliaRegistries/RegisterAction` or is named Register, or
   - a `@JuliaRegistrator register` comment on the commit (the default when there is no such workflow).
4. Write release notes in the style of earlier registrations. Read the last few `New version: <name>` PRs in JuliaRegistries/General: their `Release notes:` section shows the style.
   - Breaking release: `## Breaking changes`, one bullet per change with the old and new usage and the PR number, from the PRs merged since `registered` (including the bump PR, if it carried features).
   - Non-breaking release: no notes, unless the repo writes them for every release.
   - If the repo keeps a changelog or uses TagBot's `changelog` template, follow it.
5. Notify the user with the exact text you would post, and stop the loop:
   - Registrator: a comment on that commit:

     ```
     @JuliaRegistrator register

     Release notes:

     <notes>
     ```
   - Register workflow: `gh workflow run <workflow> --ref <default>` with its inputs.
6. Post the comment (`gh api repos/<owner>/<repo>/commits/<sha>/comments -f body=...`) or trigger the workflow only after the user says yes in the conversation.
