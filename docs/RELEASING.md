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

## Release process

Release Please watches Conventional Commits on `main`. It opens a release pull request that updates the chart version and changelog. Merging that pull request creates a GitHub release and a tag such as `codex-proxy-v0.1.0`.

The release workflow then packages the chart and publishes it to GHCR as an OCI artifact. Install a published version with:

```bash
helm upgrade --install codex-proxy \
  oci://ghcr.io/OWNER/codex-proxy \
  --version 0.1.0 \
  --namespace ai \
  --create-namespace
```

Do not publish a chart that contains cluster-specific hostnames, Gateway names, private values, or credentials.

The upstream Renovate pull request should use a conventional commit such as:

```text
fix(deps): update upstream Codex proxy to v0.2.2
```

After it merges, Release Please can create the chart release pull request.

Use an immutable chart version and keep the upstream image tag explicit. The Helm chart should continue to reference the upstream public image directly; publishing the chart does not require building or copying that image.
