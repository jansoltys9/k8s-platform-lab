# B – Change the CI/CD pipeline

**Use for:** `.github/workflows/publish-images.yml` or `.github/scripts/promote-images.py`. **No backend/frontend SemVer bump.** A regular PR validates but never publishes an app image.

## Example B1: update checkout action

```bash
git switch main
git pull --ff-only origin main
git switch -c ci/update-checkout
# Review compatibility, then change actions/checkout@v4 to @v5
# in .github/workflows/publish-images.yml.
git diff --check
git add .github/workflows/publish-images.yml
git commit -m "ci: update checkout action"
git push -u origin ci/update-checkout
```

PR → check validation/Trivy → merge. No new app image or Helm chart version. **The next application release** uses the workflow version found in the tagged commit; if that commit predates a pipeline change, it may still use the earlier workflow.

## Example B2: fix the GitOps promotion script

Branch: `ci/fix-image-promotion`. Change `.github/scripts/promote-images.py` and test *both* services before the PR:

```bash
python -m py_compile .github/scripts/promote-images.py
python .github/scripts/promote-images.py --owner jansoltys9 \
  --component backend --tag v0.1.1 --dry-run
python .github/scripts/promote-images.py --owner jansoltys9 \
  --component frontend --tag v0.1.1 --dry-run
helm lint ./helm/platformlab
```

Do not release a fake version just to test a pipeline-only edit. For **docs-only** changes the app CI won't run: see [Operations](../OPERATIONS.md). If a PR job fails, fix and push the same branch.
