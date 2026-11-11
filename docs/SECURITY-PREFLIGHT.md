# PlatformLab release preflight kit

A local preflight, not a release action. Place these files into `k8s-platform-lab` repo.

```bash
python scripts/platformlab-preflight.py --build --container-linters
```

Optional: `--scout` queries Docker Scout recommendations. The default mode (without `--build`) does not build images.

- Inventory: local CLI versions, newest stable GitHub releases, Docker `FROM` bases, GitOps chart revisions, GitHub Actions used.
- npm: `outdated`, `audit` from lockfiles.
- Scanners: Trivy filesystem and images, Hadolint, actionlint, ShellCheck, Gitleaks; missing optional scanners reported as SKIP.
- Without native Hadolint/actionlint, `--container-linters` pulls known official release containers and uses stdin (no bind mount).
- Docker build is local (`:preflight`) using `--pull`; no push, no tags, no kubectl, no git commit.
- Sanitized JSON and Markdown reports land in `../_local-reports/k8s-platform-lab` outside the Git repo.
- Blocking findings: high/critical vulnerabilities with upstream fixes, any leaked secrets, high/critical misconfiguration, failed scan/build/lint.
- Advisory findings: unfixed vulnerabilities, outdated versions, missing optional tools.
- Dependabot proposes future updates in PRs (frontend npm, backend/frontend Docker, GitHub Actions).

Limitations: "latest" is an upstream version candidate, not necessarily compatible. Mutable image tags and Helm GitOps chart revisions need manual upstream validation and staged rollout. A green preflight is not a guarantee of zero vulnerabilities. Docker Scout and GH APIs require network access; GH API may rate-limit unauthenticated requests.
