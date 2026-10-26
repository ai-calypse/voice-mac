# Maintenance and delivery

## Pull-request checks

The workflow files in [`.github/workflows`](../.github/workflows/) are the source of truth. Required checks
cover the relevant build/tests, repository documentation links, workflow syntax, dependency review, and
CodeQL analysis. CodeQL covers Actions plus JavaScript/TypeScript;
the macOS build checks Swift compilation but is not a Swift security analysis.

`main` uses pull requests, linear history, resolved review threads, and passing checks. Force pushes and branch
deletion are blocked. No approving-review count is required for the solo maintainer. Dependabot groups compatible
updates weekly; review them as normal code changes. Third-party Actions use immutable commit pins.

## Release procedure

1. Merge the release changes through a green PR and inspect the main-branch checks.
2. Choose a new semantic version and create a `vMAJOR.MINOR.PATCH` tag on that commit.
3. Push the tag. The release workflow will run TypeScript checks, offline tests, dependency audit, and a Swift release build, then prepare a draft source release. A portable signed/notarized macOS binary is not currently supported.
4. Inspect the draft, provenance/checksums or image digests, documentation, and known limitations before publishing.

A draft is not a published release. Publishing is a deliberate maintainer step. Do not reuse an existing version
tag. Failed release jobs must be investigated before retrying; no step suppresses a failed test.

## Evidence and demos

The [demo guide](demo.md) states what was recorded and what it proves. Keep capture inputs free of personal
accounts and credentials. Historical results retain their original conditions and dates. A green build alone
is not evidence that every test layer ran or that the software is production-ready.

## Operational follow-up

Check failing main builds promptly, triage dependency/security reports, and update setup instructions when
runtime requirements change. [Security policy](../SECURITY.md).
