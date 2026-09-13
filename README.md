# Codex Proxy Helm Chart

This Helm chart runs the upstream [`openai-api-server-via-codex`](https://github.com/hotchpotch/openai-api-server-via-codex) image in Kubernetes. It gives you an OpenAI-compatible API backed by your Codex login.

The upstream service is unofficial. Keep it on a trusted network, run one replica with `Recreate`, and never commit your credentials or rendered Secrets. The chart and this repository are released under the MIT license; the upstream service has its own license and terms.

AI tools are used to help with development. The project’s architecture, design decisions, and tests are human-driven and reviewed by the maintainer.

## Prepare secrets

First, create a Secret with your Codex `auth.json`:

```bash
kubectl create namespace ai --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ai create secret generic codex-auth-bootstrap --from-file=auth.json="$HOME/.codex/auth.json"
```

The chart copies that file to a writable PVC. The proxy can then refresh it in place. Do not print the Secret or commit it to Git.

## Install

Install the chart in the namespace you want. The examples use `ai`; change the `--namespace` value for another namespace. The chart generates and preserves the proxy API key unless you set `apiKey.existingSecret`.

```bash
helm upgrade --install codex-proxy \
  oci://ghcr.io/jeduardo/codex-proxy \
  --version 0.2.0 \
  --namespace ai \
  --create-namespace
```

For a Gateway API route, supply cluster-specific values in a private values file:

```yaml
route:
  enabled: true
  hostname: proxy.example.internal
  gateway:
    name: internal-gateway
    namespace: network-system
    sectionName: https
networkPolicy:
  gateway:
    enabled: true
    namespace: network-system
    podSelector:
      matchLabels:
        app.kubernetes.io/name: gateway-controller
```

Apply it with:

```bash
helm upgrade --install codex-proxy ./charts/codex-proxy --namespace ai --values private-values.yaml
kubectl -n ai rollout status deployment/codex-proxy
```

Keep cluster-specific hostnames and gateway names in a private values file. If the cluster uses a conventional Ingress controller, enable it like this:

```yaml
ingress:
  enabled: true
  className: nginx
  hostname: proxy.example.internal
  tls:
    - hosts: [proxy.example.internal]
      secretName: proxy-example-tls
```

Both containers run as UID/GID 1000. Choose a StorageClass that supports the pod `fsGroup` setting.

## Use the API

Inside the cluster, use `http://codex-proxy.ai.svc.cluster.local:18080/v1` (change `ai` if you chose another namespace). Outside the cluster, use the hostname from your values file. Send the API key as `Authorization: Bearer ...`; in-cluster clients also need the label configured by `networkPolicy.clientLabel`.

When the chart generated the key, load it into your shell like this:

```bash
export OPENAI_API_KEY="$(kubectl -n ai get secret codex-proxy-api-key -o jsonpath='{.data.api-key}' | base64 -d)"
```

If you set `apiKey.existingSecret`, use that Secret name instead.

```bash
curl https://proxy.example.internal/v1/models -H "Authorization: Bearer $OPENAI_API_KEY"
```

Send an inference request through the proxy:

```bash
curl https://proxy.example.internal/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-5.5",
    "messages": [
      {"role": "user", "content": "Tell me a haiku about DNS."}
    ]
  }'
```

## Operations

Keep one replica and `Recreate`. Do not attach an HPA or delete the PVC during a normal upgrade. If the refresh token is revoked, log in again, replace the bootstrap Secret, remove the stale `auth.json` from the PVC with a temporary non-root pod, and restart the Deployment.

Back up the PVC only with encrypted storage and restricted access. It contains the live account credential. See [docs/SECURITY.md](docs/SECURITY.md) and the upstream [Docker documentation](https://github.com/hotchpotch/openai-api-server-via-codex/blob/main/docs/docker.md) for more detail.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the resources the chart creates and how credentials move through the deployment.

See [docs/CI.md](docs/CI.md) for validation, Renovate, and workflow cleanup. See [docs/RELEASING.md](docs/RELEASING.md) for chart versioning and the OCI release process.

## Validate

```bash
helm lint charts/codex-proxy
helm template codex-proxy charts/codex-proxy
```

Renovate checks the upstream image daily and opens a pull request when a new tag is available. It updates the image tag and chart `appVersion` together. The scheduled workflow uses the repository `GITHUB_TOKEN`; enable GitHub's setting that allows Actions to create and approve pull requests if Renovate is not allowed to open one.

Patch-only upstream updates are configured for auto-merge after required checks pass. Minor and major updates remain manual.

A second scheduled workflow keeps the five newest runs for each workflow and removes older runs to limit Actions storage. Both scheduled jobs can also be started manually from the Actions tab.
