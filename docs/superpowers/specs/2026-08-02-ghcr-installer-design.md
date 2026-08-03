# GHCR Kubernetes Installer — Design

## Scope

Add guided installation support for the existing private GHCR image. The project remains on GitHub with its existing `origin` and GitHub Actions workflows. GitLab CI and GitLab registry work are explicitly out of scope.

The installer will configure GHCR image-pull credentials, bootstrap existing Codex credentials, create the separate proxy API key, apply a temporary image-tag overlay, and wait for the Kubernetes rollout. It will preserve the single-replica OAuth credential model and never alter the live PVC credential automatically.

## Architecture

Use two POSIX shell scripts:

- `scripts/configure-registry-secret.sh` independently creates or replaces a Kubernetes Docker config Secret named `ghcr-pull-secret` for `ghcr.io`.
- `scripts/install.sh` orchestrates prerequisites, current-context confirmation, registry credentials, Codex bootstrap, proxy-key generation, a temporary Kustomize overlay, application, and rollout status.

The Deployment will add `imagePullSecrets` referring to `ghcr-pull-secret`. Kubelet uses that Secret solely to pull the image; the application receives no registry token or mount.

The installer defaults to the existing `main` tag for evaluation, warns that immutable version or SHA tags are preferred, and accepts an image tag override without modifying tracked manifests. Its temporary overlay is private, permission restricted, and removed on exit.

## Components

### Registry pull-Secret helper

`configure-registry-secret.sh` accepts a namespace and GHCR username. It reads a token from `GHCR_TOKEN` or, in an interactive terminal, a hidden prompt. It does not accept a token through command-line arguments. It creates a temporary mode-0600 Docker config and uses it to idempotently apply `ghcr-pull-secret` in the requested namespace. It cleans temporary files and never prints token contents.

Users should supply a GitHub token limited to `read:packages`, with access to the private package. The documentation will explain creating, rotating, revoking, and troubleshooting that credential.

### Guided installer

`install.sh` accepts the namespace, local Codex auth-file path, GHCR username, image tag, noninteractive confirmation, and optional proxy-key display. It validates prerequisites and the selected Kubernetes context, then requires confirmation unless `--yes` is passed. In noninteractive use, `GHCR_TOKEN` is required.

It calls the existing auth bootstrap and API-key scripts plus the new registry helper. It uses a private temporary Kustomize overlay that references the base and replaces the image tag. It applies the overlay and waits for the proxy Deployment rollout. A failed rollout leaves the workload, Secrets, and PVC for troubleshooting; the installer does not delete credentials or persistent data.

### Manifest and validation updates

The base Deployment adds `imagePullSecrets` with `name: ghcr-pull-secret`. `scripts/verify.sh` expands its ShellCheck/syntax inputs to include the new scripts and checks that rendered output contains the pull-Secret reference. Existing YAML linting, Kustomize rendering, and schema validation remain intact. There is no dedicated behavioral test suite under the user-approved reduced validation scope.

## Data flow and boundaries

1. GitHub token → hidden prompt or environment variable → temporary Docker config → `ghcr-pull-secret`.
2. Local Codex `auth.json` → `codex-auth-bootstrap` → PVC live credential.
3. Generated proxy key → `codex-proxy-api-key`.
4. Kubelet authenticates to GHCR with the pull Secret; the proxy never sees the GHCR token.

The installer remains idempotent. Reruns update required Secrets and manifests but do not replace a non-empty live `auth.json` on the PVC.

## Error handling and security

Scripts use `set -eu`, restrictive temporary-file permissions, cleanup traps, explicit dependency checks, and preserved `kubectl` diagnostics. The installer exits before applying the workload when prerequisites, cluster context, registry credentials, or Codex auth validation fail.

No secret is emitted in logs, committed files, command-line arguments, rendered artifacts, or application environment. The GHCR credential is not mounted into the Pod. Documentation will warn that Kubernetes Secret access, cluster nodes, and backups remain sensitive trust boundaries.

## Documentation

`README.md` will describe GHCR package access, least-privilege `read:packages` tokens, interactive and CI-safe installation commands, tag selection, image-pull troubleshooting, rotation, and removal. `SECURITY.md` will add pull-credential scope and incident response guidance.
