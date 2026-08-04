# Security Policy

## Experimental support boundary

This is an unofficial, experimental homelab deployment of an upstream Codex proxy. It is not the official OpenAI Platform API and is not supported or endorsed by OpenAI. The upstream Codex/ChatGPT interface and credential format may change without notice. Security fixes and compatibility updates are best-effort; no stability or response-time guarantee is made.

Use the service only on a private, trusted network. Public exposure and multi-user account isolation are unsupported. Never operate more than one replica or replace the `Recreate` strategy: overlapping OAuth refresh writers can invalidate credentials.

## Report vulnerabilities privately

Do not open a public issue, discussion, or pull request for a suspected vulnerability. Use GitHub's **Security** tab and private vulnerability reporting for this repository. If that facility is unavailable, contact the repository owner privately through the owner's published contact channel and ask for a secure reporting method before sending details.

Include affected versions, impact, reproduction steps, and a minimal redacted proof of concept. Do not include live OAuth files, tokens, API keys, authorization headers, personal account data, or cluster credentials. If a real credential was exposed while testing, rotate it immediately rather than sending it to the maintainers.

General upstream application vulnerabilities should also be reported privately to the upstream project. Coordinate disclosure until affected operators have a reasonable opportunity to remediate.

## Threat model

### Assets and trust boundaries

- **Codex OAuth credentials:** `auth.json` contains access, ID, and refresh tokens plus account metadata. A valid refresh token can provide continuing account access within the provider's authorization scope.
- **Live PVC state:** `codex-auth` is the authoritative, writable credential after refresh-token rotation. It may be newer and more valuable than the bootstrap Secret.
- **Kubernetes Secrets:** `codex-auth-bootstrap` seeds the first credential; `codex-proxy-api-key` authenticates clients; and `ghcr-pull-secret` gives kubelets access to the private image. Secret data is base64-encoded unless the cluster separately enables encryption at rest.
- **GHCR token:** the registry token needs only GitHub `read:packages` for `ghcr.io/jeduardo/openai-codex-proxy-k8s`. It is distinct from Codex OAuth credentials and the proxy API key. `ghcr-pull-secret` is used for image pulls and must not be mounted into the application.
- **Authorized clients:** a client with the NetworkPolicy label and proxy key can spend account quota and submit/read API content. The label alone is not authentication, and the proxy key does not isolate users from one another.
- **Proxy pod:** compromise of the application process can expose its API key environment value, mounted live OAuth credential, request/response content, and writable PVC state.
- **Cluster nodes:** root or equivalent access to a node may expose pod memory, container runtime data, mounted volumes, traffic, and image-pull credentials delivered to kubelets.
- **Cluster and namespace administrators:** principals able to read Secrets (including `ghcr-pull-secret`), exec into pods, create PVC-mounted pods, mutate workloads, label pods, or change NetworkPolicy are trusted with the protected data. Cluster-admin access is effectively full compromise of this deployment.
- **Backup and Secret readers:** anyone who can read Kubernetes Secret data, nodes, container-runtime state, or backups containing those assets crosses the credential boundary. Restrict each of these readers to trusted administrators.

The controls here reduce accidental exposure and contain ordinary workload compromise. They do not defend against a malicious cluster administrator, compromised node/root, compromised provider, or fully compromised authorized client. NetworkPolicy is not a firewall when the CNI does not enforce it, and standard Kubernetes NetworkPolicy cannot restrict destinations by FQDN.

## Required operator controls

Operators must:

1. Keep the Service `ClusterIP` and private; do not add public Ingress, NodePort, LoadBalancer, or untrusted tunneling.
2. Keep `replicas: 1` and `strategy.type: Recreate`; do not attach an HPA or enable rolling overlap.
3. Require the separate, cryptographically random proxy API key and distribute it through a secret manager or Kubernetes Secret reference, not source control or command-line literals.
4. Restrict ingress to explicitly labelled clients, restrict who may label pods/change policy, and use a CNI that enforces NetworkPolicy.
5. Review the DNS selector for the cluster. Use an overlay for nonstandard CoreDNS, kube-dns, or NodeLocal DNS labels.
6. Deliberately control HTTPS egress through general TCP/443, an egress proxy, CNI FQDN policy, or externally maintained IP policy. Do not assume standard NetworkPolicy understands hostnames.
7. Enable Kubernetes API-data encryption at rest, encrypted etcd/datastore backups, encrypted PVC backups/snapshots, restrictive RBAC, and namespace access controls.
8. Limit Secret reads, pod exec/ephemeral-container creation, workload mutation, PVC attachment, node access, and backup access to trusted administrators.
9. Perform Codex login only on a trusted, patched workstation. Never share or commit `auth.json`, token backups, API keys, rendered Secrets, or client configuration containing them.
10. Use immutable reviewed image tags rather than `main`, verify image provenance where available, scan dependencies, and make upstream version changes explicit.
11. Create the GHCR credential with only GitHub `read:packages`. Never pass that token as a CLI argument, write it to logs, mount `ghcr-pull-secret` into the application, or commit it to source control; it is a kubelet-only image-pull credential.
12. Keep service-account token automounting disabled. The proxy needs no Kubernetes API permissions; do not grant it a Role or RoleBinding.
13. Preserve the non-root application security context, read-only root filesystem, dropped capabilities, disabled privilege escalation, RuntimeDefault seccomp, and writable mounts only for `/tmp` and the credential PVC.
14. Keep the bootstrap Secret mount read-only and the live file mode `0600`. Do not use a projected Secret as the live refreshable file.
15. Prevent secrets from reaching logs, tracing, metrics, shell history, CI artifacts, support tickets, crash dumps, or terminal recordings. Never enable shell tracing around secret operations.
16. Define encrypted backup retention, restoration tests, incident contacts, and deletion procedures. Remember that deleting a Secret or PVC does not remove copies from snapshots, datastore backups, clients, or provider sessions.

