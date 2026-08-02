# OpenAI Codex Proxy for Kubernetes

> [!CAUTION]
> **Unofficial, experimental, and private-only.** This project is not the official OpenAI Platform API and is not supported or endorsed by OpenAI. It packages an upstream proxy that depends on an unofficial or semi-official Codex/ChatGPT backend interface; that interface can change or stop working without notice. Never expose this service to the public Internet or another untrusted network. Never share or commit Codex credentials, refresh tokens, proxy API keys, backups, or rendered Secrets.
>
> **Run exactly one replica with the `Recreate` strategy.** Multiple replicas or rolling-update overlap can race during OAuth refresh-token rotation and invalidate the account credentials. Do not change `replicas: 1` or `strategy.type: Recreate`.

This repository packages [`hotchpotch/openai-api-server-via-codex`](https://github.com/hotchpotch/openai-api-server-via-codex) as a private Kubernetes `ClusterIP` service. It presents an OpenAI-compatible `/v1` API backed by one interactive Codex/ChatGPT login.

## How it works

1. A trusted workstation performs the interactive Codex login and creates `$HOME/.codex/auth.json`.
2. `codex-auth-bootstrap` supplies that file to an init container as a read-only bootstrap Secret.
3. The init container copies it only when the `codex-auth` PVC has no live `auth.json`, then sets mode `0600` and ownership `10001:10001`.
4. The non-root proxy reads and atomically refreshes `/var/lib/codex/auth.json` on the writable PVC.
5. A separate `codex-proxy-api-key` Secret authenticates callers to the proxy.

The bootstrap Secret is not the authoritative credential after the first refresh. The PVC may contain a newer rotated refresh token, and restarts deliberately do not overwrite it with the original Secret.

The application runs as UID/GID `10001`, with all capabilities dropped, privilege escalation disabled, a read-only root filesystem, no service-account token, and a writable `/tmp`. The narrowly scoped init-container exception is documented in [SECURITY.md](SECURITY.md).

## Prerequisites

- A private Kubernetes cluster and permission to create a namespace, Secrets, a PVC, a Deployment, a Service, and a NetworkPolicy.
- `kubectl` with Kustomize support and a context pointing at the intended cluster.
- A default StorageClass, or an overlay selecting one. k3s normally uses `local-path`; see [Storage on k3s](#storage-on-k3s).
- A CNI that enforces Kubernetes NetworkPolicy. A NetworkPolicy object alone provides no isolation if the CNI does not enforce it.
- The Codex client on a trusted workstation, with an eligible account and a successful interactive login.
- `jq` for `bootstrap-auth-secret.sh`, and `openssl` for `generate-api-key.sh`.
- Docker/BuildKit to build locally. An `openai` Python package is needed only for the Python client example.
- Optional: an encrypted snapshot/backup system or `age` for the manual encrypted backup example.

Review [SECURITY.md](SECURITY.md), enable Kubernetes Secret encryption at rest, and arrange encrypted datastore/etcd backups before adding credentials.

## Build the image

The upstream package is pinned by `APP_VERSION` (default `0.1.3`):

```bash
APP_VERSION=0.1.3
docker build \
  --build-arg APP_VERSION="$APP_VERSION" \
  --tag "openai-codex-proxy-k8s:${APP_VERSION}" \
  .
```

For a multi-architecture registry build:

```bash
APP_VERSION=0.1.3
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg APP_VERSION="$APP_VERSION" \
  --tag "REGISTRY/OWNER/openai-codex-proxy-k8s:${APP_VERSION}" \
  --push .
```

Use a registry the cluster can pull from, or import the local image into every node that might run the pod. Never add `auth.json`, API keys, or other credentials to the build context or image.

## Authenticate and create Secrets

### 1. Log in on a trusted workstation

Do not perform the interactive login in the cluster. On a trusted, patched workstation, use the current Codex client's login flow (for current CLI releases, typically `codex login`) and verify that it created:

```text
$HOME/.codex/auth.json
```

Treat this file as an account credential. Do not inspect it in shared terminals, paste it into chat or tickets, copy it through an untrusted host, or commit it.

### 2. Create the bootstrap Secret

The helper validates JSON, checks `auth_mode` when present, and creates or replaces the Secret without printing tokens:

```bash
./scripts/bootstrap-auth-secret.sh \
  --namespace ai \
  --file "$HOME/.codex/auth.json"
```

Updating this Secret does **not** replace an existing PVC copy. That safety property prevents an old bootstrap token from overwriting refreshed credentials. Use the recovery procedure when the live credential must be replaced.

### 3. Generate the proxy API key

Create the incoming bearer-token Secret without displaying the key:

```bash
./scripts/generate-api-key.sh --namespace ai
```

If a client configuration needs the generated value, explicitly request it and capture stdout in a mode-`0600` file; status text goes to stderr:

```bash
umask 077
api_key_file=$(mktemp "${TMPDIR:-/tmp}/codex-proxy-api-key.XXXXXX")
./scripts/generate-api-key.sh --namespace ai --print >"$api_key_file"
# Read from "$api_key_file" only into the intended secret manager/client config.
# Securely remove it as soon as that transfer is complete.
```

Prefer mounting `codex-proxy-api-key` into in-cluster clients with `secretKeyRef` instead of making extra copies. The proxy key is not an OpenAI or Codex OAuth token; it only authenticates requests to this proxy.

> [!WARNING]
> Kubernetes Secrets are base64-encoded, not inherently encrypted. Enable API-server encryption at rest, encrypt etcd/datastore backups, restrict RBAC and namespace access, and protect cluster-admin and node access. Anyone who can read these Secrets or the PVC can obtain sensitive credentials.

The files under `deploy/examples/` are documentation-only placeholders. Their resource names end in `-example`, so they do not satisfy the Deployment's required runtime Secret names. **Do not apply them as runtime credentials and never replace their placeholders with real secrets in the repository.**

## Deploy with an immutable image

The checked-in base uses the mutable `main` tag for development. Production deployments should create a cluster-local overlay that selects an immutable semantic version or, preferably, a Git SHA tag:

```bash
mkdir -p deploy/overlays/private
cat > deploy/overlays/private/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
images:
  - name: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newName: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newTag: sha-REPLACE_WITH_COMMIT_SHA
EOF

kubectl kustomize deploy/overlays/private >/dev/null
kubectl apply -k deploy/overlays/private
kubectl -n ai rollout status deployment/openai-codex-proxy
```

Replace the placeholder tag with a published immutable tag. If using another registry or a locally loaded image, change `newName` and `newTag`. Keep private overlay values under appropriate configuration control.

The base can be applied directly for evaluation with `kubectl apply -k deploy/base`, but that deploys `:main` and is not the recommended immutable production workflow. Resource requests and limits are starting points, not performance guarantees.

### Storage on k3s

The base intentionally does not hard-code a StorageClass. If k3s has no default class, add this patch to the overlay:

```yaml
patches:
  - target:
      kind: PersistentVolumeClaim
      name: codex-auth
    patch: |-
      - op: add
        path: /spec/storageClassName
        value: local-path
```

Confirm the class name with `kubectl get storageclass`; use the actual class for the cluster. A node-local `local-path` volume also makes node loss and encrypted off-node backup planning especially important.

## Network access

The Service is `ClusterIP` only; no Ingress, NodePort, or LoadBalancer is installed. The base NetworkPolicy permits port `18080` only from pods carrying:

```yaml
openai-codex-proxy-client: "true"
```

A label is only a useful boundary when untrusted users cannot label pods or modify policy. Restrict those Kubernetes permissions and still require the proxy API key.

The policy allows DNS to pods selected as `k8s-app=kube-dns` in `kube-system`. DNS labels vary among distributions. If the cluster uses different CoreDNS/kube-dns labels or NodeLocal DNS, add a cluster-specific overlay before deployment. Test DNS from the proxy and do not broadly disable egress merely to hide a selector mismatch.

Standard Kubernetes NetworkPolicy cannot allow egress by FQDN. The base therefore allows general TCP/443 egress because OpenAI/ChatGPT endpoint addresses can change. Operators that require tighter egress should choose one of these approaches:

1. route HTTPS through a controlled egress/HTTP proxy;
2. use a CNI with FQDN-aware egress policies;
3. maintain reviewed destination IP ranges externally; or
4. accept general TCP/443 egress from this workload/namespace.

Ensure the selected CNI enforces both ingress and egress policy. Do not expose the Service to untrusted networks.

## Health check from a labelled pod

An unlabelled pod should be denied by an enforcing CNI. Test the local health endpoint from a labelled, temporary curl pod:

```bash
kubectl -n ai run codex-health-check \
  --rm --attach=true --restart=Never \
  --image=curlimages/curl:8.12.1 \
  --labels='openai-codex-proxy-client=true' \
  --command -- \
  curl -fsS http://openai-codex-proxy.ai.svc.cluster.local:18080/healthz
```

A successful `/healthz` response proves that the local server is responsive; it does not prove that Codex authentication or upstream availability works.

## Use the API in cluster

The in-cluster base URL is:

```text
http://openai-codex-proxy.ai.svc.cluster.local:18080/v1
```

Client pods must carry the NetworkPolicy label and should receive the proxy key directly from its Secret:

```yaml
metadata:
  labels:
    openai-codex-proxy-client: "true"
spec:
  containers:
    - name: client
      env:
        - name: OPENAI_BASE_URL
          value: http://openai-codex-proxy.ai.svc.cluster.local:18080/v1
        - name: OPENAI_API_KEY
          valueFrom:
            secretKeyRef:
              name: codex-proxy-api-key
              key: api-key
```

Secrets are namespace-scoped; this direct reference works for a client in `ai`. Use an approved secret-distribution method for another namespace rather than copying a value into source control.

From that labelled client container, list models:

```bash
curl -fsS \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  "${OPENAI_BASE_URL}/models"
```

### Python Responses API

Run this from a labelled in-cluster workload with `OPENAI_API_KEY` injected as above:

```python
import os
from openai import OpenAI

client = OpenAI(
    base_url="http://openai-codex-proxy.ai.svc.cluster.local:18080/v1",
    api_key=os.environ["OPENAI_API_KEY"],
)

response = client.responses.create(
    model="gpt-5.5",
    input="Return a one-sentence response.",
)

print(response.output_text)
```

Choose a model returned by `/v1/models` if the example model is unavailable upstream.

## Manual acceptance checks

Run these inside a labelled client pod with `OPENAI_BASE_URL` and `OPENAI_API_KEY` set. Do not enable shell tracing (`set -x`) or paste the key into the command text.

Non-streaming Responses request:

```bash
curl -fsS \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H 'Content-Type: application/json' \
  --data '{"model":"gpt-5.5","input":"Reply with exactly: nonstream ok"}' \
  "${OPENAI_BASE_URL}/responses"
```

Streaming Responses request (the output should arrive as a stream):

```bash
curl -NfsS \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H 'Content-Type: application/json' \
  --data '{"model":"gpt-5.5","input":"Reply with exactly: stream ok","stream":true}' \
  "${OPENAI_BASE_URL}/responses"
```

API-key rejection, intentionally omitting the authorization header:

```bash
status=$(curl -sS -o /dev/null -w '%{http_code}' "${OPENAI_BASE_URL}/models")
case "$status" in
  401|403) printf 'Unauthenticated request rejected (%s).\n' "$status" ;;
  *) printf 'Unexpected unauthenticated status: %s\n' "$status" >&2; exit 1 ;;
esac
```

Also repeat the rejection test with an intentionally wrong non-secret value. A correct key must list models, while missing and incorrect keys must be rejected.

## Upgrades and persistence test

1. Review the upstream release and update `APP_VERSION` deliberately.
2. Build and validate the new image; do not use an unbounded latest release.
3. Test authentication preflight, non-streaming, streaming, and API-key rejection.
4. Change the overlay to a new immutable image tag and review `kubectl diff -k deploy/overlays/private`.
5. Apply it and monitor the `Recreate` rollout. Do not delete the PVC during an upgrade.

```bash
kubectl apply -k deploy/overlays/private
kubectl -n ai rollout status deployment/openai-codex-proxy
kubectl -n ai logs deployment/openai-codex-proxy -c proxy --tail=100
```

Confirm that a non-empty live credential survives a restart without printing it, then repeat `/v1/models` or a Responses request from a labelled client:

```bash
kubectl -n ai exec deployment/openai-codex-proxy -c proxy -- \
  test -s /var/lib/codex/auth.json
kubectl -n ai rollout restart deployment/openai-codex-proxy
kubectl -n ai rollout status deployment/openai-codex-proxy
kubectl -n ai exec deployment/openai-codex-proxy -c proxy -- \
  test -s /var/lib/codex/auth.json
```

The Deployment must remain at one replica with `Recreate`. The init container will preserve the PVC file rather than copy the possibly stale bootstrap Secret over it.

## Backup

Prefer encrypted volume snapshots or an encrypted Kubernetes backup system with tightly restricted access. The PVC backup contains active account credentials; encrypt backups in transit and at rest, protect encryption keys separately, define retention, and test restoration privately.

A manual `age` backup can stream the live file directly into encryption without writing plaintext to disk. This command requires Bash:

```bash
umask 077
set -o pipefail
AGE_RECIPIENT='age1REPLACE_WITH_YOUR_RECIPIENT'
backup_tmp=$(mktemp "${TMPDIR:-/tmp}/auth.json.backup.age.XXXXXX")
trap 'rm -f "$backup_tmp"' EXIT

if kubectl -n ai exec deployment/openai-codex-proxy -c proxy -- \
  cat /var/lib/codex/auth.json \
  | age --recipient "$AGE_RECIPIENT" --output "$backup_tmp" \
  && test -s "$backup_tmp"; then
  chmod 600 "$backup_tmp"
  mv -- "$backup_tmp" auth.json.backup.age
  trap - EXIT
else
  echo "Backup failed; auth.json.backup.age was not replaced" >&2
  exit 1
fi
```

Use a real, verified recipient and store the decryption identity separately. Verify that the backup decrypts with the operator's identity before relying on it or deleting PVC state. Never leave an unencrypted `auth.json.backup`. Automatic synchronization of refreshed credentials back to a Secret is intentionally out of scope because it would require Kubernetes write access and create additional compromise and race risks.

## Refresh-token rotation and recovery

The OAuth provider may rotate the refresh token. **After rotation, restoring only the original bootstrap Secret may not restore access.** Preserve the PVC with encrypted backups.

If refresh is permanently rejected:

1. Perform a new interactive Codex login on a trusted workstation.
2. Replace `codex-auth-bootstrap` with the new local file.
3. Stop the Deployment so the live credential has no writer.
4. Remove only the PVC's stale `auth.json` using a one-shot, non-root pod.
5. Start the Deployment. The init container seeds the new file and fixes its ownership.

```bash
./scripts/bootstrap-auth-secret.sh \
  --namespace ai \
  --file "$HOME/.codex/auth.json"

kubectl -n ai scale deployment/openai-codex-proxy --replicas=0
kubectl -n ai wait --for=delete pod \
  -l app.kubernetes.io/name=openai-codex-proxy --timeout=120s

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: codex-auth-recovery
  namespace: ai
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: remove-stale-auth
      image: busybox:1.36.1
      command: ["/bin/sh", "-c", "rm -f /data/auth.json"]
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: auth-data
          mountPath: /data
  volumes:
    - name: auth-data
      persistentVolumeClaim:
        claimName: codex-auth
EOF
kubectl -n ai wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/codex-auth-recovery --timeout=120s
kubectl -n ai delete pod codex-auth-recovery
kubectl -n ai scale deployment/openai-codex-proxy --replicas=1
kubectl -n ai rollout status deployment/openai-codex-proxy
```

If any command fails after scale-down, inspect and delete `pod/codex-auth-recovery` as needed, and keep the proxy stopped until the PVC state is understood. After resolving the failure, explicitly restore service with `kubectl -n ai scale deployment/openai-codex-proxy --replicas=1`.

Then repeat the authenticated model and Responses checks. If the account itself may be compromised, also use the provider's account/session controls and follow the rotation response in [SECURITY.md](SECURITY.md).

## Troubleshooting

Start with metadata and bounded logs:

```bash
kubectl -n ai get pods,pvc,service,networkpolicy
kubectl -n ai describe pod -l app.kubernetes.io/name=openai-codex-proxy
kubectl -n ai logs deployment/openai-codex-proxy -c bootstrap-auth --tail=100
kubectl -n ai logs deployment/openai-codex-proxy -c proxy --tail=100
```

Do not run `kubectl get secret ... -o yaml/json`, print environment variables, `cat` the auth file, enable shell tracing, or paste unredacted output into an issue. Authorization headers, proxy keys, OAuth access/ID/refresh tokens, and full authentication JSON must never appear in logs. If diagnostic output unexpectedly contains any of them, stop sharing it, remove the exposed copy, and rotate the affected credentials.

### `No persisted auth.json or bootstrap credential found`

The init container has neither a non-empty PVC file nor a bootstrap file. Run `bootstrap-auth-secret.sh`, confirm the Secret is in namespace `ai`, and restart the Deployment. The application container correctly remains stopped until credentials exist.

### Invalid authentication JSON / `CrashLoopBackOff`

Create a fresh local login and let `bootstrap-auth-secret.sh` validate it. Inspect bounded proxy logs without displaying the Secret. If the PVC already contains invalid data, follow the recovery procedure; merely replacing the bootstrap Secret does not overwrite live PVC state.

### Refresh token rejected after access-token expiry

The bootstrap Secret may now be older than the PVC, or the session may be revoked. Perform a new trusted-workstation login, update the Secret, remove the stale PVC file, and restart as described in recovery. Restore an encrypted current PVC backup only if its token is known to remain valid.

### Read-only filesystem error while refreshing

`OPENAI_VIA_CODEX_AUTH_JSON` must be `/var/lib/codex/auth.json`, which is on the writable `codex-auth` PVC. Do not mount a projected Secret as the live file. Confirm the PVC mount is writable and that no overlay changed the path or set that volume mount read-only. The root filesystem should remain read-only.

### Permission denied reading or replacing `auth.json`

Inspect init-container logs and the pod security context. The file must be mode `0600`, UID/GID `10001`, and the pod `fsGroup` must be `10001`. Do not weaken the application container to root; correct storage ownership through the existing init behavior.

### Credentials intermittently fail during rollout

Concurrent refresh is likely. Restore `replicas: 1` and `strategy.type: Recreate`, terminate overlapping proxy pods, and recover credentials if a refresh token was invalidated. Never use an HPA or rolling update for this Deployment.

### PVC loss or older bootstrap state reappears

Restore an encrypted backup of the latest PVC. If no current backup exists, perform a new login and the recovery procedure. The original bootstrap Secret can contain a refresh token that became invalid after rotation.

### PVC remains `Pending`

Check `kubectl -n ai describe pvc codex-auth` and available StorageClasses. Provide a cluster-specific overlay; on standard k3s this is commonly `local-path`. Do not delete a credential-bearing bound PVC merely to change scheduling without first making and verifying an encrypted backup.

### Health/DNS/HTTPS connectivity fails

Confirm the client has `openai-codex-proxy-client=true`, the CNI enforces NetworkPolicy, the Service endpoints exist, and the cluster DNS pod labels match the policy. Add a DNS selector overlay when required. For upstream HTTPS, use one of the documented egress alternatives; standard NetworkPolicy cannot select OpenAI endpoints by hostname.

## Safe removal

To remove only the running proxy while preserving credentials, delete the workload and network resources by name:

```bash
kubectl -n ai delete deployment openai-codex-proxy
kubectl -n ai delete service openai-codex-proxy
kubectl -n ai delete networkpolicy openai-codex-proxy
```

This intentionally leaves the `ai` Namespace, `codex-auth` PVC, and both runtime Secrets.

> [!DANGER]
> **Do not use `kubectl delete -k deploy/base` when you intend to preserve credentials.** The base includes the Namespace, PVC, and workload resources. Deleting it can delete `codex-auth`, both Secrets through Namespace cascading deletion, and any unrelated resources that also live in the shared `ai` namespace. It can therefore destroy the newest rotated credential state and unrelated `ai` workloads.

When credential destruction is explicitly intended and verified backups have also been handled, delete it separately:

```bash
kubectl -n ai delete pvc codex-auth
kubectl -n ai delete secret codex-auth-bootstrap
kubectl -n ai delete secret codex-proxy-api-key
```

Deleting Kubernetes objects may not erase storage snapshots, datastore backups, exported client configuration, local auth files, or provider-side sessions. Remove retained copies according to policy and revoke/rotate provider credentials when required. Delete the `ai` namespace only after confirming it contains no unrelated resources.

## Repository validation

With `kubectl`, `kubeconform`, `yamllint`, `shellcheck`, and `hadolint` installed:

```bash
./scripts/verify.sh
```

Add `--build` to include a local Docker build. See [SECURITY.md](SECURITY.md) for the threat model, mandatory operator controls, and vulnerability reporting process.
