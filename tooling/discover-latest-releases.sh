#!/usr/bin/env bash
# Print digest-pinned release-images refs for the latest z-stream tag per minor 4.20–4.23.
set -euo pipefail

REGISTRY="pf34-docker.jfrog.devstack.vwgroup.com"
IMAGE="${REGISTRY}/openshift/release-images"
AUTHFILE="${1:-}"

auth_args=()
[[ -n "$AUTHFILE" && -f "$AUTHFILE" ]] && auth_args=(--authfile "$AUTHFILE")

tags_json="$(skopeo list-tags "${auth_args[@]}" "docker://${IMAGE}")"
for minor in 20 21 22 23; do
  best="$(echo "$tags_json" | jq -r '.Tags[]' | grep -E "^4\\.${minor}\\.[0-9]+" | sort -V | tail -1 || true)"
  if [[ -z "$best" ]]; then
    echo "warn: no tag for 4.${minor}.x on ${IMAGE}; skipping" >&2
    continue
  fi
  digest="$(skopeo inspect "${auth_args[@]}" "docker://${IMAGE}:${best}" | jq -r .Digest)"
  echo "4.${minor} ${best} ${IMAGE}@${digest}"
done
