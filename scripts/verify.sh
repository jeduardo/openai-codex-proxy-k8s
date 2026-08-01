#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: verify.sh [--build]

Validate repository manifests, scripts, and the Dockerfile.

Options:
  --build     Build the verification container image
  -h, --help  Show this help
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

build=false

while [ "$#" -gt 0 ]; do
  case $1 in
    --build)
      build=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

for command_name in kubectl kubeconform yamllint shellcheck hadolint; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command not found: $command_name"
done

if [ "$build" = true ]; then
  command -v docker >/dev/null 2>&1 || fail 'required command not found: docker'
fi

rendered_file=$(mktemp "${TMPDIR:-/tmp}/codex-proxy-rendered.XXXXXX")
cleanup() {
  rm -f "$rendered_file"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

yamllint deploy .yamllint.yaml
if [ -d .github ]; then
  yamllint .github
fi
kubectl kustomize deploy/base >"$rendered_file"
kubeconform -strict -summary "$rendered_file"
shellcheck scripts/*.sh
hadolint Dockerfile

if [ "$build" = true ]; then
  docker build -t openai-codex-proxy-k8s:verify .
fi

printf 'Verification passed.\n'
