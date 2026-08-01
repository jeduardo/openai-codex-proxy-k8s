# OpenAI Codex Proxy for Kubernetes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a secure, single-replica Kubernetes package for `openai-api-server-via-codex` with persistent refreshable credentials, helper scripts, documentation, and lightweight static CI validation.

**Architecture:** A pinned Python image runs the proxy as UID/GID 10001. An init container seeds a writable PVC from an optional read-only Secret only when no persisted credential exists; Kustomize deploys the workload behind a private ClusterIP Service and restrictive NetworkPolicy. Shell helpers manage Secrets without printing their values, and GitHub Actions validate artifacts and publish multi-platform images.

**Tech Stack:** Docker, Python 3.12 slim, Kubernetes, Kustomize, POSIX shell, GitHub Actions, GHCR, yamllint, kubeconform, ShellCheck, Hadolint.

---

## File map

- `Dockerfile`: pinned upstream runtime image and non-root defaults.
- `.dockerignore`: excludes repository and credential artifacts from build context.
- `.gitignore`: excludes local credentials, backups, generated manifests, and editor files.
- `.yamllint.yaml`: repository YAML lint rules.
- `deploy/base/namespace.yaml`: default `ai` namespace.
- `deploy/base/pvc.yaml`: persistent live credential storage.
- `deploy/base/deployment.yaml`: bootstrap and proxy workload.
- `deploy/base/service.yaml`: private cluster service.
- `deploy/base/network-policy.yaml`: default-deny plus required ingress/egress.
- `deploy/base/kustomization.yaml`: complete base package and image replacement target.
- `deploy/examples/bootstrap-secret.example.yaml`: non-secret bootstrap shape.
- `deploy/examples/proxy-api-key.example.yaml`: non-secret API-key shape.
- `scripts/bootstrap-auth-secret.sh`: validated, idempotent bootstrap Secret creation.
- `scripts/generate-api-key.sh`: secure, idempotent API-key Secret creation.
- `scripts/verify.sh`: local static checks and optional image build.
- `.github/workflows/validate.yaml`: pull-request and push validation.
- `.github/workflows/build.yaml`: multi-platform build and trusted publishing.
- `README.md`: installation and operations guide.
- `SECURITY.md`: threat model, reporting, and operator controls.
- `LICENSE`: MIT license.
- `SPEC.md`: canonical copy of the supplied specification.

### Task 1: Add repository metadata and canonical specification

**Files:**
- Create: `.gitignore`
- Create: `.dockerignore`
- Create: `.yamllint.yaml`
- Create: `LICENSE`
- Create: `SPEC.md` from `docs/spec.md`

- [ ] **Step 1: Create ignore files**

Create `.gitignore`:

```gitignore
# Credentials and local configuration
auth.json
auth.json.*
*.backup
.env

# Generated validation output
rendered.yaml

# Editors and operating systems
.DS_Store
.idea/
.vscode/
*.swp
```

Create `.dockerignore`:

```dockerignore
.git
.github
deploy
docs
scripts
*.md
LICENSE
.env
auth.json
auth.json.*
*.backup
.DS_Store
```

- [ ] **Step 2: Add YAML lint configuration**

Create `.yamllint.yaml`:

```yaml
---
extends: default
rules:
  line-length:
    max: 120
    level: warning
  truthy:
    allowed-values: ["true", "false", "on"]
```

- [ ] **Step 3: Add the MIT license**

Create `LICENSE`:

```text
MIT License

Copyright (c) 2026 jeduardo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 4: Copy the supplied specification without modifying it**

Run:

```bash
cp docs/spec.md SPEC.md
cmp docs/spec.md SPEC.md
```

Expected: `cmp` exits 0 with no output.

- [ ] **Step 5: Check formatting and commit**

Run:

```bash
git diff --check
```

Expected: exit 0 with no output.

Commit:

```bash
git add .gitignore .dockerignore .yamllint.yaml LICENSE SPEC.md
git commit -m "chore: initialize repository metadata"
```

### Task 2: Build the pinned non-root container image

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: Create the Dockerfile**

Create `Dockerfile`:

```dockerfile
FROM python:3.12-slim

