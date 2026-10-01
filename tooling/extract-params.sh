#!/usr/bin/env bash
# Extract installer-build-params.json from a digest-pinned mirrored release image.
set -euo pipefail

REGISTRY_HOST="pf34-docker.jfrog.devstack.vwgroup.com"
RELEASE_REPO="${REGISTRY_HOST}/openshift/release-images"
PODMAN_PLATFORM="linux/amd64"

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

pull_args=(pull --platform "$PODMAN_PLATFORM")
[[ -n "$AUTHFILE" ]] && pull_args+=(--authfile "$AUTHFILE")
podman "${pull_args[@]}" "$RELEASE_IMAGE" >/dev/null

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cid="$(podman create --platform "$PODMAN_PLATFORM" "$RELEASE_IMAGE")"
trap 'podman rm -f "$cid" >/dev/null 2>&1; rm -rf "$tmpdir"' EXIT
podman cp "$cid:/release-manifests/release-metadata" "$tmpdir/"
podman cp "$cid:/release-manifests/image-references" "$tmpdir/"
podman rm -f "$cid" >/dev/null
cid=""

meta="$tmpdir/release-metadata"
refs="$tmpdir/image-references"
[[ -f "$meta" && -f "$refs" ]] || { echo "missing release-manifests in image" >&2; exit 1; }

version="$(jq -r '.version' "$meta")"
[[ -n "$version" && "$version" != null ]] || { echo "missing version in release-metadata" >&2; exit 1; }

installer_commit="$(jq -r '.spec.tags[] | select(.name=="installer") | .annotations["io.openshift.build.commit.id"]' "$refs")"
installer_ref="$(jq -r '.spec.tags[] | select(.name=="installer") | .from.name' "$refs")"
[[ ${#installer_commit} -eq 40 ]] || { echo "invalid installer commit" >&2; exit 1; }
[[ -n "$installer_ref" && "$installer_ref" != null ]] || { echo "installer image ref not found" >&2; exit 1; }

if [[ "$installer_ref" != *@sha256:* ]]; then
  echo "error: installer reference must include digest" >&2
  exit 1
fi
installer_mirror="${REGISTRY_HOST}/openshift/release@${installer_ref#*@}"

artifacts_ref="$(jq -r '.spec.tags[] | select(.name=="installer-artifacts") | .from.name' "$refs")"
[[ -n "$artifacts_ref" && "$artifacts_ref" != null && "$artifacts_ref" == *@sha256:* ]] || {
  echo "installer-artifacts image ref not found" >&2
  exit 1
}
installer_artifacts_mirror="${REGISTRY_HOST}/openshift/release@${artifacts_ref#*@}"

release_source="$(jq -r '.metadata.url // empty' "$meta")"
if [[ -z "$release_source" ]]; then
  release_source="$RELEASE_IMAGE"
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
  --arg installerArtifactsImageMirror "$installer_artifacts_mirror" \
  '{
    schemaVersion: ($schemaVersion|tonumber),
    ocpVersion: $ocpVersion,
    releaseImageSource: $releaseImageSource,
    releaseImageMirror: $releaseImageMirror,
    installerSourceRepo: $installerSourceRepo,
    installerCommit: $installerCommit,
    installerImageSource: $installerImageSource,
    installerImageMirror: $installerImageMirror,
    installerArtifactsImageMirror: $installerArtifactsImageMirror
  }' > "$OUTPUT"

echo "Wrote $OUTPUT (OCP $version, installer $installer_commit)"
