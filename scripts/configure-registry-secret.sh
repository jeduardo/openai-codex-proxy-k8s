#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: configure-registry-secret.sh --username GITHUB_USERNAME [--namespace NAME]

Create or replace the ghcr-pull-secret image pull Secret for ghcr.io.

Options:
  --username NAME    GitHub username required for GHCR authentication
  --namespace NAME   Kubernetes namespace (default: ai)
  -h, --help         Show this help

Environment:
  GHCR_TOKEN         GitHub token with read:packages; required without a terminal
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_value() {
  option=$1
  count=$2
  value=${3-}

  [ "$count" -ge 2 ] || fail "$option requires a value"
  [ -n "$value" ] || fail "$option requires a non-empty value"
  case $value in
    -*) fail "$option requires a value" ;;
  esac
}

namespace=ai
username=

while [ "$#" -gt 0 ]; do
  case $1 in
    --username)
      require_value "$1" "$#" "${2-}"
      username=$2
      shift 2
      ;;
    --namespace)
      require_value "$1" "$#" "${2-}"
      namespace=$2
      shift 2
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

[ -n "$username" ] || fail '--username is required'

for command_name in kubectl base64 mktemp; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command not found: $command_name"
done

umask 077
tmpdir=
terminal_state=
terminal_echo_disabled=false

restore_terminal() {
  if [ "${terminal_echo_disabled-false}" = true ]; then
    if [ -n "${terminal_state-}" ]; then
      stty "$terminal_state" >/dev/null 2>&1 || :
    fi
    terminal_echo_disabled=false
  fi
}

cleanup() {
  restore_terminal
  [ -z "$tmpdir" ] || rm -rf "$tmpdir"
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

token=${GHCR_TOKEN-}
if [ -z "$token" ]; then
  [ -t 0 ] || fail 'GHCR_TOKEN is required for noninteractive execution'
  printf 'GHCR token: ' >&2
  terminal_state=$(stty -g)
  terminal_echo_disabled=true
  stty -echo
  if ! IFS= read -r token; then
    printf '\n' >&2
    fail 'unable to read GHCR_TOKEN from terminal'
  fi
  restore_terminal
  printf '\n' >&2
  [ -n "$token" ] || fail 'GHCR_TOKEN must be non-empty'
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/ghcr-pull-secret.XXXXXX")
chmod 700 "$tmpdir"
config_file=$tmpdir/.dockerconfigjson
manifest_file=$tmpdir/manifest.yaml
: >"$config_file"
: >"$manifest_file"
chmod 600 "$config_file" "$manifest_file"

auth=$(printf '%s' "$username:$token" | base64 | tr -d '\n')
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$auth" >"$config_file"

kubectl --namespace "$namespace" create secret generic ghcr-pull-secret \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$config_file" \
  --dry-run=client -o yaml >"$manifest_file"
kubectl apply -f "$manifest_file" >/dev/null

printf 'GHCR pull Secret is ready in namespace %s.\n' "$namespace"
