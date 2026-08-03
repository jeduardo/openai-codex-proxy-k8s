# GHCR Kubernetes Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an operator securely configure GHCR pull credentials and install the private proxy into Kubernetes with one guided command.

**Architecture:** A standalone registry helper creates a `kubernetes.io/dockerconfigjson` Secret from a GitHub `read:packages` token without passing it in command arguments. A guided installer validates its execution context, calls the existing credential helpers plus that registry helper, generates a temporary Kustomize overlay for the requested image tag, applies it, and waits for rollout. The Deployment references the pull Secret through `imagePullSecrets`; the application never mounts or sees the registry token.

**Tech Stack:** POSIX shell, Kubernetes, Kustomize, `kubectl`, Docker config JSON, GitHub Container Registry, ShellCheck, yamllint, kubeconform, Hadolint.

---

## File map

- `.gitignore`: excludes installer-generated, in-repository temporary overlays.
- `deploy/base/deployment.yaml`: adds the GHCR pull-Secret reference at Pod level.
- `scripts/configure-registry-secret.sh`: securely creates/replaces the GHCR Docker config Secret.
- `scripts/install.sh`: validates operator inputs, configures three Secrets, renders a temporary image-tag overlay, deploys, and waits for rollout.
- `scripts/verify.sh`: includes the new scripts in static checks and asserts rendered `imagePullSecrets` presence.
- `README.md`: documents GitHub token requirements, interactive/noninteractive installation, tag selection, rotation, and image-pull troubleshooting.
- `SECURITY.md`: documents the GHCR token scope, trust boundary, and revocation response.

### Task 1: Reference the GHCR pull Secret in the Pod

**Files:**
- Modify: `.gitignore`
- Modify: `deploy/base/deployment.yaml` after `automountServiceAccountToken: false`

- [ ] **Step 1: Ignore installer-generated overlays**

Append this line to `.gitignore`:

```gitignore
deploy/overlays/.install-*/
```

This keeps the temporary Kustomize overlay inside the repository tree, where its relative `../../base` reference is supported, without allowing it to be committed.

- [ ] **Step 2: Add the Pod-level image pull Secret**

Add this exact block under `spec.template.spec`:

```yaml
      imagePullSecrets:
        - name: ghcr-pull-secret
```

Keep it adjacent to `automountServiceAccountToken: false`; do not mount the Secret or add it to application environment variables.

- [ ] **Step 3: Render and inspect the manifest**

Run:

```bash
kubectl kustomize deploy/base > /tmp/openai-codex-proxy-rendered.yaml
grep -A2 -B1 'imagePullSecrets:' /tmp/openai-codex-proxy-rendered.yaml
```

Expected output includes:

```yaml
imagePullSecrets:
- name: ghcr-pull-secret
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore deploy/base/deployment.yaml
git commit -m "feat: add GHCR pull secret to deployment"
```

### Task 2: Add the secure GHCR pull-Secret helper

**Files:**
- Create: `scripts/configure-registry-secret.sh`

- [ ] **Step 1: Create the helper**

Create an executable POSIX shell script with this behavior:

```sh
#!/bin/sh
set -eu

namespace=ai
username=

usage() {
  cat <<'EOF'
Usage: configure-registry-secret.sh --username GITHUB_USERNAME [--namespace NAME]

Create or replace the ghcr-pull-secret image pull Secret for ghcr.io.

Environment:
  GHCR_TOKEN  GitHub token with read:packages; required without an interactive terminal
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}
```

Implement `--username`, `--namespace`, `-h`, and `--help`; reject missing/empty values and unknown flags. Require `kubectl`, `base64`, and `mktemp`. Read the token from non-empty `GHCR_TOKEN`; otherwise, only when standard input is a terminal, prompt without echo using `stty -echo` and restore terminal state through a trap. Fail noninteractive runs without `GHCR_TOKEN`.

Use `umask 077`, a temporary directory, and a mode-0600 config file. Generate the Docker config with `printf` and a base64-encoded `username:token` value, without printing either value:

```json
{"auths":{"ghcr.io":{"auth":"BASE64_VALUE"}}}
```

Create the Secret with a temporary generated YAML manifest rather than a pipeline:

```sh
kubectl -n "$namespace" create secret generic ghcr-pull-secret \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$config_file" \
  --dry-run=client -o yaml >"$manifest_file"
kubectl apply -f "$manifest_file" >/dev/null
```

Clean every temporary file on `EXIT`, `HUP`, `INT`, and `TERM`. Print only:

```text
GHCR pull Secret is ready in namespace <namespace>.
```

- [ ] **Step 2: Make it executable and check non-secret paths**

Run:

```bash
chmod +x scripts/configure-registry-secret.sh
sh -n scripts/configure-registry-secret.sh
./scripts/configure-registry-secret.sh --help >/dev/null
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/configure-registry-secret.sh
fi
```

Expected: all commands exit 0.

- [ ] **Step 3: Verify noninteractive failure does not leak a token**