ARG APP_VERSION=0.1.3

RUN groupadd --gid 10001 codex \
    && useradd --uid 10001 --gid codex --create-home --home-dir /home/codex codex \
    && pip install --no-cache-dir "openai-api-server-via-codex==${APP_VERSION}"

USER 10001:10001
WORKDIR /home/codex

EXPOSE 18080

ENTRYPOINT ["openai-api-server-via-codex"]
CMD ["--host", "0.0.0.0", "--port", "18080"]
```

- [ ] **Step 2: Run Dockerfile lint when Hadolint is available**

Run:

```bash
if command -v hadolint >/dev/null 2>&1; then hadolint Dockerfile; fi
```

Expected: no lint errors, or no output when Hadolint is unavailable.

- [ ] **Step 3: Optionally smoke-build the image when Docker is available**

Run:

```bash
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker build -t openai-codex-proxy-k8s:dev .
  docker inspect --format '{{.Config.User}}' openai-codex-proxy-k8s:dev
fi
```

Expected when Docker is available: build succeeds and inspect prints `10001:10001`.

- [ ] **Step 4: Commit the image**

```bash
git add Dockerfile
git commit -m "feat: add pinned non-root proxy image"
```

### Task 3: Add the Kustomize base and Secret examples

**Files:**
- Create: `deploy/base/namespace.yaml`
- Create: `deploy/base/pvc.yaml`
- Create: `deploy/base/deployment.yaml`
- Create: `deploy/base/service.yaml`
- Create: `deploy/base/network-policy.yaml`
- Create: `deploy/base/kustomization.yaml`
- Create: `deploy/examples/bootstrap-secret.example.yaml`
- Create: `deploy/examples/proxy-api-key.example.yaml`

- [ ] **Step 1: Create namespace and PVC resources**

Create `deploy/base/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ai
```

Create `deploy/base/pvc.yaml`:

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: codex-auth
  namespace: ai
  labels:
    app.kubernetes.io/name: openai-codex-proxy
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 32Mi
```

- [ ] **Step 2: Create the Deployment**

Create `deploy/base/deployment.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openai-codex-proxy
  namespace: ai
  labels:
    app.kubernetes.io/name: openai-codex-proxy
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: openai-codex-proxy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: openai-codex-proxy
    spec:
      automountServiceAccountToken: false
      securityContext:
        fsGroup: 10001
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: bootstrap-auth
          image: busybox:1.36.1
          command:
            - /bin/sh
            - -c
            - |
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
          securityContext:
            runAsNonRoot: false
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
              add:
                - CHOWN
          volumeMounts:
            - name: auth-data
              mountPath: /data
            - name: auth-bootstrap
              mountPath: /bootstrap
              readOnly: true
      containers:
        - name: proxy
          image: ghcr.io/jeduardo/openai-codex-proxy-k8s:main
          imagePullPolicy: IfNotPresent
          env:
            - name: OPENAI_VIA_CODEX_AUTH_JSON
              value: /var/lib/codex/auth.json
            - name: OPENAI_VIA_CODEX_API_KEY
              valueFrom:
                secretKeyRef:
                  name: codex-proxy-api-key
                  key: api-key
          ports:
            - name: http
              containerPort: 18080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: auth-data
              mountPath: /var/lib/codex
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: auth-data
          persistentVolumeClaim:
            claimName: codex-auth
        - name: auth-bootstrap
          secret:
            secretName: codex-auth-bootstrap
            optional: true
        - name: tmp
          emptyDir: {}
```

The init container is the sole root process and receives only `CHOWN`, which is required to repair ownership on restored volumes. The application drops every capability.

