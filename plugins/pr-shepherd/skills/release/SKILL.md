---
name: release
description: Prepare a Julia package release - version bump PR, release notes, and the registration comment or workflow. Use only when the user runs /pr-shepherd:release, explicitly asks for a release, or merge-when-ready was given --then-release.
argument-hint: [patch|minor|major|<version>]
allowed-tools: Bash(gh pr list *), Bash(gh pr view *), Bash(gh release list *), Bash(gh api repos/*/tags*), Bash(git fetch *), Bash(git tag *), Bash(git log *)
---

# release

Arguments: `$ARGUMENTS` (optional `patch`, `minor`, `major`, or an explicit version).

Work out the repo's conventions from its files. Don't assume them.

## Gather

1. `git fetch origin --tags`. Read `Project.toml` on the default branch (`git show origin/<default>:Project.toml`): `name`, `uuid`, `version`.
2. Last release: the highest `v*` tag (`git tag --list 'v*' --sort=-v:refname | head -1`). Compare its version with `Project.toml`.
3. PRs merged since that tag: `gh pr list --state merged --base <default> --search "merged:>=<tag date>" --limit 200 --json number,title,labels,body,mergedAt`.
4. Registration method:
   - a workflow in `.github/workflows/` that uses `JuliaRegistries/RegisterAction` or is named Register, or
   - a `@JuliaRegistrator register` comment on the commit (the default when there is no such workflow).
5. TagBot: `.github/workflows/TagBot.yml` options (`changelog`, `changelog_ignore`, `branches`). Note whether the repo keeps `NEWS.md` or `CHANGELOG.md`, and how earlier entries look.

## Choose the version

Use the argument if given. Otherwise infer the bump from the merged PRs: labels (`breaking`, `enhancement`, `bug`), titles, and breaking markers (`!:`, "BREAKING", a `(0.x.0)` prefix).

Julia semver: for `0.x.y`, a minor bump (`0.x+1.0`) is breaking and a patch bump is anything else. For `>= 1.0`, use normal semver. For `0.0.x`, every bump is breaking.

## Release notes

Write release notes for every release in the style the repo already uses. For a breaking release, include `## Breaking changes` with a migration note per change, written from the PRs. Put them where the repo expects: the `Release notes:` section of the Registrator comment, the changelog file, or both.

## Phase 1: the default branch still has the old version

1. On a new branch from `origin/<default>`, set `version` in `Project.toml`, and update `NEWS.md`/`CHANGELOG.md` if the repo keeps one.
2. Open a version-bump PR. Commit directly to the default branch only if recent history shows that is how the repo releases (bump commits without PRs).
3. Show the user the release notes, and tell them to merge the PR (for example with `/pr-shepherd:merge-when-ready <PR>`), then run this skill again.

## Phase 2: the bump is merged

1. Find the commit on the default branch that set the new version.
2. Show the user exactly what you would post:
   - Registrator: the comment for that commit:

     ```
     @JuliaRegistrator register

     Release notes:

     <notes>
     ```
   - Register workflow: `gh workflow run <workflow> --ref <default>` with its inputs.
3. Ask the user before posting the comment (`gh api repos/{owner}/{repo}/commits/{sha}/comments -f body=...`) or triggering the workflow. Do nothing until they say yes.
