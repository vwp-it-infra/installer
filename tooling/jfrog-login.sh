#!/usr/bin/env bash
set -euo pipefail
REG="pf34-docker.jfrog.devstack.vwgroup.com"
USER="${JFROG_USER:-dlxp2nt}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTHFILE="${AUTHFILE:-${REPO_ROOT}/.vw-build/podman-auth.json}"
TOKEN_FILE="${TOKEN_FILE:-${REPO_ROOT}/.vw-build/jfrog-token}"

mkdir -p "$(dirname "$AUTHFILE")"
token="${JFROG_TOKEN:-}"
if [[ -z "$token" && -f "$TOKEN_FILE" ]]; then
  token="$(tr -d '\n' < "$TOKEN_FILE")"
fi
if [[ -z "$token" ]]; then
  echo "Set JFROG_TOKEN or create ${TOKEN_FILE} (chmod 600) with the reference token." >&2
  exit 1
fi
echo "$token" | podman login "$REG" -u "$USER" --password-stdin --authfile "$AUTHFILE"
echo "Auth written to ${AUTHFILE}"
