#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: generate-api-key.sh [--namespace NAME] [--print]

Generate an API key and create or replace the proxy API key Secret.

Options:
  --namespace NAME  Kubernetes namespace (default: ai)
  --print           Print the generated key to standard output
  -h, --help        Show this help
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
print_key=false

while [ "$#" -gt 0 ]; do
  case $1 in
    --namespace)
      require_value "$1" "$#" "${2-}"
      namespace=$2
      shift 2
      ;;
    --print)
      print_key=true
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

command -v kubectl >/dev/null 2>&1 || fail 'required command not found: kubectl'
command -v openssl >/dev/null 2>&1 || fail 'required command not found: openssl'

umask 077
key_file=
manifest_file=
cleanup() {
  [ -z "$key_file" ] || rm -f "$key_file"
  [ -z "$manifest_file" ] || rm -f "$manifest_file"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

api_key=$(openssl rand -hex 32)
key_file=$(mktemp "${TMPDIR:-/tmp}/codex-proxy-api-key.XXXXXX")
chmod 600 "$key_file"
printf '%s' "$api_key" >"$key_file"
manifest_file=$(mktemp "${TMPDIR:-/tmp}/codex-proxy-api-key-manifest.XXXXXX")
chmod 600 "$manifest_file"

kubectl create namespace "$namespace" --dry-run=client -o yaml >"$manifest_file"
kubectl apply -f "$manifest_file" >/dev/null
kubectl --namespace "$namespace" create secret generic codex-proxy-api-key \
  --from-file="api-key=$key_file" \
  --dry-run=client -o yaml >"$manifest_file"
kubectl apply -f "$manifest_file" >/dev/null

if [ "$print_key" = true ]; then
  printf '%s\n' "$api_key"
  printf 'Proxy API key Secret is ready in namespace %s.\n' "$namespace" >&2
else
  printf 'Proxy API key Secret is ready in namespace %s.\n' "$namespace"
fi
