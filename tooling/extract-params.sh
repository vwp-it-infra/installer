#!/usr/bin/env bash
# Extract installer-build-params.json from a digest-pinned mirrored release image.
set -euo pipefail

REGISTRY_HOST="pf34-docker.jfrog.devstack.vwgroup.com"
RELEASE_REPO="${REGISTRY_HOST}/openshift/release-images"

usage() {
  echo "Usage: $0 --release-image REF --output PATH [--authfile PATH]"
  echo "  REF must be ${RELEASE_REPO}@sha256:..."
  exit 1
}

RELEASE_IMAGE=""
OUTPUT=""
AUTHFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-image) RELEASE_IMAGE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --authfile) AUTHFILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown: $1"; usage ;;
  esac
done

[[ -n "$RELEASE_IMAGE" && -n "$OUTPUT" ]] || usage
[[ "$RELEASE_IMAGE" == "${REGISTRY_HOST}"* ]] || { echo "release image must be on ${REGISTRY_HOST}" >&2; exit 1; }

oc_args=()
[[ -n "$AUTHFILE" ]] && oc_args=(--registry-config "$AUTHFILE")

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

oc "${oc_args[@]}" image extract "$RELEASE_IMAGE" --path "$tmpdir:/" >/dev/null

meta="$tmpdir/release-manifests/release-metadata"
refs="$tmpdir/release-manifests/image-references"
[[ -f "$meta" && -f "$refs" ]] || { echo "missing release-manifests in image" >&2; exit 1; }

version="$(grep -E '^version=' "$meta" | head -1 | cut -d= -f2-)"
installer_commit="$(grep -E '^Metadata:installer\.git\.commit=' "$meta" | head -1 | cut -d= -f2-)"
if [[ -z "$installer_commit" ]]; then
  installer_commit="$(grep -E '^Metadata:installer-commit=' "$meta" | head -1 | cut -d= -f2-)"
fi
[[ ${#installer_commit} -eq 40 ]] || { echo "invalid installer commit in metadata" >&2; exit 1; }

installer_ref="$(grep -A3 'name: installer' "$refs" | grep 'reference:' | head -1 | awk '{print $2}')"
[[ -n "$installer_ref" ]] || { echo "installer reference not found" >&2; exit 1; }

release_source="$(grep -E '^release\.image=' "$meta" | head -1 | cut -d= -f2- || true)"
[[ -n "$release_source" ]] || release_source="$RELEASE_IMAGE"

# Mirror installer component by digest (same blob as upstream payload).
installer_mirror="$installer_ref"
if [[ "$installer_ref" == *@sha256:* ]]; then
  installer_mirror="${REGISTRY_HOST}/openshift/release@${installer_ref#*@}"
elif [[ "$installer_ref" == quay.io/* ]]; then
  echo "error: installer reference must include digest" >&2
  exit 1
fi

jq -n \
  --arg schemaVersion "1" \
  --arg ocpVersion "$version" \
  --arg releaseImageSource "$release_source" \
  --arg releaseImageMirror "$RELEASE_IMAGE" \
  --arg installerSourceRepo "https://github.com/openshift/installer" \
  --arg installerCommit "$installer_commit" \
  --arg installerImageSource "$installer_ref" \
  --arg installerImageMirror "$installer_mirror" \
  '{
    schemaVersion: ($schemaVersion|tonumber),
    ocpVersion: $ocpVersion,
    releaseImageSource: $releaseImageSource,
    releaseImageMirror: $releaseImageMirror,
    installerSourceRepo: $installerSourceRepo,
    installerCommit: $installerCommit,
    installerImageSource: $installerImageSource,
    installerImageMirror: $installerImageMirror
  }' > "$OUTPUT"

echo "Wrote $OUTPUT (OCP $version, installer $installer_commit)"