Run:

```bash
env -u GHCR_TOKEN ./scripts/configure-registry-secret.sh --username example </dev/null
```

Expected: nonzero exit and an error that `GHCR_TOKEN` is required for noninteractive execution; no token value is printed.

- [ ] **Step 4: Commit**

```bash
git add scripts/configure-registry-secret.sh
git commit -m "feat: add GHCR pull secret helper"
```

### Task 3: Add the guided installer

**Files:**
- Create: `scripts/install.sh`

- [ ] **Step 1: Create command parsing and prerequisite checks**

Create an executable POSIX shell script with `set -eu`, `fail()`, and this usage:

```text
Usage: install.sh --ghcr-username GITHUB_USERNAME [options]

Options:
  --namespace NAME       Kubernetes namespace (default: ai)
  --auth-file PATH       Codex auth file (default: $HOME/.codex/auth.json)
  --ghcr-username NAME   GitHub username owning the supplied GHCR token (required)
  --image-tag TAG        Image tag (default: main)
  --print-api-key        Print generated proxy API key to stdout after successful deployment
  --yes                  Skip interactive current-context confirmation
  -h, --help             Show this help

Environment:
  GHCR_TOKEN             GitHub token with read:packages; required without an interactive terminal
```

Reject empty values, unknown options, `--print-api-key` duplicates, and noninteractive execution without both `--yes` and `GHCR_TOKEN`. Require `kubectl`, `mktemp`, and the three helper scripts. Verify `kubectl config current-context` returns a non-empty value and print the selected context to stderr. Unless `--yes` is supplied, require a TTY and prompt exactly:

```text
Install into Kubernetes context "<context>" and namespace "<namespace>"? [y/N]
```

Proceed only on `y` or `Y`.

- [ ] **Step 2: Safely create required credentials**

Invoke helpers in this order:

```sh
./scripts/configure-registry-secret.sh \
  --namespace "$namespace" \
  --username "$ghcr_username"

./scripts/bootstrap-auth-secret.sh \
  --namespace "$namespace" \
  --file "$auth_file"
```

For the API key, call the existing helper without `--print` by default. When `--print-api-key` is requested, capture its clean stdout in a mode-0600 temporary file; do not store the key in a shell variable. Print the file content to stdout only after a successful rollout, then remove it through the existing cleanup trap. All installer progress text goes to stderr.

- [ ] **Step 3: Render an untracked temporary image overlay**

Determine the repository root safely, then create a mode-0700 ignored overlay directory inside `deploy/overlays`:

```sh
repo_root=$(git rev-parse --show-toplevel) || fail 'run this script from inside the repository'
mkdir -p "$repo_root/deploy/overlays"
overlay_dir=$(mktemp -d "$repo_root/deploy/overlays/.install-XXXXXX")
chmod 700 "$overlay_dir"
```

Write `$overlay_dir/kustomization.yaml` with this exact shape:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
images:
  - name: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newName: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newTag: IMAGE_TAG
```

Reject image tags containing whitespace, `/`, or `..`. Write the overlay with quoted shell expansion. Run:

```sh
kubectl kustomize "$overlay_dir" >/dev/null
kubectl apply -k "$overlay_dir"
kubectl -n "$namespace" rollout status deployment/openai-codex-proxy --timeout=180s
```

On rollout failure, print a safe troubleshooting message to stderr and leave cluster resources intact; cleanup only local temporary files. On success, print:

```text
Installed openai-codex-proxy in namespace <namespace> using ghcr.io/jeduardo/openai-codex-proxy-k8s:<tag>.
```

- [ ] **Step 4: Run static checks and help-path verification**

Run:

```bash
chmod +x scripts/install.sh
sh -n scripts/install.sh
./scripts/install.sh --help >/dev/null
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/install.sh
fi
git diff --check
```

Expected: all commands exit 0. Do not run an install against a real cluster without an operator-provided token and explicit cluster authorization.

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh
git commit -m "feat: add guided Kubernetes installer"
```

### Task 4: Extend static verification

**Files:**
- Modify: `scripts/verify.sh`

- [ ] **Step 1: Include new scripts and inspect rendered pull Secret**

Keep existing syntax/lint/schema validation and add both new scripts through the existing glob:

```sh
shellcheck scripts/*.sh
```

After Kustomize rendering and before printing success, assert the rendered deployment contains the expected pull Secret:

```sh
grep -q 'imagePullSecrets:' "$rendered_file" || fail 'rendered deployment is missing imagePullSecrets'
grep -q 'name: ghcr-pull-secret' "$rendered_file" \
  || fail 'rendered deployment is missing ghcr-pull-secret'
```

The existing `.yaml` suffix and positive kubeconform resource-count assertion must remain unchanged.

- [ ] **Step 2: Run verification**

Run:

```bash
./scripts/verify.sh
```

Expected output includes:

```text
Summary: 5 resources found in 1 file - Valid: 5, Invalid: 0, Errors: 0, Skipped: 0
Verification passed.
```