- [ ] **Step 3: Create the private Service**

Create `deploy/base/service.yaml`:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: openai-codex-proxy
  namespace: ai
  labels:
    app.kubernetes.io/name: openai-codex-proxy
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: openai-codex-proxy
  ports:
    - name: http
      port: 18080
      targetPort: http
      protocol: TCP
```

- [ ] **Step 4: Create the NetworkPolicy**

Create `deploy/base/network-policy.yaml`:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: openai-codex-proxy
  namespace: ai
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: openai-codex-proxy
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              openai-codex-proxy-client: "true"
      ports:
        - protocol: TCP
          port: 18080
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
        - ipBlock:
            cidr: ::/0
      ports:
        - protocol: TCP
          port: 443
```

- [ ] **Step 5: Create the Kustomization**

Create `deploy/base/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - network-policy.yaml
images:
  - name: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newTag: main
```

- [ ] **Step 6: Create placeholder-only Secret examples**

Create `deploy/examples/bootstrap-secret.example.yaml`:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: codex-auth-bootstrap
  namespace: ai
type: Opaque
stringData:
  auth.json: |
    {"auth_mode":"chatgpt","replace":"with a real local auth.json"}
```

Create `deploy/examples/proxy-api-key.example.yaml`:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: codex-proxy-api-key
  namespace: ai
type: Opaque
stringData:
  api-key: replace-with-a-cryptographically-random-value
```

- [ ] **Step 7: Render and inspect the base**

Run:

```bash
kubectl kustomize deploy/base > /tmp/openai-codex-proxy-rendered.yaml
grep -E '^kind: (Namespace|PersistentVolumeClaim|Deployment|Service|NetworkPolicy)$' \
  /tmp/openai-codex-proxy-rendered.yaml
```

Expected: one line for each of the five resource kinds.

- [ ] **Step 8: Commit the Kubernetes package**

```bash
git add deploy
git commit -m "feat: add secure Kustomize deployment"
```

### Task 4: Add credential and validation helper scripts

**Files:**
- Create: `scripts/bootstrap-auth-secret.sh`
- Create: `scripts/generate-api-key.sh`
- Create: `scripts/verify.sh`

- [ ] **Step 1: Create the bootstrap credential helper**

Create `scripts/bootstrap-auth-secret.sh`:

```sh
#!/bin/sh
set -eu

namespace=ai
auth_file=${HOME:-}/.codex/auth.json

usage() {
  echo "Usage: $0 [--namespace NAME] [--file PATH]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --namespace)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      namespace=$2
      shift 2
      ;;
    --file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      auth_file=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[ -n "$auth_file" ] && [ -f "$auth_file" ] || {
  echo "Codex auth file not found: $auth_file" >&2
  exit 1
}

jq -e . "$auth_file" >/dev/null 2>&1 || {
  echo "Codex auth file is not valid JSON: $auth_file" >&2
  exit 1
}

auth_mode=$(jq -r '.auth_mode // empty' "$auth_file")
if [ -n "$auth_mode" ] && [ "$auth_mode" != chatgpt ]; then
  echo "Codex auth_mode must be chatgpt when present" >&2
  exit 1
fi

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$namespace" create secret generic codex-auth-bootstrap \
  --from-file="auth.json=$auth_file" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Updated Secret codex-auth-bootstrap in namespace $namespace"
```

- [ ] **Step 2: Create the API-key helper**

Create `scripts/generate-api-key.sh`:

```sh
#!/bin/sh
set -eu

namespace=ai
print_key=false

usage() {
  echo "Usage: $0 [--namespace NAME] [--print]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --namespace)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      namespace=$2
      shift 2
      ;;
    --print)
      print_key=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

api_key=$(openssl rand -hex 32)
kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$namespace" create secret generic codex-proxy-api-key \
  --from-literal="api-key=$api_key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Updated Secret codex-proxy-api-key in namespace $namespace"
if [ "$print_key" = true ]; then
  printf '%s\n' "$api_key"
else
  echo "Key value hidden; use --print only when you need to capture it"
fi
```