Anyone allowed to add the client label can attempt network access, so bearer authentication remains mandatory. Conversely, possession of the bearer key does not bypass NetworkPolicy when it is enforced.

## Application least privilege

The main proxy container runs as UID/GID `10001`, drops all Linux capabilities, cannot gain privileges, uses a read-only root filesystem, and receives no service-account token. Only `/tmp` and `/var/lib/codex` are writable. The latter is unavoidable because upstream refreshes tokens by atomically replacing `auth.json`.

The application does not synchronize refreshed credentials into Kubernetes Secrets. Giving it Kubernetes write permission would expand compromise impact, create update races, and violate its least-privilege boundary.

### Narrow init-container exception

The `bootstrap-auth` init container runs as UID/GID `0` only to normalize ownership and mode on storage supplied by varying CSI drivers. It has a read-only root filesystem, no service-account token, no privilege escalation, RuntimeDefault seccomp, and drops every capability except `CHOWN`. It can access only the read-only bootstrap Secret and credential PVC.

This root-plus-`CHOWN` exception must remain limited to the init container. It is not justification to run the proxy as root, add other capabilities, use a privileged container, mount the host filesystem, or broaden Kubernetes API access. If a storage driver can reliably provision correct UID/GID ownership, operators may test a narrower overlay, but must preserve mode `0600` and atomic credential rewrites.

## Credential rotation and incident response

### Proxy API key exposure

1. Stop or isolate untrusted clients and preserve only non-secret evidence.
2. Run `./scripts/generate-api-key.sh --namespace ai` to replace the Secret. Do not use `--print` unless securely capturing the value for an intended client.
3. Restart the Deployment because Secret-backed environment variables are read at pod creation:

   ```bash
   kubectl -n ai rollout restart deployment/openai-codex-proxy
   kubectl -n ai rollout status deployment/openai-codex-proxy
   ```

4. Update authorized clients through approved secret distribution and invalidate/remove old copies.
5. Review access logs and account usage without printing authorization headers or request secrets.

### GHCR token or pull Secret exposure

1. Revoke the exposed GitHub token and create a replacement limited to `read:packages`.
2. Replace `ghcr-pull-secret` with `GHCR_TOKEN` using `./scripts/configure-registry-secret.sh --namespace ai --username GITHUB_USERNAME`; do not pass the token as a CLI argument or record it in logs.
3. Restart and observe the rollout so nodes use the replacement image-pull credential:

   ```bash
   kubectl -n ai rollout restart deployment/openai-codex-proxy
   kubectl -n ai rollout status deployment/openai-codex-proxy
   ```

4. Review Secret-reader, node, container-runtime, and backup access because each may retain or expose the old credential.

### OAuth, bootstrap Secret, or PVC exposure

1. Treat exposure of any live or backed-up `auth.json` as account credential compromise.
2. Use the provider's account/session controls to revoke affected sessions or credentials where available, and review account activity.
3. Perform a new Codex login on a trusted workstation.
4. Replace `codex-auth-bootstrap`, stop the Deployment, remove the stale PVC `auth.json`, and restart using the recovery procedure in [README.md](README.md#refresh-token-rotation-and-recovery).
5. Rotate the proxy API key too if pod, node, administrator, backup, or namespace compromise could have exposed both assets.
6. Replace or securely destroy exported files and client copies; expire encrypted snapshots/backups according to incident policy.
7. Investigate and correct the access path before restoring service.

Merely updating the bootstrap Secret is insufficient when the PVC already has a file: the init container intentionally preserves the PVC copy. Likewise, restoring only an original Secret may fail after refresh-token rotation.

### Node or administrator compromise

Assume both OAuth credentials and the proxy API key are exposed, along with API request/response data. Isolate the affected infrastructure, rotate both credential sets, rebuild on trusted nodes, review RBAC/audit events and backup access, and follow the cluster's broader incident-response plan. Application container hardening cannot protect credentials from a malicious node or cluster administrator.

## Logging and evidence handling

Normal operational logs must not contain OAuth access, ID, or refresh tokens; incoming proxy API keys; complete authentication JSON; or authorization headers. CI must never receive credentials or upload them as artifacts.

Use bounded `kubectl logs` and metadata-only inspection. Do not dump Secrets, pod environments, or the live credential file for troubleshooting. Redact locally before sharing output. If a secret appears in logs or evidence, restrict access, remove retained copies where feasible, and rotate it; redaction after public disclosure is not sufficient.

## Supported security posture

The supported posture is one account, one private `ClusterIP` service, one proxy pod, one writable credential PVC, explicitly authorized in-cluster clients, and no public ingress. Deployments that expose the API publicly, share one account across mutually untrusted users, run concurrent replicas, or weaken the container/cluster controls are outside this project's security model.
