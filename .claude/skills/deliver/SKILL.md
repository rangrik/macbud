---
name: deliver
description: Ship finished MacBud work end to end - open a PR, merge it, rebuild and install the production app, and publish a GitHub release with notes. Use when the user says "deliver", "ship it", "release this", "cut a release", or asks to get merged work onto their Mac and onto GitHub.
---

# deliver

Take committed work on a branch and turn it into an installed production app plus a published GitHub release.

Run every command from the repo root (or the worktree root). Never skip the checks.

## 1. Pre-flight

```bash
git status --short          # must be clean
make test                   # must end in TEST SUCCEEDED
gh api user --jq .login     # must equal the repo owner
```

- `make test` prints through a filter. For the real count run
  `rtk proxy "xcodebuild -project MacBud.xcodeproj -scheme MacBud -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64' test"` and grep for `Test run with`.
- The repo is `rangrik/macbud`. If the active `gh` account is not `rangrik`, `gh pr create` fails with
  "must be a collaborator". Fix it with `gh auth switch --hostname github.com --user rangrik`, and
  switch back to the original account once the release is published.

## 2. Version bump

Bump both keys in `project.yml`: `CFBundleShortVersionString` (semver) and `CFBundleVersion` (integer, +1).
Patch for fixes and small features, minor for a new capability.

Then `make build` once so `Sources/MacBud/Info.plist` regenerates, and write `docs/releases/vX.Y.Z.md`:

```
# MacBud vX.Y.Z

<one sentence: what a user can now do>

- <change, written as the user's outcome, not the code>
- ...

Requires macOS 26 or later. Universal (Apple Silicon + Intel). Signed with an Apple Development
certificate and **not notarized**, so macOS may block a downloaded copy.
```

Commit as `Release X.Y.Z` with a one-line body naming the headline change, then run `make test`
again. The pre-flight run predates this commit, so it did not cover what actually ships.

## 3. PR and merge

```bash
git push -u origin <branch>
gh pr create --base main --head <branch> --title "<headline>" --body "<what changed + verification>"
gh pr merge <number> --squash --delete-branch=false
```

The repo rejects `--rebase`. Put real evidence in the PR body: test counts, diagnostics output, screenshot names.

## 4. Rebuild from main

In a worktree you cannot check out `main`, so point the branch at the merged commit instead:

```bash
git fetch origin
git reset --hard origin/main
git diff --stat HEAD origin/main   # must be empty
make test                          # this tree is what gets packaged and installed
```

## 5. Package and install

```bash
make package    # Release build + dist/MacBud-X.Y.Z-macOS.zip + .sha256
make install    # replaces /Applications/MacBud.app and relaunches it
```

`make install` quits a running MacBud first and rolls back the previous app if anything fails.
Confirm the result:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/MacBud.app/Contents/Info.plist
pgrep -lf '/Applications/MacBud.app'
```

## 6. Publish

Release notes are the doc body without its `# ` heading, plus the checksum:

```bash
SHA=$(awk '{print $1}' dist/MacBud-X.Y.Z-macOS.zip.sha256)
{ tail -n +3 docs/releases/vX.Y.Z.md; printf '\nSHA-256: `%s`\n' "$SHA"; } > /tmp/relnotes.md
gh release create vX.Y.Z --title "MacBud X.Y.Z" --notes-file /tmp/relnotes.md --target main \
  dist/MacBud-X.Y.Z-macOS.zip dist/MacBud-X.Y.Z-macOS.zip.sha256
```

Then restore the `gh` account you switched away from.

## 7. Report

One line of evidence each: test count, PR URL, merge commit, installed version, release URL.

## Stop and ask

- Tests fail at any of the three points, the tree is dirty, or `codesign --verify` fails.
- The active `gh` account cannot open the PR and switching accounts is denied.
- `make install` reports MacBud is still running.