- [ ] **Step 3: Commit**

```bash
git add scripts/verify.sh
git commit -m "test: verify GHCR pull secret rendering"
```

### Task 5: Document GHCR installation and credential lifecycle

**Files:**
- Modify: `README.md`
- Modify: `SECURITY.md`

- [ ] **Step 1: Update README image references and install workflow**

Replace GHCR deployment examples so the registry image is consistently:

```text
ghcr.io/jeduardo/openai-codex-proxy-k8s
```

Add a `## Install from private GHCR` section before the existing manual deployment material. Include these instructions:

1. Create a GitHub fine-grained token or classic token with the minimum required `read:packages` permission and access to this private package.
2. Do not use an OAuth/Codex token as `GHCR_TOKEN`.
3. Interactive installation:

```bash
./scripts/install.sh \
  --ghcr-username jeduardo \
  --image-tag sha-REPLACE_WITH_COMMIT_SHA
```

4. Noninteractive installation:

```bash
export GHCR_TOKEN='obtain-from-a-secret-manager'
./scripts/install.sh \
  --yes \
  --namespace ai \
  --ghcr-username jeduardo \
  --image-tag sha-REPLACE_WITH_COMMIT_SHA
unset GHCR_TOKEN
```

5. Explain that `main` is only an evaluation default and immutable SHA/version tags are preferred.
6. Explain `ghcr-pull-secret` is a `kubernetes.io/dockerconfigjson` Secret used by kubelet only, is not mounted into the proxy, and must exist before the Pod can pull a private image.
7. Include token rotation:

```bash
export GHCR_TOKEN='new-token-from-a-secret-manager'
./scripts/configure-registry-secret.sh --namespace ai --username jeduardo
unset GHCR_TOKEN
kubectl -n ai rollout restart deployment/openai-codex-proxy
```

8. Add troubleshooting for `ImagePullBackOff`/`ErrImagePull`: inspect Pod events, confirm package visibility and `read:packages`, verify username/token and Secret name, then rerun the registry helper.

Keep manual Kustomize deployment documentation but state that private GHCR deployments need the `ghcr-pull-secret` first.

- [ ] **Step 2: Update SECURITY.md**

Add a GHCR section stating:

- `GHCR_TOKEN` is a registry credential, separate from the Codex auth file and proxy key.
- It must be limited to `read:packages` and package access only.
- It must not be supplied as a command argument, committed, logged, or mounted into the application.
- On suspected exposure, revoke the GitHub token, create a replacement, rerun `configure-registry-secret.sh`, and restart the Deployment.
- Kubernetes readers of `ghcr-pull-secret`, node operators, and backups remain sensitive trust boundaries.

- [ ] **Step 3: Validate documentation references**

Run:

```bash
grep -nE 'ghcr-pull-secret|GHCR_TOKEN|read:packages|ImagePullBackOff|scripts/install.sh' README.md SECURITY.md
git diff --check README.md SECURITY.md
```

Expected: the grep lists all documented registry lifecycle topics; `git diff --check` exits 0.

- [ ] **Step 4: Commit**

```bash
git add README.md SECURITY.md
git commit -m "docs: add private GHCR installation guide"
```

### Task 6: Final validation and review

**Files:**
- Modify only files required to correct a validation failure.

- [ ] **Step 1: Verify repository artifacts**

Run:

```bash
./scripts/verify.sh
cmp SPEC.md docs/spec.md
git ls-files | grep -E '(^|/)(auth\.json|.*\.backup|\.env)$' && exit 1 || true
git diff --check
git status --short
```

Expected: static verification passes; canonical spec comparison exits 0; no tracked credential/backup/environment files appear; no whitespace errors; no uncommitted output except the pre-existing untracked `docs/spec.md` when applicable.

- [ ] **Step 2: Verify installer safety paths without a cluster**

Run:

```bash
sh -n scripts/*.sh
./scripts/configure-registry-secret.sh --help >/dev/null
./scripts/install.sh --help >/dev/null
env -u GHCR_TOKEN ./scripts/configure-registry-secret.sh --username example </dev/null
```

Expected: first three commands exit 0; the final command exits nonzero with a noninteractive-token error and no secret output.

- [ ] **Step 3: Inspect rendered security configuration**

Run:

```bash
kubectl kustomize deploy/base > /tmp/openai-codex-proxy-rendered.yaml
grep -nE 'imagePullSecrets:|name: ghcr-pull-secret|replicas: 1|type: Recreate|automountServiceAccountToken: false|readOnlyRootFilesystem: true|type: ClusterIP' \
  /tmp/openai-codex-proxy-rendered.yaml
```

Expected: all controls are present, including `ghcr-pull-secret`.

- [ ] **Step 4: Commit any validation fixes**

If validation required changes:

```bash
git add -A
git commit -m "fix: satisfy GHCR installer validation"
```

Otherwise, do not create an empty commit.
