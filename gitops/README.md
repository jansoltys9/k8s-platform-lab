# GitOps

Argo CD reads the desired Kubernetes state from this repository.

| Path | Purpose |
|---|---|
| `bootstrap/platformlab-root.yaml` | Parent App-of-Apps; watches `gitops/apps/` |
| `apps/` | Child Applications and AppProjects (application, monitoring, storage, secrets, etc.) |
| `secrets/` | Encrypted SealedSecret manifest; never commit plaintext secrets |

## Which changes are automatic?

- Application image or Helm changes: the `platformlab` child Application automatically syncs the chart in `helm/platformlab/`.
- Monitoring values: the `platformlab-monitoring` child can sync its updated values.
- A change under `gitops/apps/`: `platformlab-root` currently requires a **manual Sync** in Argo CD after the PR is merged. This is intentional during first-time setup, when dependencies and the cluster-specific SealedSecret must be prepared first.
- A change to `bootstrap/platformlab-root.yaml` does **not** update the existing root Application automatically: the root watches `apps/`, not its own YAML file. Apply a reviewed root configuration change explicitly.

Example branch for an app Application change: `gitops/app-sync-policy` (Case C). For an add-on chart upgrade, use `platform/monitoring-upgrade` (Case D). Neither change needs a new frontend/backend SemVer tag.

For the step-by-step commands, see [C – Helm and application GitOps](../docs/operations/C-HELM-GITOPS.md) or [D – Platform and add-ons](../docs/operations/D-PLATFORM.md). For diagrams and ownership, see the [repository map](../docs/REPOSITORY-AND-GITOPS-MAP.md). For a new full lab, start with [bootstrap modes](../docs/BOOTSTRAP-MODES.md) and [Sealed Secrets setup](../docs/FULL-LAB-SECRETS.md).
