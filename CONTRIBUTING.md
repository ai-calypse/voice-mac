# Contributing

Start with the [README](README.md) for scope and setup. Report a reproducible bug or discuss a proposed feature
before making a large change. Small, focused pull requests are easiest to review.

## Development loop

Create a branch from current `main`, make the change, and run the relevant checks:

```sh
npm ci
npm run typecheck
npm test
# On macOS:
SIGN_IDENTITY=- ./shell/build.sh
python3 .github/scripts/check-docs.py README.md CONTRIBUTING.md SECURITY.md docs/maintaining.md docs/demo.md
```

Add a regression test for behavior changes. Documentation-only edits do not need artificial tests.
Include the problem, resulting behavior, commands run, and any remaining limitations in the PR. Performance
claims need reproducible inputs and measured evidence; do not present an old benchmark as a new run.

## Review expectations

Keep secrets and generated local data out of commits. Use the issue and PR templates. Maintainers review
correctness, error paths, compatibility, and the evidence behind claims. Required checks must pass and review
threads must be resolved before merging. Solo-maintainer PRs do not require an impossible self-approval.

Version and delivery conventions are in [Maintenance](docs/maintaining.md). Report vulnerabilities using
[the security policy](SECURITY.md), not a public issue.
