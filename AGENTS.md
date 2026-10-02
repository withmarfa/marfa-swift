# marfa-swift

The Swift package `Marfa`: Swift types, `async` calls, change streams and errors over `MarfaCore`, the Rust engine from `withmarfa/marfa` that every native client embeds. The core does the networking, storage and syncing.

## Layout and build

- `MarfaCoreFFI` is the core as a binary, `Frameworks/MarfaCoreFFI.xcframework`, gitignored; a release tag points it at a prebuilt archive instead. `MarfaCore` is its UniFFI glue and `Sources/MarfaTypes` the server's wire types, both generated, committed and never edited. `MarfaCoreNames` exists because the glue's class shares its module's name. `Marfa` is the hand-written layer apps import.
- `core.pin` names the commit on marfa's `main` the package is built against. `scripts/core.sh` builds the core at that commit, copies the framework and glue in, and regenerates the wire types; it needs the Rust toolchain. By default it fetches the pinned commit into `.build/marfa`, a build input like any other under `.build/`, never a working clone: do not edit, branch or commit there. With `MARFA_MONOREPO` it builds from a clean checkout already at the pin instead, such as a detached worktree of an existing marfa clone. CI fails when the committed glue or wire types differ from what the pin generates.
- Then `swift build` and `swift test`. Live tests run against the server `MARFA_API_URL` and `MARFA_API_KEY` name and are skipped by name without them; `MARFA_LIVE_REQUIRED` makes a missing server fail. marfa's `core/scripts/server-up.sh` boots one from the pinned checkout once `pnpm install --frozen-lockfile` and `pnpm --filter "@withmarfa/server..." build` have run there; export its `MARFA_TEST_URL` and `MARFA_TEST_KEY` as `MARFA_API_URL` and `MARFA_API_KEY`, and stop it with `core/scripts/server-down.sh`.
- No test reads or writes an item in the login keychain or raises a dialog. A test that keeps a key uses `inIsolatedKeychain`, a keychain file outside the search list with prompts refused for the process. CI compares the login keychain's generic passwords under the tests' service before and after the suite; it checks nothing else, and nothing checks a local `swift test`.
- `Examples/MarfaSample` is the sample app. `xcodegen generate` makes its project, which is gitignored.
- `.github/workflows/ci.yml`'s `Build + test` is the full check: lint, the core at the pin, both generated sources, the live tests against a booted server, both sample builds, and the sample's scenario offline and back.
- `scripts/ci-changes.sh` decides whether a pull request runs `Build + test`: Markdown anywhere, `LICENSE`, `.claude/` and `.github/` other than the workflow do not, and an unnamed path or a push does. A skipped job passes its required check; `scripts/ci-changes.test.sh` pins the rules and runs first in the job. The core is rebuilt only when `core.pin`, `scripts/core.sh` or `generator/` changes; otherwise the job reuses what that pin generated.
- `.github/workflows/codeql.yml` analyzes Actions and Swift on every push to `main`, once a week, and on a pull request unless it changes only Markdown, the license or `.claude/`. It is not a required check, so a `paths-ignore` filter starts no run at all for documentation. Its Swift job builds the library targets for one architecture beside the framework `ci.yml` caches for the pin, so a change to that cache's paths or key changes both workflows.

## Versions

- A version is a tag on this repository, which is where SwiftPM reads versions from, created only when a release is called for, each the previous plus 0.0.1 whatever the change, as `v0.0.1`, `v0.0.2` and so on. No one writes a version into a file.
- `.github/workflows/release.yml`, run from `main`, makes a release. With `dry_run`, the default, it builds the core at the pin and an app on the archived framework without Rust. Without it, it also tags the next version on a commit on top of `main` that only points the binary target at the release's archive and checksum, publishes the release from the `release` environment, which only `main` can deploy to, and builds an app on it by URL.

## Working here

- American English in code, comments and commits. Scoped Conventional Commits (`feat(package):`, `fix(ci):`).
- One clone per machine. Parallel work happens in worktrees inside it, made with `git worktree add .claude/worktrees/<name> -b <branch> origin/main`; never a second clone or a sibling folder. Once a branch is merged, `git worktree remove` its worktree and run `git worktree prune`; if git refuses, report it rather than forcing it.
- Feature branches and pull requests; never push `main`. A session merges its own pull request once every required check is green and the review its risk calls for is done, with that depth stated on the pull request: squash, branch deleted.
- Workflows use standard GitHub-hosted runners only. Never hold back a push or a check to ration runners.
- No personal details of any machine or person: no absolute paths, hostnames, account names or credentials.
- Removed means gone: no shims, aliases or compatibility paths.
- A comment stays only if it says what the code cannot: a constraint from outside, a non-obvious reason, a trap. Never what the code does, history, a ticket or a person. When in doubt, it goes.
- Swift 6 language mode, except the generated glue; Swift Testing, not XCTest.
