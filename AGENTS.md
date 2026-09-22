# marfa-swift-sdk

The Swift package `Marfa`, product `Marfa`: a thin layer over `MarfaCore`, the Rust engine every native client embeds, built from the monorepo `withmarfa/marfa`. The package does no networking, storage or syncing of its own; the core does all three.

Under rebuild. Anything in this repository that describes the earlier SwiftData engine is being removed, and none of it is supported.

## Versions

- **Every version is the previous one plus 0.0.1, whatever the size of the change.** Numbering starts again from 0: the first version is 0.0.1.
- A version exists only as a git tag, and tags are August's. Agents never create a tag or write a version into a file.

## In force

- American English in code, comments and commits. Scoped Conventional Commits (`feat(package):`, `fix(ci):`).
- Feature branches and pull requests; never push `main`. A session merges its own pull request once every required check is green and its reviewers have run: squash, branch deleted.
- Every Actions workflow runs on the self-hosted runner pool, never on GitHub-hosted runners.
- No personal details of any machine or person in this repository: no absolute paths, hostnames, account names or credentials.
- Removed means gone: no shims, no aliases, no compatibility paths.
- A comment survives only if it explains a why the code cannot.
- Swift 6 language mode; Swift Testing, not XCTest.
