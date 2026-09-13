#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: verify.sh

Validate the Helm chart and shell scripts.

Options:
  -h, --help  Show this help
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

for command_name in helm kubeconform shellcheck; do
  command -v "$command_name" >/dev/null 2>&1 \
  || fail "required command not found: $command_name"
done

rendered_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-proxy-rendered.XXXXXX")
rendered_file="$rendered_dir/rendered.yaml"
cleanup() {
  rm -rf "$rendered_dir"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

helm lint charts/codex-proxy
helm template codex-proxy charts/codex-proxy >"$rendered_file"
if ! kubeconform_output=$(kubeconform -strict -summary "$rendered_file" 2>&1); then
  printf '%s\n' "$kubeconform_output" >&2
  fail 'schema validation failed'
fi
printf '%s\n' "$kubeconform_output"
printf '%s\n' "$kubeconform_output" \
  | grep -q 'Summary: [1-9][0-9]* resource' \
  || fail 'schema validation processed zero resources'
shellcheck scripts/*.sh

printf 'Verification passed.\n'
