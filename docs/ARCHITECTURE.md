# Architecture

The chart runs the upstream `openai-api-server-via-codex` image as a single Kubernetes Deployment. It exposes the server through a ClusterIP Service and keeps the live Codex credential on a writable PersistentVolumeClaim.

## Resources

By default, the chart creates:

- one `Deployment` with one replica and the `Recreate` strategy;
- one `PersistentVolumeClaim` for the live `auth.json`;
- one `Service` on port `18080`;
- one `NetworkPolicy` allowing labelled clients to reach the Service and allowing DNS and HTTPS egress;
- one proxy API-key `Secret`, generated and preserved by Helm unless `apiKey.existingSecret` is set.

The Codex bootstrap Secret is supplied by the operator through `auth.existingSecret`. The chart does not generate or store a Codex login. An init container copies `auth.json` from that Secret to the PVC the first time the volume is empty. The upstream process then reads and refreshes the PVC copy in place.

The chart does not mount the Secret as the live file because Kubernetes Secret volumes are read-only and the upstream process must be able to replace `auth.json` during token refresh.

## External access

External access is disabled by default. Choose one of these optional resources:

- `HTTPRoute`, when the cluster uses Gateway API;
- `Ingress`, when the cluster uses a conventional Ingress controller.

Both route types point to the chart Service. Hostnames, Gateway references, Ingress class names, TLS settings, and gateway pod labels belong in private values files because they are cluster-specific.

## Security boundary

The proxy container runs as UID/GID `1000`, has a read-only root filesystem, drops Linux capabilities, and receives no service-account token. The API key protects incoming `/v1` requests. The Codex OAuth credential remains in the operator-managed bootstrap Secret and the PVC, so both need the same protection as the account they represent.

The chart deliberately runs one replica. Concurrent instances can race while refreshing a rotating OAuth credential and invalidate one another.
