#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: bootstrap-auth-secret.sh [--namespace NAME] [--file PATH]

Create or replace the Codex authentication bootstrap Secret.

Options:
  --namespace NAME  Kubernetes namespace (default: ai)
  --file PATH       Codex auth file (default: $HOME/.codex/auth.json)
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
auth_file=

while [ "$#" -gt 0 ]; do
  case $1 in
    --namespace)
      require_value "$1" "$#" "${2-}"
      namespace=$2
      shift 2
      ;;
    --file)
      require_value "$1" "$#" "${2-}"
      auth_file=$2
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

if [ -z "$auth_file" ]; then
  [ -n "${HOME-}" ] || fail 'HOME is not set; specify --file PATH'
  auth_file=$HOME/.codex/auth.json
fi

command -v kubectl >/dev/null 2>&1 || fail 'required command not found: kubectl'
command -v jq >/dev/null 2>&1 || fail 'required command not found: jq'

[ -f "$auth_file" ] || fail "auth file not found: $auth_file"

jq -e -s 'length == 1' -- "$auth_file" >/dev/null 2>&1 \
  || fail 'auth file is not valid JSON'
jq -e '
  if type == "object" and has("auth_mode") then
    .auth_mode == "chatgpt"
  else
    true
  end
' -- "$auth_file" >/dev/null 2>&1 || fail 'auth_mode must be chatgpt when present'

kubectl create namespace "$namespace" --dry-run=client -o yaml 2>/dev/null \
  | kubectl apply -f - >/dev/null 2>&1
kubectl --namespace "$namespace" create secret generic codex-auth-bootstrap \
  --from-file="auth.json=$auth_file" \
  --dry-run=client -o yaml 2>/dev/null \
  | kubectl apply -f - >/dev/null 2>&1

printf 'Codex authentication Secret is ready in namespace %s.\n' "$namespace"
