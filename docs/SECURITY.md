# Security

This project runs an unofficial proxy using a ChatGPT/Codex account. Treat the Codex auth file, the live PVC, the proxy API key, and encrypted backups as account credentials.

## Supported posture

Use the chart on a private, trusted network with one account and one replica. Keep `Service` as `ClusterIP`, retain `Recreate`, and require the proxy API key for `/v1` requests. Do not expose the service publicly, share one account among mutually untrusted users, or attach an HPA.

The NetworkPolicy is useful only when the cluster CNI enforces it and untrusted users cannot create labelled pods or change the policy. The bearer key remains required even when the policy is active.

## Credential handling

- Create the Codex bootstrap Secret on a trusted workstation.
- Do not commit `auth.json`, API keys, rendered Secrets, shell history, or backups.
- Keep the bootstrap Secret read-only and the live file on the writable PVC.
- Protect the Helm release metadata because it contains references to Secret names and may contain generated API-key data in release state.
- Use an external Secret manager when GitOps or centralized rotation is required.
- Encrypt Kubernetes Secret data, PVC snapshots, and datastore backups at rest.
- Limit access to Secrets, PVCs, pod exec, workload mutation, and nodes to trusted administrators.

The chart does not give the proxy Kubernetes API permissions. A compromised pod can still access its mounted auth file, its API key environment value, and request data; container hardening cannot protect against a compromised node or cluster administrator.

## Runtime controls

The proxy and bootstrap init container run as UID/GID 1000 with no Linux capabilities, no privilege escalation, RuntimeDefault seccomp, and a read-only root filesystem. Only `/tmp` and the auth PVC are writable. Service-account token automounting is disabled.

The single-replica `Recreate` strategy is required because refresh-token rotation is stateful. Overlapping instances can refresh the same credential concurrently and invalidate one another.

Standard NetworkPolicy cannot restrict HTTPS egress by hostname. Use an egress proxy, a CNI with FQDN policy, reviewed IP ranges, or accept TCP/443 egress for this workload.

The optional Ingress requires a TLS entry. The optional Gateway API route still depends on the selected Gateway listener being HTTPS. Gateway access also requires an explicit pod label selector; an empty selector is rejected because it would allow every pod in the gateway namespace.

## Incidents

If the proxy API key is exposed, replace the Secret and restart the Deployment. If `auth.json`, the PVC, a backup, or a node is exposed, treat the ChatGPT/Codex session as compromised: revoke the affected session where possible, perform a fresh trusted login, replace the bootstrap Secret, remove the stale PVC file, and rotate the proxy API key.

If a token appears in logs or support material, stop sharing the output and rotate the affected credential. Use bounded, redacted logs for troubleshooting.

## Reporting

Report suspected vulnerabilities privately through GitHub Security. Do not open a public issue with credentials, authorization headers, account data, or a live reproduction. Report upstream application issues to the upstream project as well.
