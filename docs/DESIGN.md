# Design

This repository provides a small Helm chart for running the upstream [`openai-api-server-via-codex`](https://github.com/hotchpotch/openai-api-server-via-codex) service in Kubernetes.

The service presents an OpenAI-compatible `/v1` API backed by one ChatGPT/Codex login. It is intended for a private cluster and a trusted set of clients. It is not the official OpenAI Platform API and does not provide account isolation or bypass plan limits.

## Goals

The chart should:

- use the upstream container image directly;
- run one replica with the `Recreate` strategy;
- keep the live, refreshable `auth.json` on a writable PVC;
- protect requests with a separate bearer API key;
- run the proxy as a non-root user with a read-only root filesystem;
- support either Gateway API `HTTPRoute` or conventional `Ingress`;
- keep cluster-specific hostnames, Gateway names, and TLS settings in values files;
- make normal upgrades and credential recovery understandable.

## Credential flow

The operator creates a Secret containing a valid Codex `auth.json`. An init container copies that file to the PVC only when the PVC does not already contain one. The upstream process reads the PVC copy and refreshes it in place when tokens expire.

```text
auth Secret ──read-only──> init container ──first start──> PVC/auth.json
                                                            │
                                                            ▼
                                                   upstream proxy
```

The Secret is a bootstrap input, not the live credential. Replacing it does not overwrite a newer file on the PVC. This prevents an old refresh token from replacing a rotated one.

The chart can generate the incoming API-key Secret and preserve it across upgrades. Operators may instead set `apiKey.existingSecret`. The Codex auth Secret is always supplied externally.

## Kubernetes resources

The chart creates a Deployment, Service, PVC, NetworkPolicy, and API-key Secret. It optionally creates an HTTPRoute or an Ingress. The Service is always ClusterIP.

The NetworkPolicy allows traffic from pods carrying the configured client label and HTTPS/DNS egress. If a Gateway controller reaches the Service directly, its namespace and pod selector must be added through `networkPolicy.gateway`.

The containers use UID/GID 1000, `fsGroup: 1000`, dropped capabilities, RuntimeDefault seccomp, disabled service-account tokens, and a read-only root filesystem. The selected StorageClass must support `fsGroup` so the non-root init container can seed the PVC.

## Deliberate limits

The chart does not implement OAuth login, copy refreshed credentials back into Kubernetes Secrets, run multiple replicas, or expose the service publicly by default. Those choices keep the chart small and preserve the upstream credential model.

## Validation

Changes should pass:

```bash
helm lint charts/codex-proxy
helm template codex-proxy charts/codex-proxy
```

Rendered resources should also pass Kubernetes schema validation. Test both the default chart and the optional route or ingress configuration being changed.
