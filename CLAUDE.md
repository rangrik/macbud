# MacBud

## Finishing work

When the work on a branch is done and QA'd, ship it without being asked. Run the
`deliver` skill: PR, merge to main, rebuild Release from main, install it into
/Applications, publish the GitHub release. Do not stop at "the code is written"
and wait to be told to open a PR.

Ask first only for what the skill says to stop for: failing tests, a dirty tree,
a failed signature check, or a `gh` account that cannot open the PR.

## Building

`make build` regenerates the Xcode project from `project.yml` first, so a new
source file needs `xcodegen` to run before tests can see it.

`make test` pipes through a filter that hides the failure summary. For the real
result run xcodebuild through `rtk proxy` and grep for `Failing tests:`.
