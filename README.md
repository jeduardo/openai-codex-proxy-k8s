# Codex Proxy Helm Chart

This chart deploys the upstream [`openai-api-server-via-codex`](https://github.com/hotchpotch/openai-api-server-via-codex) image as a private Kubernetes service with a writable persistent Codex credential, bearer-key authentication, NetworkPolicy, and optional Gateway API HTTPRoute.

The upstream service is unofficial and uses a ChatGPT/Codex login. Keep it on a trusted network, use exactly one replica with `Recreate`, and never commit credentials or rendered Secrets.

## Prepare secrets

Create a Secret containing a valid Codex `auth.json`. The live credential is copied from it to a writable PVC and may be refreshed in place. The chart generates and preserves the proxy API-key Secret unless `apiKey.existingSecret` is set.

```bash
kubectl create namespace ai --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ai create secret generic codex-auth-bootstrap --from-file=auth.json="$HOME/.codex/auth.json"
```

Do not print the Secret value. A Kubernetes Secret volume cannot be used as the live auth file because the upstream process refreshes it.

## Install

The chart uses the upstream public multi-platform image by default and generates the proxy API key:

```bash
helm upgrade --install codex-proxy ./charts/codex-proxy --namespace ai --create-namespace
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

The route and gateway values are intentionally not included in the repository.

## Use the API

The Service URL inside the cluster is `http://codex-proxy.ai.svc.cluster.local:18080/v1`. Use the hostname configured in your private values file outside the cluster. Clients send the API key from `codex-proxy-api-key` as `Authorization: Bearer ...`. Pods reaching the Service must carry the label configured by `networkPolicy.clientLabel`.

```bash
curl https://proxy.example.internal/v1/models -H "Authorization: Bearer $OPENAI_API_KEY"
```

## Operations

Keep one replica and `Recreate`; do not attach an HPA or rolling strategy. Do not delete the PVC during normal upgrades. If the refresh token is revoked, log in again, replace the bootstrap Secret, stop the Deployment, remove only the stale `auth.json` from the PVC with a temporary non-root pod, and start the Deployment.

Back up the PVC only with encrypted storage and restricted access. It contains the live account credential. See the upstream [Docker documentation](https://github.com/hotchpotch/openai-api-server-via-codex/blob/main/docs/docker.md) for application behavior and configuration.

## Validate

```bash
helm lint charts/codex-proxy
helm template codex-proxy charts/codex-proxy
```
