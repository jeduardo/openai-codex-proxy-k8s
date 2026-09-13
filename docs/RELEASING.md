# Releasing

The chart and the upstream proxy have separate versions.

- The chart version describes changes to templates, values, security defaults, and documentation.
- `appVersion` and `image.tag` identify the upstream proxy image used by the chart.

For example:

```yaml
version: 0.1.0
appVersion: v0.2.1
```

An upstream update should change `image.tag` and `appVersion` together. A chart-only change should bump the chart version without changing the upstream image.

## Current release process

Until the OCI publishing workflow is added, validate the chart locally and package it manually:

```bash
./scripts/verify.sh
helm package charts/codex-proxy
```

Do not publish a chart that contains cluster-specific hostnames, Gateway names, private values, or credentials.

## Planned Release Please flow

Release Please should manage the chart version from Conventional Commits. A manifest configuration can treat `charts/codex-proxy` as the releasable component, open a release pull request, update the changelog, and create a Git tag when that pull request is merged.

The upstream Renovate pull request should use a conventional commit such as:

```text
fix(deps): update upstream Codex proxy to v0.2.2
```

After it merges, Release Please can create the chart release pull request.

## Planned OCI publishing

After a Release Please tag is created, a publishing workflow should:

1. package `charts/codex-proxy`;
2. authenticate to GHCR with the workflow token;
3. push the chart as an OCI artifact;
4. publish the chart version from `Chart.yaml`.

The eventual install form will be:

```bash
helm upgrade --install codex-proxy \
  oci://ghcr.io/OWNER/codex-proxy \
  --version 0.1.0 \
  --namespace ai \
  --create-namespace
```

Use an immutable chart version and keep the upstream image tag explicit. The Helm chart should continue to reference the upstream public image directly; publishing the chart does not require building or copying that image.
