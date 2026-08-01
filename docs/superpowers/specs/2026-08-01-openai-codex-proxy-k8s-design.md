# OpenAI Codex Proxy for Kubernetes — Design

## Scope

Implement the project defined by `docs/spec.md` as a small, auditable repository for a private homelab Kubernetes cluster. The implementation will use the MIT license and will not include optional future enhancements such as Helm, ingress, or cluster-specific overlays.

The project packages `openai-api-server-via-codex`, persists its mutable Codex OAuth credentials, protects its OpenAI-compatible API with a separate bearer token, and supplies deployment automation and operational documentation.

## Approach

Use direct, declarative project files: a Dockerfile, handwritten Kustomize resources, POSIX-compatible shell scripts, and GitHub Actions workflows. This approach matches the required repository layout, minimizes dependencies, and keeps security-sensitive behavior easy to audit.

Generated Kubernetes manifests and Helm-first packaging are excluded because they add tooling and abstraction without helping this experiment.

## Architecture

The container image is based on Python 3.12 slim, installs an explicitly pinned upstream package version, and runs the upstream executable on port 18080 as UID and GID 10001.

Kubernetes runs exactly one application replica with a `Recreate` strategy. A bootstrap init container checks a `ReadWriteOnce` PVC for an existing non-empty `auth.json`. If none exists, it copies the initial file from a read-only Kubernetes Secret. It applies ownership 10001:10001 and mode 0600. The application then reads and atomically updates the PVC copy. The init container may run as root solely to set PVC ownership; the application container remains strictly non-root.

A separate Secret provides the incoming proxy API key. A private `ClusterIP` Service exposes the proxy only inside the cluster. A NetworkPolicy permits ingress from explicitly labelled client pods, DNS egress, and TCP/443 egress. The documentation will explain that standard NetworkPolicy cannot restrict egress by hostname.

## Components

- **Dockerfile:** Builds the pinned application without credentials or package caches and defines secure non-root runtime defaults.
- **Deployment:** Configures single-replica execution, credential bootstrap, restrictive security contexts, health probes, resource defaults, writable PVC storage, and writable temporary storage.
- **PVC:** Stores the authoritative live credential at `/var/lib/codex/auth.json` across restarts.
- **Secrets:** `codex-auth-bootstrap` seeds the initial credential; `codex-proxy-api-key` independently authenticates clients.
- **Service:** Provides the cluster-local API on TCP port 18080.
- **NetworkPolicy:** Applies default-deny behavior with narrowly described ingress and required DNS/HTTPS egress allowances.
- **Kustomization:** Installs all base resources and supports replacing the default GHCR image and tag.
- **Scripts:** Create or replace Secrets safely and run local validation without exposing token values.
- **GitHub Actions:** Validate repository artifacts and build or publish multi-architecture images under trusted event conditions.
- **Documentation:** Covers installation, security limitations, operation, upgrade, backup, recovery, removal, and troubleshooting.
- **License:** MIT.

`SPEC.md` will contain the supplied specification. The original `docs/spec.md` will remain in place.

## Credential data flow

Initial credential flow is workstation → bootstrap Secret → PVC. The Secret is a read-only seed and is not synchronized after startup. Once initialized, the PVC is authoritative.

On restart, any non-empty PVC file takes precedence over the Secret. This prevents an old bootstrap refresh token from replacing newer rotated credentials. If credentials become permanently invalid, an operator must log in again outside Kubernetes, update the Secret, explicitly replace or remove the persisted file, and restart the Deployment.

## Error handling and security

Missing or empty credentials in both the PVC and Secret cause the init container to fail with a non-sensitive error. Existing PVC credentials are never automatically overwritten.

Helper scripts will use strict shell behavior, validate inputs and dependencies, validate authentication JSON, and avoid printing secrets. The API-key script will print a generated value only when explicitly requested.

The application container runs without root, Linux capabilities, privilege escalation, a writable root filesystem, or an automatically mounted service-account token. The bootstrap Secret mount is read-only. The init container receives only the filesystem privileges required to initialize ownership and permissions.

No real credentials, authorization headers, or token-bearing artifacts are included in source, images, logs, or CI outputs. Documentation will identify Kubernetes Secret and backup risks and will warn against public exposure and multiple replicas.

## Validation

This quick experiment will not include a dedicated behavioral test suite or mocked script tests. It will retain the lightweight automated validation required by the supplied specification:

- YAML linting;
- Kustomize rendering;
- strict Kubernetes schema validation;
- ShellCheck;
- Hadolint;
- multi-architecture image builds;
- an optional local image build through `scripts/verify.sh --build`.

Runtime checks requiring private Codex credentials or a Kubernetes cluster—health, API-key rejection, model listing, streaming and non-streaming requests, and credential persistence—will be documented as manual acceptance procedures.

## Delivery boundaries

The implementation includes only the base Kustomize deployment, example placeholder Secret manifests, helper scripts, CI workflows, and required documentation. It does not include ingress, Helm, credential synchronization, interactive in-cluster login, multi-account support, or cluster-specific overlays.
