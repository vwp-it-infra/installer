#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_REPO="${INSTALLER_REPO:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
AUTHFILE="${1:-}"

if [[ -z "$AUTHFILE" || ! -f "$AUTHFILE" ]]; then
  echo "Usage: JFROG_TOKEN=... $0 /path/to/auth.json" >&2
  echo "  Create auth: podman login pf34-docker.jfrog.devstack.vwgroup.com -u USER --password-stdin" >&2
  exit 1
fi

chmod +x "${SCRIPT_DIR}/discover-latest-releases.sh" "${SCRIPT_DIR}/extract-params.sh" "${SCRIPT_DIR}/vw-build.sh"

params_dir="${INSTALLER_REPO}/.vw-build/params"
mkdir -p "$params_dir"

while read -r _minor tag release_ref; do
  params="${params_dir}/${tag}.json"
  echo "=== Params for ${tag} ==="
  "${SCRIPT_DIR}/extract-params.sh" --release-image "$release_ref" --output "$params" --authfile "$AUTHFILE"
  echo "=== Build ${tag} ==="
  "${SCRIPT_DIR}/vw-build.sh" \
    --params-file "$params" \
    --authfile "$AUTHFILE" \
    --installer-repo "$INSTALLER_REPO"
done < <("${SCRIPT_DIR}/discover-latest-releases.sh" "$AUTHFILE")