- [ ] **Step 3: Create the local verification helper**

Create `scripts/verify.sh`:

```sh
#!/bin/sh
set -eu

build=false
case "${1:-}" in
  "") ;;
  --build) build=true ;;
  -h|--help)
    echo "Usage: $0 [--build]"
    exit 0
    ;;
  *)
    echo "Usage: $0 [--build]" >&2
    exit 2
    ;;
esac

for tool in kubectl kubeconform yamllint shellcheck hadolint; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required" >&2
    exit 1
  }
done

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT HUP INT TERM

yamllint .github deploy .yamllint.yaml
kubectl kustomize deploy/base > "$rendered"
kubeconform -strict -summary "$rendered"
shellcheck scripts/*.sh
hadolint Dockerfile

if [ "$build" = true ]; then
  command -v docker >/dev/null 2>&1 || { echo "docker is required for --build" >&2; exit 1; }
  docker build -t openai-codex-proxy-k8s:verify .
fi

echo "Verification passed"
```

- [ ] **Step 4: Make scripts executable and run syntax checks**

Run:

```bash
chmod +x scripts/*.sh
sh -n scripts/*.sh
if command -v shellcheck >/dev/null 2>&1; then shellcheck scripts/*.sh; fi
```

Expected: no syntax or lint errors.

- [ ] **Step 5: Commit the helpers**

```bash
git add scripts
git commit -m "feat: add credential and validation helpers"
```

### Task 5: Add validation and multi-architecture build workflows

**Files:**
- Create: `.github/workflows/validate.yaml`
- Create: `.github/workflows/build.yaml`

- [ ] **Step 1: Create the validation workflow**

Create `.github/workflows/validate.yaml`:

```yaml
---
name: Validate

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up kubectl
        uses: azure/setup-kubectl@v4
        with:
          version: v1.31.4

      - name: Install validation tools
        run: |
          python -m pip install --disable-pip-version-check yamllint==1.35.1
          curl -fsSLo /tmp/kubeconform.tar.gz \
            https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz
          tar -xzf /tmp/kubeconform.tar.gz -C /usr/local/bin kubeconform
          curl -fsSLo /usr/local/bin/hadolint \
            https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64
          chmod +x /usr/local/bin/hadolint

      - name: Verify repository
        run: ./scripts/verify.sh
```

- [ ] **Step 2: Create the Buildx workflow**

Create `.github/workflows/build.yaml`:

```yaml
---
name: Build image

on:
  push:
    branches:
      - main
    tags:
      - "v*.*.*"
  pull_request:

permissions:
  contents: read
  packages: write
  id-token: write

env:
  IMAGE_NAME: ghcr.io/jeduardo/openai-codex-proxy-k8s

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Generate image metadata
        id: metadata
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=main,enable={{is_default_branch}}
            type=semver,pattern={{version}}
            type=sha,prefix=sha-

      - name: Build and conditionally push
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.metadata.outputs.tags }}
          labels: ${{ steps.metadata.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: mode=max
```

- [ ] **Step 3: Lint workflow YAML**

Run:

```bash
yamllint .github .yamllint.yaml
```

Expected: exit 0; line-length warnings are acceptable but errors are not.

- [ ] **Step 4: Commit CI**

```bash
git add .github
git commit -m "ci: validate and build multi-platform images"
```

### Task 6: Write user and security documentation

**Files:**
- Create: `README.md`
- Create: `SECURITY.md`

- [ ] **Step 1: Create the README**

Create `README.md` with the following exact section structure and commands:

```markdown
# OpenAI Codex Proxy for Kubernetes

This repository packages
[`openai-api-server-via-codex`](https://github.com/hotchpotch/openai-api-server-via-codex)
as a private, single-replica Kubernetes service. A bootstrap Secret seeds Codex
OAuth credentials into a writable PVC, where the proxy can refresh them safely.

> [!WARNING]
> This is not the official OpenAI Platform API. It depends on an unofficial or
> semi-official Codex backend interface that may change without notice. Do not
> expose this service to untrusted networks, commit credentials, share account
> credentials, or run more than one replica.

## How it works

The init container copies `codex-auth-bootstrap/auth.json` to the `codex-auth`
PVC only when the PVC has no non-empty credential file. The application uses
`/var/lib/codex/auth.json` on that PVC and may atomically replace it during token
refresh. After first refresh, the PVC is authoritative; the Secret may contain
an obsolete refresh token.

A different Secret, `codex-proxy-api-key`, protects the HTTP API. Its value is
not a Codex or OpenAI OAuth token.

## Prerequisites

- Kubernetes with a default StorageClass (k3s `local-path` works)
- `kubectl` with Kustomize support
- Docker or another BuildKit client when building locally
- `jq` and `openssl` for helper scripts
- a trusted workstation with a working Codex login

Kubernetes Secrets are base64-encoded, not inherently encrypted. Enable
Kubernetes encryption at rest, encrypted datastore backups, restrictive RBAC,
and namespace access controls.

## Build the image

The upstream version defaults to `0.1.3` and remains explicit:

```bash
docker build \
  --build-arg APP_VERSION=0.1.3 \
  -t ghcr.io/jeduardo/openai-codex-proxy-k8s:dev .
```

The published workflow builds `linux/amd64` and `linux/arm64`. Prefer immutable
semantic-version or `sha-*` tags in production instead of `main`.

## Authenticate and create Secrets

Authenticate with Codex interactively on a trusted workstation. The resulting
file is normally `$HOME/.codex/auth.json`. Never perform or automate this login
inside the cluster.

Create or replace the bootstrap Secret:

```bash
./scripts/bootstrap-auth-secret.sh \
  --namespace ai \
  --file "$HOME/.codex/auth.json"
```

Create or replace the independent proxy API key:

```bash
./scripts/generate-api-key.sh --namespace ai
```

The key is hidden by default. Use `--print` only when you need to capture it in
a secure shell session:

```bash
umask 077
./scripts/generate-api-key.sh --namespace ai --print > proxy-api-key.txt
```

The example Secret YAML files contain unusable placeholders and must not be
applied unchanged.

## Deploy

Optionally edit `deploy/base/kustomization.yaml` to select an immutable image:

```yaml
images:
  - name: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newTag: "0.1.0"
```

Deploy:

```bash
kubectl apply -k deploy/base
kubectl -n ai rollout status deploy/openai-codex-proxy
```

The base does not set a StorageClass. For k3s, add
`storageClassName: local-path` with a Kustomize patch only if `local-path` is not
the cluster default. Add application arguments through a Kustomize Deployment
patch rather than forking the base.

Resource requests and limits are starting points, not performance guarantees.

## Network access

The Service is a private `ClusterIP`; no Ingress, NodePort, or LoadBalancer is
included. NetworkPolicy allows port 18080 only from pods carrying:

```yaml
metadata:
  labels:
    openai-codex-proxy-client: "true"
```

It permits cluster DNS and general TCP/443 egress. Standard Kubernetes
NetworkPolicy cannot select OpenAI hostnames and IP ranges can change. Tighter
alternatives are an HTTP egress proxy, an FQDN-aware CNI, or externally managed
IP allowlists. Your CNI must enforce NetworkPolicy; some clusters do not.

## Check health

Start a labelled temporary client:

```bash
kubectl -n ai run codex-client --rm -it --restart=Never \
  --labels=openai-codex-proxy-client=true \
  --image=curlimages/curl -- \
  curl --fail http://openai-codex-proxy:18080/healthz
