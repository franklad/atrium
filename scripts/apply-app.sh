#!/usr/bin/env bash
#
# scripts/apply-app.sh — render and apply an atrium-shape app's deploy
# bundle against the current kubectl context.
#
# Usage:
#   ./scripts/apply-app.sh <app-name> [--path /path/to/app/repo]
#
# Conventions: see docs/app-conventions.md. By default this looks for
# the app's repo as a sibling of atrium (`../<app-name>/`). Override
# with --path.
#
# The script exports CLUSTER_DOMAIN, ACME_EMAIL, APP_NAME,
# APP_FE_HOSTNAME, APP_BE_HOSTNAME — the app's manifests reference these
# via ${VAR} placeholders, rendered by envsubst before apply.
#
# Prereqs: yq, envsubst, kubectl.

set -euo pipefail

ATRIUM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ATRIUM_DIR}/cluster.config.yaml"

# ---------- args ------------------------------------------------------------

APP_NAME=""
APP_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --path)
      APP_PATH="$2"; shift 2 ;;
    --path=*)
      APP_PATH="${1#--path=}"; shift ;;
    -h|--help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    -*)
      echo "error: unknown flag: $1" >&2; exit 1 ;;
    *)
      if [ -z "$APP_NAME" ]; then APP_NAME="$1"
      else echo "error: unexpected arg: $1" >&2; exit 1; fi
      shift ;;
  esac
done

[ -n "$APP_NAME" ] || {
  echo "error: app name required." >&2
  echo "usage: $0 <app-name> [--path /path/to/app/repo]" >&2
  exit 1
}

[ -z "$APP_PATH" ] && APP_PATH="$(cd "$ATRIUM_DIR/.." && pwd)/$APP_NAME"

# ---------- prereqs ---------------------------------------------------------

[ -f "$CONFIG" ] || {
  echo "error: $CONFIG missing — run from an atrium clone with cluster.config.yaml in place." >&2
  exit 1
}

for tool in yq envsubst kubectl; do
  command -v "$tool" >/dev/null || {
    echo "error: '$tool' not found in PATH." >&2
    [ "$tool" = yq ] && echo "       install: mise use -g yq (or brew install yq)" >&2
    exit 1
  }
done

KUSTOMIZATION="$APP_PATH/deploy/k8s/kustomization.yaml"
[ -f "$KUSTOMIZATION" ] || {
  echo "error: $KUSTOMIZATION not found." >&2
  echo "       expected an atrium-shape app at: $APP_PATH" >&2
  echo "       use --path to point at a different location." >&2
  exit 1
}

# ---------- load config + app identity --------------------------------------

CLUSTER_DOMAIN=$(yq -r '.cluster.domain // ""' "$CONFIG")
ACME_EMAIL=$(yq -r '.acme.email // ""' "$CONFIG")

# Optional per-app overrides in cluster.config.yaml.apps.<app>.{fe_hostname,be_hostname}
APP_FE_HOSTNAME=$(yq -r ".apps.${APP_NAME}.fe_hostname // \"${APP_NAME}\"" "$CONFIG")
APP_BE_HOSTNAME=$(yq -r ".apps.${APP_NAME}.be_hostname // \"api.${APP_NAME}\"" "$CONFIG")

for v in CLUSTER_DOMAIN ACME_EMAIL APP_FE_HOSTNAME APP_BE_HOSTNAME; do
  if [ -z "${!v}" ] || [ "${!v}" = "null" ]; then
    echo "error: $v resolved empty (check cluster.config.yaml)" >&2; exit 1
  fi
done

export CLUSTER_DOMAIN ACME_EMAIL
export APP_NAME APP_FE_HOSTNAME APP_BE_HOSTNAME

echo "rendering $APP_NAME with:"
printf "  %-18s %s\n" APP_PATH "$APP_PATH"
printf "  %-18s %s\n" CLUSTER_DOMAIN "$CLUSTER_DOMAIN"
printf "  %-18s %s.%s\n" APP_FE_HOSTNAME "$APP_FE_HOSTNAME" "$CLUSTER_DOMAIN"
printf "  %-18s %s.%s\n" APP_BE_HOSTNAME "$APP_BE_HOSTNAME" "$CLUSTER_DOMAIN"
printf "  %-18s %s\n" ACME_EMAIL "$ACME_EMAIL"
echo

# ---------- apply -----------------------------------------------------------

SUBST_VARS='${CLUSTER_DOMAIN} ${ACME_EMAIL} ${APP_NAME} ${APP_FE_HOSTNAME} ${APP_BE_HOSTNAME}'

echo "=== apply $APP_PATH/deploy/k8s/ ==="
kubectl kustomize "$APP_PATH/deploy/k8s" | envsubst "$SUBST_VARS" | kubectl apply -f -
echo

# ---------- next-step hint --------------------------------------------------

cat <<EOF
done.

next steps:
  1. wait for pods Ready:
       kubectl -n ${APP_NAME}-be get pods -w
  2. once the backend is up, install its skill into Hermes:
       kubectl -n hermes exec deploy/hermes -c dashboard -- \\
         /opt/hermes/.venv/bin/hermes skills install \\
           https://${APP_BE_HOSTNAME}.${CLUSTER_DOMAIN}
  3. dashboard chat will discover the skill on next session.
EOF
