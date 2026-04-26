# Layer AWS EKS Cluster Management

Kaptain config layer providing the full AWS EKS cluster management build flow
as a `postVersionsAndNaming` hook on top of the standard
`basic-quality-and-versioning` workflow.

Projects that reference this layer inherit:

- **EKS cluster yaml generation** - `cluster.yaml` and optional
  `cluster-controlplane-only.yaml` from templates with token substitution
- **Pre-build validation** - token reference checks before substitution
- **Docker build** - calls buildon's `docker-build-dockerfile` with the
  generated dockerfile and substitution config
- **Post-build validation** - substituted yaml checks plus image integrity
  verification
- **User hook slots** - optional `userPreDockerPrepare` and
  `userPostDockerTests` for project-specific glue (e.g.
  `copy-scripts-to-docker-context.bash`)
- **Layer payload** - delivers the orchestrator, defaults, prepare, and
  validate scripts to `kaptain-out/`

## Configuring the user hook slots

The orchestrator reads two optional hook paths from the consuming project's
`kaptainpm/final/KaptainPM.yaml` interpolated KaptainPM.yaml under the free-form
 `user-data` section. Both are optional - omit either to skip that slot.

```yaml
user-data:
  aws-eks-cluster-management:
    userPreDockerPrepare: bin/copy-scripts-to-docker-context.bash
    userPostDockerTests: bin/run-image-checks.bash
```

Path resolution is relative to the repo root. Files must be executable
(`chmod +x`).

Position in the orchestrator sequence:

| Slot                   | Runs after            | Runs before          |
|------------------------|-----------------------|----------------------|
| `userPreDockerPrepare` | `prepare`             | `pre-build-validate` |
| `userPostDockerTests`  | `post-build-validate` | (final step)         |

If you need extra inputs from KaptainPM at hook time, add more keys under
`user-data.aws-eks-cluster-management.*` and read them with `yq` inside your
hook script - they're already in the merged file at `kaptainpm/final/KaptainPM.yaml`.

## Origin

This layer replaces the in-buildon `aws-eks-cluster-management` workflow,
scripts, step-commons, and defaults. See history of `buildon-github-actions` or
`kaptain-build-scripts` (once it exists, shared history) to see how that used
to look and work.

## Reference: full user-data block

```yaml
user-data:
  aws-eks-cluster-management:
    baseImage:
      registry: ghcr.io
      namespace: kube-kaptain
      name: aws/aws-eks-cluster-management
      tag: "1.10"
    clusterYamlSubPath: src/eks
    privateNetworking: true
    publicNetworking: false
    ciliumEbpfNetworking: false
    userPreDockerPrepare: bin/copy-scripts-to-docker-context.bash
    userPostDockerTests: bin/run-image-checks.bash
```
