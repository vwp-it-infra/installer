#!/usr/bin/env bash
# Print digest-pinned release-images refs for the latest z-stream tag per minor 4.20–4.23.
set -euo pipefail

REGISTRY="pf34-docker.jfrog.devstack.vwgroup.com"
IMAGE="${REGISTRY}/openshift/release-images"
AUTHFILE="${1:-}"

skopeo_args=(list-tags "docker://${IMAGE}")
[[ -n "$AUTHFILE" ]] && skopeo_args=(--authfile "$AUTHFILE" "${skopeo_args[@]}")

tags_json="$(skopeo "${skopeo_args[@]}")"
for minor in 20 21 22 23; do
  best="$(echo "$tags_json" | jq -r '.Tags[]' | grep -E "^4\\.${minor}\\.[0-9]+\$" | sort -V | tail -1 || true)"
  if [[ -z "$best" ]]; then
    echo "error: no tag found for 4.${minor}.x on ${IMAGE}" >&2
    exit 1
  fi
  digest="$(skopeo inspect "docker://${IMAGE}:${best}" ${AUTHFILE:+--authfile "$AUTHFILE"} | jq -r .Digest)"
  echo "4.${minor} ${best} ${IMAGE}@${digest}"
done
