# OpenAI Codex Proxy for Kubernetes

## 1. Overview

This project packages [`hotchpotch/openai-api-server-via-codex`](https://github.com/hotchpotch/openai-api-server-via-codex) as a secure, private Kubernetes workload.

The proxy exposes an OpenAI-compatible HTTP API backed by a user’s authenticated Codex/ChatGPT session. It must persist and refresh Codex OAuth credentials across pod restarts without storing the actively changing credential file in a read-only Kubernetes Secret volume.

The intended repository is:

```text
jeduardo/openai-codex-proxy-k8s
```

The implementation must be suitable for a private homelab Kubernetes cluster, including k3s.

---

## 2. Goals

The project must:

1. Build a container image containing `openai-api-server-via-codex`.
2. Deploy the proxy as a private Kubernetes `ClusterIP` service.
3. Seed the initial Codex `auth.json` from a Kubernetes Secret.
4. Store the live, refreshable `auth.json` on writable persistent storage.
5. Allow the proxy process to refresh and atomically rewrite the credential file.
6. Protect the proxy API with a separate bearer token.
7. Run as a non-root user with a read-only root filesystem.
8. Prevent multiple replicas from concurrently refreshing the same OAuth credentials.
9. Provide documentation for installation, credential bootstrap, upgrades, backup, recovery, and troubleshooting.
10. Include automated validation for the Dockerfile and Kubernetes manifests.

---

## 3. Non-goals

The project will not:

- Implement a replacement OAuth flow.
- Automate interactive Codex login inside Kubernetes.
- Expose the proxy publicly by default.
- Support multiple replicas sharing the same Codex account.
- Provide multi-user account isolation.
- Synchronize refreshed credentials back into Kubernetes Secrets by default.
- Bypass ChatGPT or Codex usage limits.
- Provide an officially supported OpenAI API implementation.

---

## 4. Upstream application behavior

The upstream proxy reads a Codex authentication file, normally:

```text
~/.codex/auth.json
```

The path can be overridden with:

```text
OPENAI_VIA_CODEX_AUTH_JSON
```

The authentication file contains:

- an access token;
- an ID token;
- a refresh token;
- account metadata;
- the authentication mode.

When the access token approaches expiry, the application:

1. reads the current authentication file;
2. uses the refresh token to request new tokens;
3. updates the token fields;
4. writes a temporary file;
5. atomically replaces the original `auth.json`.

Because of this behavior, the live authentication file must reside on a writable filesystem.

A Kubernetes Secret volume cannot be used as the live credential path because projected Secret volumes are read-only.

---

## 5. Architecture

```text
                         Kubernetes namespace: ai

  Kubernetes Secret
  codex-auth-bootstrap
  ┌─────────────────────┐
  │ initial auth.json   │
  └──────────┬──────────┘
             │ read-only
             ▼
  ┌─────────────────────────────┐
  │ Init container              │
  │                             │
  │ If PVC auth.json is absent: │
  │ copy Secret → PVC           │
  │ chmod 0600                  │
  │ chown application UID       │
  └──────────────┬──────────────┘
                 │
                 ▼
  PersistentVolumeClaim
  ┌─────────────────────────────┐
  │ /var/lib/codex/auth.json    │
  │                             │
  │ writable and persistent     │
  └──────────────┬──────────────┘
                 │
                 ▼
  ┌──────────────────────────────────────────┐
  │ openai-api-server-via-codex              │
  │                                          │
  │ - reads auth.json                        │
  │ - refreshes access token                 │
  │ - updates refresh token when rotated     │
  │ - atomically rewrites auth.json          │
  │ - exposes OpenAI-compatible HTTP API     │
  └───────────────────┬──────────────────────┘
                      │
                      ▼
             Kubernetes ClusterIP
```

---

## 6. Repository structure

The repository should use the following structure:

```text
.
├── .github
│   └── workflows
│       ├── build.yaml
│       └── validate.yaml
├── deploy
│   ├── base
│   │   ├── deployment.yaml
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── network-policy.yaml
│   │   ├── pvc.yaml
│   │   └── service.yaml
│   └── examples
│       ├── bootstrap-secret.example.yaml
│       └── proxy-api-key.example.yaml
├── scripts
│   ├── bootstrap-auth-secret.sh
│   ├── generate-api-key.sh
│   └── verify.sh
├── .dockerignore
├── .gitignore
├── Dockerfile
├── LICENSE
├── README.md
├── SECURITY.md
└── SPEC.md
```

`SPEC.md` should contain this specification.

---

## 7. Container image

### 7.1 Base image

Use an official slim Python image:

```dockerfile
FROM python:3.12-slim
```

The Python version must be compatible with the upstream package.

### 7.2 Package version

The upstream package version must be pinned through a build argument:

```dockerfile
ARG APP_VERSION=0.1.3
```

The image must not install an unbounded `latest` release.

Installation:

```dockerfile
RUN pip install --no-cache-dir \
    "openai-api-server-via-codex==${APP_VERSION}"
```

### 7.3 Runtime user

The image must create a dedicated non-root user and group.

Required defaults:

```text
UID: 10001
GID: 10001
```

The entrypoint must execute:

```text
openai-api-server-via-codex
```

Default arguments:

```text
--host 0.0.0.0
--port 18080
```

### 7.4 Image requirements

The image must:

- run as UID and GID `10001`;
- expose TCP port `18080`;
- contain no Codex credentials;
- contain no shell scripts with embedded tokens;
- avoid package caches;
- use a deterministic upstream package version;
- support `linux/amd64` and `linux/arm64` builds.

---

## 8. Kubernetes resources

### 8.1 Namespace

Default namespace:

```text
ai
```

The namespace manifest may be omitted by users who already manage it externally.

### 8.2 PersistentVolumeClaim

Create a PVC named:

```text
codex-auth
```

Default requirements:

```yaml
accessModes:
  - ReadWriteOnce
resources:
  requests:
    storage: 32Mi
```

The default base manifest should not hard-code a cluster-specific storage class.

A k3s example may document use of:

```yaml
storageClassName: local-path
```

The PVC contains the active credential file:

```text
/var/lib/codex/auth.json
```

### 8.3 Bootstrap Secret

The initial credential Secret must be named:

```text
codex-auth-bootstrap
```

Required key:

```text
auth.json
```

The Secret is only a bootstrap source. It is not the authoritative copy after the first successful token refresh.

It should normally be created imperatively:

```bash
kubectl -n ai create secret generic codex-auth-bootstrap \
  --from-file=auth.json="$HOME/.codex/auth.json"
```

The repository must not contain real credentials.

### 8.4 Proxy API key Secret

The incoming proxy must be protected with a separate API key stored in:

```text
codex-proxy-api-key
```

Required key:

```text
api-key
```

Example creation:

```bash
kubectl -n ai create secret generic codex-proxy-api-key \
  --from-literal=api-key="$(openssl rand -hex 32)"
```

The proxy API key must not be confused with the Codex OAuth access token.

### 8.5 Init container

The Deployment must include an init container named:

```text
bootstrap-auth
```

Responsibilities:

1. Check whether `/data/auth.json` already exists and is non-empty.
2. If it exists, leave it unchanged.
3. If it does not exist, copy `/bootstrap/auth.json` from the Secret volume.
4. Fail if neither an existing PVC credential file nor a bootstrap file exists.
5. Set permissions to `0600`.
6. Set ownership to UID and GID `10001`.

Illustrative logic:

```sh
set -eu

if [ ! -s /data/auth.json ]; then
  if [ ! -s /bootstrap/auth.json ]; then
    echo "No persisted auth.json or bootstrap credential found" >&2
    exit 1
  fi

  cp /bootstrap/auth.json /data/auth.json
fi

chmod 0600 /data/auth.json
chown 10001:10001 /data/auth.json
```

The bootstrap Secret volume must be mounted read-only.

### 8.6 Deployment

The Deployment must use:

```yaml
replicas: 1
strategy:
  type: Recreate
```

`Recreate` is required because OAuth refresh token rotation may make concurrent writers unsafe.

The application container must receive:

```yaml
env:
  - name: OPENAI_VIA_CODEX_AUTH_JSON
    value: /var/lib/codex/auth.json
```

The proxy API key must be loaded from the Secret:

```yaml
- name: OPENAI_VIA_CODEX_API_KEY
  valueFrom:
    secretKeyRef:
      name: codex-proxy-api-key
      key: api-key
```

Set:

```yaml
automountServiceAccountToken: false
```

No Kubernetes API permissions are required by the application.

### 8.7 Security context

Pod-level settings:

```yaml
securityContext:
  fsGroup: 10001
  fsGroupChangePolicy: OnRootMismatch
```

Container-level settings:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
```

A writable `emptyDir` must be mounted at:

```text
/tmp
```

The PVC must be mounted at:

```text
/var/lib/codex
```

### 8.8 Service

Create a `ClusterIP` Service named:

```text
openai-codex-proxy
```

Default port:

```text
18080
```

Example in-cluster base URL:

```text
http://openai-codex-proxy.ai.svc.cluster.local:18080/v1
```

The Service must not be a `LoadBalancer` or `NodePort` by default.

### 8.9 Health probes

Use the upstream health endpoint:

```text
/healthz
```

Readiness probe example:

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    port: http
  initialDelaySeconds: 3
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
```

Liveness probe example:

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: http
  initialDelaySeconds: 10
  periodSeconds: 30
  timeoutSeconds: 3
  failureThreshold: 3
```

The health endpoint does not need to validate upstream Codex availability. It should indicate whether the local server process is responsive.

### 8.10 Resources

Default resources:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: "1"
    memory: 1Gi
```

These defaults should be documented as starting points rather than guarantees.

---

## 9. Network security

The default deployment must remain private inside the cluster.

A default-deny NetworkPolicy should be included where supported.

The policy should:

- permit ingress to TCP port `18080` only from explicitly labelled client pods or namespaces;
- permit DNS resolution;
- permit HTTPS egress to OpenAI and ChatGPT services;
- avoid attempting hostname-based Kubernetes NetworkPolicy rules, because standard Kubernetes NetworkPolicy supports IP and selector rules rather than domain names.

Because OpenAI endpoint IP ranges may change, the project should document these alternatives:

1. allow general TCP/443 egress from the proxy namespace;
2. route egress through a controlled HTTP proxy;
3. use a CNI with FQDN-aware egress policy support;
4. maintain explicit IP ranges externally.

The base manifest may include a conservative policy that permits:

- cluster DNS;
- outbound TCP/443;
- inbound traffic from pods labelled:

```text
openai-codex-proxy-client=true
```

Example client pod label:

```yaml
metadata:
  labels:
    openai-codex-proxy-client: "true"
```

---

## 10. Credential lifecycle

### 10.1 Initial login

The user must authenticate interactively outside Kubernetes using a trusted workstation.

The resulting file is typically:

```text
$HOME/.codex/auth.json
```

The file must be copied into the bootstrap Kubernetes Secret.

### 10.2 First deployment

On the first pod startup:

1. the PVC is empty;
2. the init container copies the Secret’s `auth.json` to the PVC;
3. file ownership and permissions are fixed;
4. the proxy starts using the PVC copy.

### 10.3 Normal token refresh

During normal requests:

1. the proxy checks the access token expiry;
2. if the token is near expiry, it uses the refresh token;
3. newly issued tokens are written to the PVC;
4. subsequent requests use the refreshed credentials.

No separate token refresh CronJob is required.

### 10.4 Pod restart

On restart:

1. the init container finds the existing PVC credential file;
2. it does not overwrite it with the older bootstrap Secret;
3. the application resumes using the latest persisted credentials.

### 10.5 Refresh-token rotation

The OAuth provider may return a new refresh token.

After rotation, the PVC copy may be newer than the original bootstrap Secret.

The documentation must clearly warn:

> The initial Kubernetes Secret is only a bootstrap mechanism. After token rotation, restoring only the original Secret may not restore access.

### 10.6 Reauthentication

If refresh fails permanently:

1. run Codex login again on a trusted workstation;
2. replace the bootstrap Secret;
3. replace or remove the persisted PVC `auth.json`;
4. restart the Deployment.

A recovery procedure must be documented.

---

## 11. Backup and recovery

### 11.1 Recommended approach

Back up the PVC using encrypted storage snapshots or an encrypted Kubernetes backup system.

The backup contains account credentials and must be handled as highly sensitive data.

### 11.2 Manual backup

An optional documented manual procedure may copy the current file:

```bash
kubectl -n ai exec deploy/openai-codex-proxy -- \
  cat /var/lib/codex/auth.json > auth.json.backup
```

The documentation must discourage leaving the resulting file unencrypted.

A safer example should use restrictive permissions:

```bash
umask 077
kubectl -n ai exec deploy/openai-codex-proxy -- \
  cat /var/lib/codex/auth.json > auth.json.backup
```

### 11.3 Secret synchronization

Automatic synchronization of refreshed credentials back into a Kubernetes Secret is out of scope for the default deployment.

Reasons:

- it requires Kubernetes API write permissions;
- it expands the impact of a pod compromise;
- it creates potential update races;
- it makes the application responsible for cluster-level secret management.

This may be documented as an optional future enhancement.

---

## 12. Configuration

The following application settings should be configurable through environment variables or command arguments.

| Setting                      |                    Default | Description                            |
| ---------------------------- | -------------------------: | -------------------------------------- |
| `OPENAI_VIA_CODEX_AUTH_JSON` | `/var/lib/codex/auth.json` | Writable Codex authentication file     |
| `OPENAI_VIA_CODEX_API_KEY`   |                   required | Incoming bearer token                  |
| Host                         |                  `0.0.0.0` | Bind address                           |
| Port                         |                    `18080` | HTTP port                              |
| Default model                |           upstream default | Default Codex model                    |
| Timeout                      |           upstream default | Backend request timeout                |
| Maximum concurrent requests  |           upstream default | Local concurrency limit                |
| Maximum stored items         |           upstream default | In-memory response compatibility store |

The Kubernetes manifest should support additional arguments through Kustomize patches rather than requiring a fork.

---

## 13. Client usage

Clients inside Kubernetes should use:

```bash
export OPENAI_BASE_URL="http://openai-codex-proxy.ai.svc.cluster.local:18080/v1"
export OPENAI_API_KEY="<proxy-api-key>"
```

Python example:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://openai-codex-proxy.ai.svc.cluster.local:18080/v1",
    api_key="proxy-api-key",
)

