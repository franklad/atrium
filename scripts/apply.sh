#!/usr/bin/env bash
#
# scripts/apply.sh — render the kustomize bundles against
# cluster.config.yaml and apply to the current kubectl context.
#
# Usage:
#   ./scripts/apply.sh                # apply platform + hermes
#   ./scripts/apply.sh platform       # apply only deploy/platform/
#   ./scripts/apply.sh hermes         # apply only deploy/hermes/
#
# Prereqs: yq, envsubst, kubectl. Install yq via:
#   mise use -g yq            (mise users)
#   brew install yq           (macOS)
#   pacman -S go-yq           (Arch)

set -euo pipefail

ATRIUM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ATRIUM_DIR}/cluster.config.yaml"

# ---------- prereqs ---------------------------------------------------------

[ -f "$CONFIG" ] || {
  echo "error: $CONFIG missing." >&2
  echo "       cp cluster.config.example.yaml cluster.config.yaml" >&2
  echo "       \$EDITOR cluster.config.yaml" >&2
  exit 1
}

for tool in yq envsubst kubectl; do
  command -v "$tool" >/dev/null || {
    echo "error: '$tool' not found in PATH." >&2
    [ "$tool" = yq ] && echo "       install: mise use -g yq  (or brew install yq)" >&2
    exit 1
  }
done

# ---------- load config -----------------------------------------------------

CLUSTER_DOMAIN=$(yq -r '.cluster.domain // ""' "$CONFIG")
HERMES_HOSTNAME=$(yq -r '.mesh.hermes_hostname // ""' "$CONFIG")
ACME_EMAIL=$(yq -r '.acme.email // ""' "$CONFIG")

for v in CLUSTER_DOMAIN HERMES_HOSTNAME ACME_EMAIL; do
  if [ -z "${!v}" ] || [ "${!v}" = "null" ]; then
    echo "error: $v missing in $CONFIG (check cluster/mesh/acme keys)" >&2
    exit 1
  fi
done

export CLUSTER_DOMAIN HERMES_HOSTNAME ACME_EMAIL

echo "rendering with:"
printf "  %-18s %s\n" CLUSTER_DOMAIN "$CLUSTER_DOMAIN"
printf "  %-18s %s\n" HERMES_HOSTNAME "$HERMES_HOSTNAME"
printf "  %-18s %s\n" ACME_EMAIL "$ACME_EMAIL"
echo

# ---------- apply -----------------------------------------------------------

# envsubst with explicit varlist avoids accidentally chewing any literal
# $-sequences in upstream manifest contents.
SUBST_VARS='${CLUSTER_DOMAIN} ${HERMES_HOSTNAME} ${ACME_EMAIL}'

apply_dir() {
  local name="$1"
  local dir="$ATRIUM_DIR/deploy/$name"
  [ -d "$dir" ] || { echo "error: $dir not found" >&2; exit 1; }
  echo "=== apply deploy/$name/ ==="
  kubectl kustomize "$dir" | envsubst "$SUBST_VARS" | kubectl apply -f -
  echo
}

case "${1:-all}" in
  all)      apply_dir platform; apply_dir hermes ;;
  platform) apply_dir platform ;;
  hermes)   apply_dir hermes ;;
  *)        echo "usage: $0 [all|platform|hermes]" >&2; exit 1 ;;
esac

echo "done."