```

## Call the API

Inside an allowed pod, use:

```bash
export OPENAI_BASE_URL=http://openai-codex-proxy.ai.svc.cluster.local:18080/v1
export OPENAI_API_KEY='<proxy-api-key>'
curl --fail-with-body \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  "$OPENAI_BASE_URL/models"
```

Python clients can use the same values:

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

Manually verify both streaming and non-streaming Responses calls after every
upstream upgrade. Requests with a missing or incorrect proxy key must fail.

## Upgrade

1. Change `APP_VERSION` deliberately and build the image.
2. Run `./scripts/verify.sh --build`.
3. Test authentication, a normal response, and a streaming response.
4. Set an immutable image tag in Kustomize and apply the base.
5. Confirm the `Recreate` rollout and inspect logs for authentication errors.
6. Restart once more and verify requests still work, proving PVC persistence.

Never scale above one replica or change the strategy from `Recreate`. Do not
delete the PVC during routine upgrades. The old bootstrap Secret must never
overwrite the live file.

## Back up credentials

Prefer encrypted volume snapshots or an encrypted Kubernetes backup system.
The backup grants account access and must be treated as highly sensitive.

For an emergency manual backup:

```bash
umask 077
kubectl -n ai exec deploy/openai-codex-proxy -- \
  cat /var/lib/codex/auth.json > auth.json.backup
```

Encrypt or securely delete the resulting file immediately. Do not commit it.
Automatic synchronization to a Kubernetes Secret is intentionally excluded
because it requires API write access and introduces races and broader impact.

## Recover expired credentials

If token refresh is permanently rejected:

1. Perform a new Codex login on a trusted workstation.
2. Replace the bootstrap Secret with `bootstrap-auth-secret.sh`.
3. Remove the invalid live copy while the current pod still owns the file:

   ```bash
   kubectl -n ai exec deploy/openai-codex-proxy -- \
     rm /var/lib/codex/auth.json
   kubectl -n ai rollout restart deploy/openai-codex-proxy
   ```

The replacement pod copies the new Secret. If the PVC was lost, restore an
encrypted backup or reauthenticate; the original bootstrap Secret may no longer
work after refresh-token rotation.

## Troubleshooting

- **`No persisted auth.json or bootstrap credential found`:** create the
  bootstrap Secret and restart the Deployment.
- **CrashLoopBackOff after authentication errors:** recreate credentials and
  follow the recovery procedure. Never paste full auth JSON into logs or issues.
- **Read-only filesystem:** confirm `OPENAI_VIA_CODEX_AUTH_JSON` points to the
  writable PVC path, not the Secret mount.
- **Permission denied:** inspect init-container logs and verify UID/GID 10001,
  `fsGroup: 10001`, and mode 0600.
- **Intermittent invalid credentials:** confirm one replica and `Recreate`.
- **Network timeout:** verify the CNI policy, DNS pod labels, and HTTPS egress.
- **PVC Pending:** select a valid cluster StorageClass using an overlay.

Inspect logs without copying credentials:

```bash
kubectl -n ai logs deploy/openai-codex-proxy -c bootstrap-auth
kubectl -n ai logs deploy/openai-codex-proxy -c proxy
```

Logs must never contain access, refresh, or ID tokens; proxy keys; full auth
JSON; or Authorization headers.

## Remove

To preserve credentials, remove only workload networking resources:

```bash
kubectl -n ai delete deployment openai-codex-proxy
kubectl -n ai delete service openai-codex-proxy
kubectl -n ai delete networkpolicy openai-codex-proxy
```

A full base removal includes the `ai` Namespace and therefore destroys the PVC
and Secrets in that namespace:

```bash
kubectl delete -k deploy/base
```

For explicit credential deletion when the namespace remains:

```bash
kubectl -n ai delete pvc codex-auth
kubectl -n ai delete secret codex-auth-bootstrap codex-proxy-api-key
```

Deleting the PVC permanently removes the latest refreshed credential state.
```

