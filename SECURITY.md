# Security policy

Security fixes target the latest commit on `main`. This is a portfolio project with no production support SLA.

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/ai-calypse/voice-mac/security/advisories/new).
Include the affected commit, reproduction steps, impact, and a proposed fix if available. Do not post credentials,
private audio, transcripts, or exploit details in a public issue. If private reporting is unavailable, open an issue
requesting a private contact without disclosing the vulnerability.

## Development practices

Pull requests run with read-only repository permissions. Security analysis receives only the additional permission
needed to upload results. Third-party Actions are pinned to commit SHAs and Dependabot proposes updates. Keep
secrets in local ignored configuration or GitHub Actions secrets; never commit `.env` files or capture them in demos.
