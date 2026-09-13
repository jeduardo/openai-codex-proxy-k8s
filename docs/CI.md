# CI

The repository has three small bits of automation.

## Validation

The `Validate` workflow runs on pushes and pull requests. It installs Helm and kubeconform, then runs:

```bash
./scripts/verify.sh
```

That command lints the chart, renders the default chart, checks the rendered Kubernetes resources against schemas, and runs ShellCheck over the shell scripts.

Run the same checks locally before opening a pull request:

```bash
./scripts/verify.sh
```

## Renovate

The `Renovate` workflow runs daily and can also be started from the Actions tab. It checks the upstream container for new tags and opens a pull request that updates both `image.tag` and `appVersion`.

The workflow uses the repository `GITHUB_TOKEN`. If Renovate cannot open or approve its pull request, enable the repository setting that allows GitHub Actions to create and approve pull requests. Review Renovate pull requests like any other dependency update; the chart must still pass validation before merging.

## Workflow cleanup

The `Clean up workflow runs` workflow runs daily and can be started manually. It keeps the five newest runs for each workflow and deletes older runs through the GitHub Actions API. It needs `actions: write` permission and does not delete releases, tags, artifacts, or source code.

## Public repository settings

When the repository is public:

- keep workflow permissions as narrow as possible;
- review third-party Actions and pin their versions;
- enable the setting required for Actions to create and approve pull requests if Renovate needs it;
- do not put Kubernetes credentials, Codex auth files, API keys, or private values files in the repository.