- [ ] **Step 2: Create the security policy**

Create `SECURITY.md`:

```markdown
# Security Policy

## Support status

This experimental project is not an official OpenAI product and provides no
compatibility or availability guarantee. The upstream Codex interface can
change without notice.

## Reporting a vulnerability

Do not open a public issue containing credentials, Authorization headers,
private endpoint details, or exploit instructions. Use GitHub's private
security-advisory reporting for this repository. Revoke exposed proxy keys and
reauthenticate Codex immediately if OAuth material may have leaked.

## Threat model

The proxy holds credentials capable of accessing a Codex/ChatGPT account. A
compromised pod, node, volume backup, Secret reader, or allowed client can cause
account misuse. The base reduces exposure but does not defend a compromised
cluster administrator or node.

## Required operator controls

- Keep the Service cluster-private and allow only trusted labelled clients.
- Run one replica with `Recreate`; concurrent refresh can invalidate tokens.
- Enable Secret encryption at rest and encrypted etcd/datastore backups.
- Restrict RBAC and namespace access.
- Encrypt PVC snapshots and manual credential backups.
- Rotate the proxy key and reauthenticate Codex after suspected exposure.
- Verify that the cluster CNI enforces NetworkPolicy.
- Review pinned upstream dependency changes before upgrading.

The application runs as UID/GID 10001 with no capabilities, no privilege
escalation, a read-only root filesystem, and no service-account token. The init
container runs briefly as root with only `CHOWN` so it can secure restored PVC
files; it cannot modify the read-only bootstrap Secret.

Never include tokens in source, image layers, command arguments, logs, CI
artifacts, screenshots, or support reports.
```

- [ ] **Step 3: Check documentation and commit**

Run:

```bash
git diff --check README.md SECURITY.md
```

Expected: exit 0 with no output.

Commit:

```bash
git add README.md SECURITY.md
git commit -m "docs: add deployment and security guides"
```

### Task 7: Run final static verification

**Files:**
- Modify only files that fail a check, preserving the approved design.

- [ ] **Step 1: Verify no credential-shaped files are tracked**

Run:

```bash
git ls-files | grep -E '(^|/)(auth\.json|.*\.backup)$' && exit 1 || true
grep -RIl 'replace-with-a-cryptographically-random-value' deploy/examples
```

Expected: the first command emits nothing; the second lists only `deploy/examples/proxy-api-key.example.yaml`.

- [ ] **Step 2: Run repository verification**

Run:

```bash
./scripts/verify.sh
```

Expected: YAML linting, Kustomize rendering, kubeconform, ShellCheck, and Hadolint all pass, ending with `Verification passed`.

If a required local tool is unavailable, install the pinned versions from `.github/workflows/validate.yaml`, then rerun rather than claiming success without evidence.

- [ ] **Step 3: Build locally when Docker is available**

Run:

```bash
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ./scripts/verify.sh --build
else
  echo "Docker unavailable; multi-platform build remains covered by GitHub Actions"
fi
```

Expected: verification and image build pass, or the explicit Docker-unavailable message is printed.

- [ ] **Step 4: Inspect rendered mandatory controls**

Run:

```bash
kubectl kustomize deploy/base > /tmp/openai-codex-proxy-rendered.yaml
grep -nE 'replicas: 1|type: Recreate|automountServiceAccountToken: false|readOnlyRootFilesystem: true|runAsUser: 10001|type: ClusterIP|optional: true' \
  /tmp/openai-codex-proxy-rendered.yaml
```

Expected: all listed controls appear; `readOnlyRootFilesystem: true` appears for both init and application containers.

- [ ] **Step 5: Check the working tree and commit any verification fixes**

Run:

```bash
git diff --check
git status --short
```

Expected: no formatting errors. If verification required fixes, commit them:

```bash
git add -A
git commit -m "fix: satisfy repository validation"
```

If there were no fixes, do not create an empty commit.
