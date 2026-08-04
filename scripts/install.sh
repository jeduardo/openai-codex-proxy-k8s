#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
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
  case $value in -*) fail "$option requires a value" ;; esac
}

namespace=ai
auth_file=
ghcr_username=
image_tag=main
print_api_key=false
yes=false
namespace_set=false
auth_file_set=false
ghcr_username_set=false
image_tag_set=false

while [ "$#" -gt 0 ]; do
  case $1 in
    --namespace)
      [ "$namespace_set" = false ] || fail '--namespace may only be specified once'
      require_value "$1" "$#" "${2-}"; namespace=$2; namespace_set=true; shift 2 ;;
    --auth-file)
      [ "$auth_file_set" = false ] || fail '--auth-file may only be specified once'
      require_value "$1" "$#" "${2-}"; auth_file=$2; auth_file_set=true; shift 2 ;;
    --ghcr-username)
      [ "$ghcr_username_set" = false ] || fail '--ghcr-username may only be specified once'
      require_value "$1" "$#" "${2-}"; ghcr_username=$2; ghcr_username_set=true; shift 2 ;;
    --image-tag)
      [ "$image_tag_set" = false ] || fail '--image-tag may only be specified once'
      require_value "$1" "$#" "${2-}"; image_tag=$2; image_tag_set=true; shift 2 ;;
    --print-api-key)
      [ "$print_api_key" = false ] || fail '--print-api-key may only be specified once'
      print_api_key=true; shift ;;
    --yes)
      [ "$yes" = false ] || fail '--yes may only be specified once'
      yes=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$ghcr_username" ] || fail '--ghcr-username is required'
case $image_tag in
  *[![:print:]]*|*[[:space:]]*|*/*|*..*) fail '--image-tag must not contain whitespace, /, or ..' ;;
esac
if [ -z "$auth_file" ]; then
  [ -n "${HOME-}" ] || fail 'HOME is not set; specify --auth-file PATH'
  auth_file=$HOME/.codex/auth.json
fi

for command_name in kubectl mktemp git; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
repo_root=$(git rev-parse --show-toplevel) || fail 'run this script from inside the repository'
script_dir=$repo_root/scripts
for helper_name in configure-registry-secret.sh bootstrap-auth-secret.sh generate-api-key.sh; do
  helper_path=$script_dir/$helper_name
  [ -x "$helper_path" ] || fail "required executable helper not found: $helper_path"
done

if [ ! -t 0 ]; then
  [ "$yes" = true ] || fail 'noninteractive execution requires --yes'
  [ -n "${GHCR_TOKEN-}" ] || fail 'GHCR_TOKEN is required for noninteractive execution'
fi
context=$(kubectl config current-context) || fail 'unable to determine current Kubernetes context'
[ -n "$context" ] || fail 'current Kubernetes context is empty'
printf 'Kubernetes context: %s\n' "$context" >&2
if [ "$yes" = false ]; then
  [ -t 0 ] || fail 'interactive confirmation requires a terminal; use --yes'
  printf 'Install into Kubernetes context "%s" and namespace "%s"? [y/N] ' "$context" "$namespace" >&2
  IFS= read -r confirmation || fail 'unable to read confirmation'
  case $confirmation in y|Y) ;; *) fail 'installation cancelled' ;; esac
fi

umask 077
overlay_dir=
rendered_file=
api_key_file=
cleanup() {
  [ -z "$api_key_file" ] || rm -f "$api_key_file"
  [ -z "$rendered_file" ] || rm -f "$rendered_file"
  [ -z "$overlay_dir" ] || rm -rf "$overlay_dir"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

printf 'Configuring GHCR pull Secret...\n' >&2
"$script_dir/configure-registry-secret.sh" --namespace "$namespace" --username "$ghcr_username" >&2
printf 'Configuring Codex authentication Secret...\n' >&2
"$script_dir/bootstrap-auth-secret.sh" --namespace "$namespace" --file "$auth_file" >&2
printf 'Generating proxy API key Secret...\n' >&2
if [ "$print_api_key" = true ]; then
  api_key_file=$(mktemp "${TMPDIR:-/tmp}/openai-codex-proxy-api-key.XXXXXX")
  chmod 600 "$api_key_file"
  "$script_dir/generate-api-key.sh" --namespace "$namespace" --print >"$api_key_file"
else
  "$script_dir/generate-api-key.sh" --namespace "$namespace" >&2
fi

mkdir -p "$repo_root/deploy/overlays"
overlay_dir=$(mktemp -d "$repo_root/deploy/overlays/.install-XXXXXX")
chmod 700 "$overlay_dir"
cat >"$overlay_dir/kustomization.yaml" <<EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $namespace
resources:
  - ../../base
images:
  - name: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newName: ghcr.io/jeduardo/openai-codex-proxy-k8s
    newTag: $image_tag
EOF
rendered_file=$(mktemp "${TMPDIR:-/tmp}/openai-codex-proxy-rendered.XXXXXX")
chmod 600 "$rendered_file"
printf 'Rendering Kubernetes manifests...\n' >&2
kubectl kustomize "$overlay_dir" >"$rendered_file"
printf 'Applying Kubernetes manifests...\n' >&2
kubectl apply -f "$rendered_file" >&2
printf 'Waiting for deployment rollout...\n' >&2
if ! kubectl --namespace "$namespace" rollout status deployment/openai-codex-proxy --timeout=180s >&2; then
  printf 'Deployment rollout failed; inspect the deployment and Pod events. Cluster resources were left unchanged.\n' >&2
  exit 1
fi
printf 'Installed openai-codex-proxy in namespace %s using ghcr.io/jeduardo/openai-codex-proxy-k8s:%s.\n' "$namespace" "$image_tag" >&2
if [ "$print_api_key" = true ]; then
  cat "$api_key_file"
fi