response = client.responses.create(
    model="gpt-5.5",
    input="Return a one-sentence response.",
)

print(response.output_text)
```

The supplied API key authenticates to the proxy. It is not sent to the Codex backend.

---

## 14. Kustomize support

The base deployment must be installable with:

```bash
kubectl apply -k deploy/base
```

The base `kustomization.yaml` should include:

```yaml
resources:
  - namespace.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - network-policy.yaml
```

The image must be replaceable using:

```yaml
images:
  - name: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newTag: "<version>"
```

Cluster-specific overlays are optional but recommended.

Possible future overlays:

```text
deploy/overlays/k3s
deploy/overlays/tailscale
deploy/overlays/traefik
```

---

## 15. GitHub Container Registry

The default image name should be:

```text
ghcr.io/jeduardo/openai-codex-proxy-k8s
```

Tags should include:

- semantic version tags;
- immutable Git commit SHA tags;
- `main` for builds from the default branch.

Examples:

```text
ghcr.io/jeduardo/openai-codex-proxy-k8s:0.1.0
ghcr.io/jeduardo/openai-codex-proxy-k8s:sha-abc1234
ghcr.io/jeduardo/openai-codex-proxy-k8s:main
```

Production documentation should recommend immutable version or SHA tags.

---

## 16. CI requirements

### 16.1 Manifest validation workflow

The validation workflow should run on pull requests and pushes.

Required checks:

- YAML syntax validation;
- `kubectl kustomize deploy/base`;
- Kubernetes schema validation;
- shell script linting;
- Dockerfile linting.

Suggested tools:

- `yamllint`;
- `kubeconform`;
- `shellcheck`;
- `hadolint`;
- `kubectl kustomize`.

Example validation commands:

```bash
kubectl kustomize deploy/base > /tmp/rendered.yaml
kubeconform -strict -summary /tmp/rendered.yaml
shellcheck scripts/*.sh
hadolint Dockerfile
```

### 16.2 Image build workflow

The build workflow should:

1. build the container for `linux/amd64` and `linux/arm64`;
2. use Docker Buildx;
3. use GitHub Actions cache;
4. push to GHCR on the default branch and version tags;
5. avoid pushing images for untrusted pull requests;
6. generate image provenance where practical.

### 16.3 Dependency updates

Dependabot or Renovate may be configured for:

- GitHub Actions;
- Docker base images;
- the pinned upstream Python package version.

Upstream application upgrades must remain explicit and reviewable.

---

## 17. Scripts

### 17.1 `bootstrap-auth-secret.sh`

Responsibilities:

- accept an optional auth file path;
- default to `$HOME/.codex/auth.json`;
- verify the file exists;
- verify it is valid JSON;
- optionally confirm `auth_mode` is `chatgpt`;
- create or replace `codex-auth-bootstrap`;
- avoid printing token contents.

Example interface:

```bash
./scripts/bootstrap-auth-secret.sh \
  --namespace ai \
  --file "$HOME/.codex/auth.json"
```

### 17.2 `generate-api-key.sh`

Responsibilities:

- generate a cryptographically strong random API key;
- create or replace `codex-proxy-api-key`;
- avoid printing the key unless explicitly requested.

Example interface:

```bash
./scripts/generate-api-key.sh --namespace ai
```

### 17.3 `verify.sh`

The verification script should:

1. render the Kustomize manifests;
2. validate the rendered resources;
3. lint shell scripts;
4. lint the Dockerfile;
5. optionally build the image locally.

---

## 18. Documentation requirements

The `README.md` must cover:

1. project purpose;
2. security and support disclaimer;
3. prerequisites;
4. building the image;
5. authenticating Codex locally;
6. creating the bootstrap Secret;
7. creating the proxy API key;
8. deploying with Kustomize;
9. testing the health endpoint;
10. calling the OpenAI-compatible API;
11. upgrading the image;
12. recovering from expired credentials;
13. backing up the live token file;
14. removing the deployment;
15. troubleshooting common failures.

The README must prominently state:

- this is not the official OpenAI Platform API;
- it depends on an unofficial or semi-official Codex backend interface;
- the upstream interface may change;
- the service must not be exposed to untrusted networks;
- credentials must not be shared or committed;
- the deployment must remain single-replica.

---

## 19. Security requirements

### 19.1 Mandatory controls

The implementation must:

- run as non-root;
- drop all Linux capabilities;
- disable privilege escalation;
- use a read-only root filesystem;
- disable service-account token mounting;
- keep the Service private by default;
- require a proxy API key;
- mount the bootstrap Secret read-only;
- store live credentials with file mode `0600`;
- avoid logging token contents;
- avoid embedding secrets in image layers;
- avoid embedding secrets in command-line arguments;
- use one replica;
- use `Recreate` deployment strategy.

### 19.2 Secret handling

The documentation must warn that Kubernetes Secret data is base64-encoded, not inherently encrypted.

Cluster operators should enable:

- Kubernetes encryption at rest;
- encrypted etcd or datastore backups;
- restricted RBAC access;
- namespace-level access controls.

### 19.3 Logging

Application logs must not include:

- access tokens;
- refresh tokens;
- ID tokens;
- incoming proxy API keys;
- full authentication JSON;
- authorization headers.

CI must not upload credentials as artifacts.

### 19.4 Public exposure

Ingress resources must not be included in the base deployment.

Any optional ingress example must require:

- TLS;
- proxy API-key authentication;
- IP restrictions or private-network access;
- explicit operator acknowledgement of the risks.

---

## 20. Failure modes

### Missing bootstrap credentials

Symptom:

```text
No persisted auth.json or bootstrap credential found
```

Expected behavior:

- init container fails;
- application container does not start.

Resolution:

- create `codex-auth-bootstrap`;
- restart the Deployment.

### Invalid authentication JSON

Symptom:

- application authentication preflight fails;
- pod enters `CrashLoopBackOff`.

Resolution:

- inspect logs without exposing credentials;
- recreate the Secret from a valid Codex login;
- replace the persisted file if required.

### Refresh token rejected

Symptom:

- requests fail after the access token expires;
- logs show refresh failure.

Resolution:

- perform a new interactive Codex login;
- replace the bootstrap Secret;
- replace the PVC credential file;
- restart the Deployment.

### Read-only filesystem error

Symptom:

- token refresh fails when writing `auth.json`.

Likely cause:

- authentication file mounted directly from a Secret;
- PVC mounted read-only;
- incorrect path configuration.

Resolution:

- ensure `OPENAI_VIA_CODEX_AUTH_JSON` points to the PVC;
- ensure the PVC mount is writable.

### Permission denied

Symptom:

- application cannot read or replace `auth.json`.

Resolution:

- verify init-container ownership;
- verify `fsGroup`;
- verify UID and GID `10001`;
- verify mode `0600`.

### Concurrent token refresh

Symptom:

- credentials intermittently become invalid during rollouts.

Likely cause:

- multiple replicas;
- rolling-update overlap.

Resolution:

- set `replicas: 1`;
- use `strategy.type: Recreate`.

### PVC loss

Symptom:

- deployment falls back to an older bootstrap refresh token;
- token refresh may fail.

Resolution:

- restore an encrypted PVC backup;
- otherwise perform a new Codex login.

---

## 21. Upgrade strategy

Upgrades should follow this process:

1. update the pinned upstream package version;
2. build the image;
3. run CI validation;
4. test authentication preflight;
5. test a non-streaming response;
6. test a streaming response;
7. test token-file persistence across a pod restart;
8. deploy with `Recreate`;
9. monitor logs for authentication errors.

The PVC must not be deleted during normal upgrades.

The bootstrap Secret must not overwrite an existing live credential file.

---

## 22. Uninstallation

Remove workload resources:

```bash
kubectl delete -k deploy/base
```

Credential storage should require a separate explicit deletion step:

```bash
kubectl -n ai delete pvc codex-auth
kubectl -n ai delete secret codex-auth-bootstrap
kubectl -n ai delete secret codex-proxy-api-key
```

The README must warn that deleting the PVC removes the latest refreshed credential state.

---

## 23. Acceptance criteria

The implementation is complete when all of the following are true.

### Image

- [ ] The image builds successfully.
- [ ] The image runs as UID `10001`.
- [ ] The upstream package version is pinned.
- [ ] No credentials are present in the image.
- [ ] The image supports `amd64` and `arm64`.

### Kubernetes deployment

- [ ] `kubectl apply -k deploy/base` succeeds.
- [ ] The Deployment runs exactly one replica.
- [ ] The Deployment uses `Recreate`.
- [ ] The application runs as non-root.
- [ ] The root filesystem is read-only.
- [ ] The service-account token is not mounted.
- [ ] The Service is `ClusterIP`.
- [ ] The health endpoint passes readiness and liveness checks.

### Credential management

- [ ] The initial `auth.json` is copied from a Secret to the PVC.
- [ ] An existing PVC credential is never overwritten by the bootstrap Secret.
- [ ] The application can rewrite the PVC credential file.
- [ ] The credential file persists across pod restarts.
- [ ] File permissions are `0600`.
- [ ] The proxy API key is separate from Codex credentials.

### API behavior

- [ ] `/healthz` returns success.
- [ ] `/v1/models` is reachable with the correct proxy API key.
- [ ] Requests without the correct API key are rejected.
- [ ] A non-streaming Responses request succeeds.
- [ ] A streaming Responses request succeeds.
- [ ] Clients can use the Kubernetes Service DNS name.

### Security

- [ ] No token values appear in logs.
- [ ] No real Secret manifests are committed.
- [ ] NetworkPolicy restricts inbound access.
- [ ] Public ingress is not enabled by default.
- [ ] Documentation warns against multi-replica deployment.

### CI

- [ ] YAML validation passes.
- [ ] Kustomize rendering passes.
- [ ] Kubernetes schema validation passes.
- [ ] ShellCheck passes.
- [ ] Hadolint passes.
- [ ] Multi-architecture image builds pass.

---

## 24. Optional future enhancements

The following may be implemented later:

- Helm chart packaging;
- External Secrets Operator integration;
- SOPS-encrypted bootstrap Secret examples;
- Sealed Secrets examples;
- encrypted PVC backup jobs;
- Cilium FQDN egress policies;
- Tailscale-only access;
- Traefik ingress examples;
- Prometheus metrics;
- PodDisruptionBudget documentation;
- automatic upstream release detection;
- optional credential synchronization to an external secret manager;
- support for multiple isolated Codex accounts using separate StatefulSet instances.

These enhancements must preserve the default single-account, single-replica security model.

---

## 25. Implementation summary

The core implementation rule is:

> Use a Kubernetes Secret only to seed the initial authentication file. Store the actively refreshed authentication file on a writable persistent volume.

This allows the upstream proxy to manage access-token expiry and refresh-token rotation while preserving the updated credentials across Kubernetes pod restarts.
