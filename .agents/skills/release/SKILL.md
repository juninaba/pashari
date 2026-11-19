---
name: release
description: Release a new version of Pashari on GitHub Releases. Picks the version from what changed since the last release, asks the user once, then bumps the version, tags it and checks the published release. Use when the user asks to release Pashari, or to cut, tag or publish a new version.
---

# Release Pashari

Pushing a tag `v<version>` runs the Release workflow
(`.github/workflows/release.yml`). It builds the app, packs
`Pashari-<version>.dmg` and `Pashari-<version>.zip`, and publishes a GitHub
release with both, for anyone to download. The app is signed ad hoc, so no
Apple Developer Program membership is needed.

## 1. See what changed

```sh
git fetch origin --tags
git rev-parse origin/main                     # the commit you will show
gh release view --json tagName --jq .tagName  # the last release, e.g. v0.2.0
git log --first-parent --format='%h %s%n    %b' <last release>..origin/main
git diff --stat <last release> origin/main -- Pashari project.yml Config Scripts/package-release.sh
```

The log lists the pull requests merged since the last release. The diff
covers what ships: the app's code and resources, its build settings and its
packaging. Read a pull request or its diff where the title leaves the change
unclear. Judge by what changes for people using the app, not by the `feat:`
or `fix:` prefix alone: a `build:` that adds an app icon changes how Pashari
looks.

## 2. Pick the version

While Pashari is below 1.0:

- Something new, or a change in how Pashari looks or works: raise the minor
  version, 0.2.0 → 0.3.0.
- Only fixes and speedups: raise the patch version, 0.2.0 → 0.2.1.
- Nothing that ships changed, for example only the README or CI: tell the
  user that no release is needed, and stop.
- Go to 1.0.0 only when the user asks for it.

The build number, `CURRENT_PROJECT_VERSION`, goes up by one with every
release.

## 3. Ask once

Ask the user to approve the release, with your harness's question tool if it
has one. Show:

- the version, and the changes that led to it
- the build number
- the commit of `origin/main` you looked at
- the release notes GitHub will generate. This command only previews them:

  ```sh
  gh api 'repos/{owner}/{repo}/releases/generate-notes' \
    -f tag_name=v<version> -f target_commitish=main \
    -f previous_tag_name=<last release> --jq .body
  ```

Create or push nothing until the user approves. The approval covers all of
step 4 for the commit you showed. If a check in step 4 finds that
`origin/main` has moved past it, show what came in and ask again.

## 4. Release

1. On a branch `chore/release-<version>` from the commit you showed, set
   `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `Config/Base.xcconfig`. Commit it as `chore: prepare Pashari <version>`
   and open a pull request.
2. If `origin/main` is still the commit you showed, merge the pull request
   with a merge commit, as this repository does
   (`gh pr merge <number> --merge`).
3. Tag the merge commit, not the tip of `main`, which may have moved on
   since, and push the tag. The `test` stops both unless the merge commit's
   first parent is the commit you showed, which it is not if another pull
   request merged just before yours. Then show what came in and ask again.

   ```sh
   git fetch origin
   sha=$(gh pr view <number> --json mergeCommit --jq .mergeCommit.oid)
   test "$(git rev-parse "$sha^1")" = <full SHA of the commit you showed> &&
     git tag v<version> "$sha" &&
     git push origin v<version>
   ```

## 5. Check and report

Wait for the Release run of the tag to finish, then check that the release
has both files:

```sh
gh run list --workflow release.yml --branch v<version> --json databaseId,status,conclusion
gh release view v<version> --json url,assets --jq '.url, .assets[].name'
```

If the run failed, show the failing step (`gh run view <id> --log-failed`),
and ask the user before you delete or move the tag or a release.

Report the release URL. Say that the app was built and published but nobody
has opened this build yet: the user tries it on a Mac, installing it as the
README's Installing section says.
