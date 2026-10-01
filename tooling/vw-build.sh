#!/usr/bin/env bash
# Build and push a VW-patched openshift-install image for a specific z-stream payload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_HOST="pf34-docker.jfrog.devstack.vwgroup.com"
DEFAULT_PUSH_REGISTRY="${REGISTRY_HOST}/openshift/installer"
MIRROR_HOST="${REGISTRY_HOST}"
VERSION_RE='^4\.(20|21|22|23)\.[0-9]+$'
COMMIT_RE='^[0-9a-f]{40}$'

DRY_RUN=false
PARAMS_FILE=""
OCP_VERSION=""
INSTALLER_COMMIT=""
INSTALLER_BASE_IMAGE=""
RELEASE_IMAGE_MIRROR=""
PATCH_REVISION=""
AUTHFILE=""
INSTALLER_REPO=""
PUSH_REGISTRY="$DEFAULT_PUSH_REGISTRY"
BUILDER_IMAGE=""
SKIP_ENVTEST="y"
WORK_ROOT=""

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \?//'
  echo ""
  echo "Options:"
  echo "  --params-file PATH          installer-build-params.json (schemaVersion 1)"
  echo "  --ocp-version VER           e.g. 4.21.34"
  echo "  --installer-commit SHA        40-char git commit"
  echo "  --installer-base-image REF    digest-pinned mirror installer image"
  echo "  --release-image-mirror REF    digest-pinned mirrored release (labels only)"
  echo "  --patch-revision N            default: read from carrier commit trailer"
  echo "  --installer-repo PATH         fork clone (default: parent of tooling/)"
  echo "  --authfile PATH               podman auth json"
  echo "  --push-registry REPO          default ${DEFAULT_PUSH_REGISTRY}"
  echo "  --builder-image IMAGE         override golang builder image"
  echo "  --skip-envtest y|n            default y"
  echo "  --work-root DIR               build worktree parent"
  echo "  --dry-run"
  exit 1
}

log() { echo "[vw-build] $*"; }
run() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

digest_from_image_ref() {
  local ref="$1"
  if [[ "$ref" == *@sha256:* ]]; then
    echo "${ref#*@}"
  else
    echo "error: image ref must be pinned by digest: $ref" >&2
    exit 1
  fi
}

minor_from_version() {
  local ver="$1"
  if [[ ! "$ver" =~ $VERSION_RE ]]; then
    echo "error: ocp version must match ${VERSION_RE}: $ver" >&2
    exit 1
  fi
  echo "4.${BASH_REMATCH[1]}"
}

default_builder_image() {
  local minor="$1"
  case "$minor" in
    4.20|4.21) echo "docker.io/library/golang:1.24.5-bookworm" ;;
    4.22) echo "docker.io/library/golang:1.25.8-bookworm" ;;
    4.23) echo "docker.io/library/golang:1.26.0-bookworm" ;;
    *) echo "error: unsupported minor $minor" >&2; exit 1 ;;
  esac
}

parse_params_file() {
  local f="$1"
  if ! command -v jq &>/dev/null; then
    echo "error: jq required to read params file" >&2
    exit 1
  fi
  local schema
  schema="$(jq -r '.schemaVersion // 0' "$f")"
  if [[ "$schema" != "1" ]]; then
    echo "error: params file schemaVersion must be 1" >&2
    exit 1
  fi
  OCP_VERSION="$(jq -r '.ocpVersion' "$f")"
  INSTALLER_COMMIT="$(jq -r '.installerCommit' "$f")"
  INSTALLER_BASE_IMAGE="$(jq -r '.installerImageMirror' "$f")"
  RELEASE_IMAGE_MIRROR="$(jq -r '.releaseImageMirror' "$f")"
}

validate_inputs() {
  [[ "$OCP_VERSION" =~ $VERSION_RE ]] || { echo "error: invalid ocp version"; exit 1; }
  [[ "$INSTALLER_COMMIT" =~ $COMMIT_RE ]] || { echo "error: invalid installer commit"; exit 1; }
  [[ "$INSTALLER_BASE_IMAGE" == "${MIRROR_HOST}"* ]] || {
    echo "error: installer base image must be on ${MIRROR_HOST}" >&2
    exit 1
  }
  digest_from_image_ref "$INSTALLER_BASE_IMAGE" >/dev/null
  if [[ -n "$RELEASE_IMAGE_MIRROR" ]]; then
    digest_from_image_ref "$RELEASE_IMAGE_MIRROR" >/dev/null
  fi
  if [[ -z "$INSTALLER_REPO" ]]; then
    INSTALLER_REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
  fi
  if [[ -z "$WORK_ROOT" ]]; then
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vw-build.XXXXXX")"
  fi
  local minor
  minor="$(minor_from_version "$OCP_VERSION")"
  if [[ -z "$BUILDER_IMAGE" ]]; then
    BUILDER_IMAGE="$(default_builder_image "$minor")"
  fi
}

ensure_clean_repo() {
  if ! git -C "$INSTALLER_REPO" diff --quiet || ! git -C "$INSTALLER_REPO" diff --cached --quiet; then
    echo "error: installer repo has uncommitted changes: $INSTALLER_REPO" >&2
    exit 1
  fi
}

patch_revision_from_carrier() {
  local minor="$1"
  local carrier="release-${minor}-timeout-patch"  # minor is e.g. 4.21
  git -C "$INSTALLER_REPO" fetch origin "$carrier" 2>/dev/null || true
  local msg
  msg="$(git -C "$INSTALLER_REPO" log -1 --format=%B "origin/${carrier}" 2>/dev/null || git -C "$INSTALLER_REPO" log -1 --format=%B "$carrier")"
  echo "$msg" | awk -F': ' '/^VW-Patch-Revision:/{print $2; exit}'
}

prepare_source_tree() {
  local minor="$1"
  local base="release-${minor}"
  local carrier="${base}-timeout-patch"
  local wt="${WORK_ROOT}/src"

  git -C "$INSTALLER_REPO" fetch origin "$base" "$carrier" tags 2>/dev/null || true

  local base_ref="origin/${base}"
  if ! git -C "$INSTALLER_REPO" rev-parse "$base_ref" &>/dev/null; then
    base_ref="$base"
  fi
  local carrier_ref="origin/${carrier}"
  if ! git -C "$INSTALLER_REPO" rev-parse "$carrier_ref" &>/dev/null; then
    carrier_ref="$carrier"
  fi

  if ! git -C "$INSTALLER_REPO" merge-base --is-ancestor "$INSTALLER_COMMIT" "$base_ref"; then
    echo "error: installer commit $INSTALLER_COMMIT is not on ${base_ref}" >&2
    exit 1
  fi

  if [[ -d "$wt" ]]; then
    git -C "$INSTALLER_REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  fi
  run git -C "$INSTALLER_REPO" worktree add --detach "$wt" "$INSTALLER_COMMIT"

  local patch_sha
  patch_sha="$(git -C "$INSTALLER_REPO" rev-list -n 1 "${carrier_ref}" "^${base_ref}")"
  if [[ -z "$patch_sha" ]]; then
    echo "error: no patch commit found on ${carrier_ref} above ${base_ref}" >&2
    exit 1
  fi
  if ! run git -C "$wt" cherry-pick "$patch_sha"; then
    echo "error: cherry-pick failed; fix patch for this z-stream commit" >&2
    exit 1
  fi
  if ! git -C "$wt" grep -q 'package envtimeout' pkg/envtimeout/duration.go 2>/dev/null; then
    echo "error: patched tree missing pkg/envtimeout" >&2
    exit 1
  fi
  echo "$wt"
}

build_binary() {
  local wt="$1"
  local tag_version="v${OCP_VERSION}-tp.${PATCH_REVISION}"
  local base_digest
  base_digest="$(digest_from_image_ref "$INSTALLER_BASE_IMAGE")"

  log "Extracting cluster-api binaries from base installer image"
  local extract_dir="${WORK_ROOT}/extract"
  mkdir -p "$extract_dir"
  run podman create --name vw-installer-extract "${INSTALLER_BASE_IMAGE}" >/dev/null
  run podman cp vw-installer-extract:/usr/share/openshift/. "$extract_dir/openshift"
  run podman rm vw-installer-extract

  local goos goarch
  goos="$(uname -s | tr '[:upper:]' '[:lower:]')"
  goarch="$(uname -m)"
  [[ "$goarch" == "x86_64" ]] && goarch="amd64"
  [[ "$goarch" == "aarch64" ]] && goarch="arm64"
  local bindir="${wt}/cluster-api/bin/${goos}_${goarch}"
  mkdir -p "$bindir"
  if [[ -d "${extract_dir}/openshift/${goos}/${goarch}" ]]; then
    cp -a "${extract_dir}/openshift/${goos}/${goarch}/." "$bindir/"
  elif [[ -d "${extract_dir}/openshift/linux/amd64" && "$goarch" == "amd64" ]]; then
    cp -a "${extract_dir}/openshift/linux/amd64/." "$bindir/"
  else
    echo "error: could not find CAPI binaries for ${goos}/${goarch} in base image" >&2
    exit 1
  fi

  log "Building openshift-install (${tag_version}) in ${BUILDER_IMAGE}"
  local artifact_dir="${WORK_ROOT}/image-context/artifacts"
  mkdir -p "$artifact_dir"
  local out_bin="${artifact_dir}/openshift-install"
  run podman run --rm \
    -v "${wt}:/go/src/github.com/openshift/installer:Z" \
    -v "${artifact_dir}:/out:Z" \
    -w /go/src/github.com/openshift/installer \
    -e CGO_ENABLED=0 \
    -e SKIP_ENVTEST="${SKIP_ENVTEST}" \
    -e BUILD_VERSION="${tag_version}" \
    -e SOURCE_GIT_COMMIT="${INSTALLER_COMMIT}" \
    -e GOTOOLCHAIN=auto \
    "$BUILDER_IMAGE" \
    bash -lc 'hack/build.sh && go test ./pkg/envtimeout/... && cp bin/openshift-install /out/openshift-install'

  local image_tag="${PUSH_REGISTRY}:${OCP_VERSION}-tp.${PATCH_REVISION}"
  local containerfile="${SCRIPT_DIR}/Containerfile.installer"
  log "Building runtime image ${image_tag}"
  run podman build \
    -f "$containerfile" \
    --build-arg "BASE_IMAGE=${INSTALLER_BASE_IMAGE}" \
    --build-arg "OCP_VERSION=${OCP_VERSION}" \
    --build-arg "PATCH_REVISION=${PATCH_REVISION}" \
    --build-arg "INSTALLER_COMMIT=${INSTALLER_COMMIT}" \
    --build-arg "RELEASE_DIGEST=${RELEASE_IMAGE_MIRROR#*@}" \
    --build-arg "BASE_DIGEST=${base_digest}" \
    -t "$image_tag" \
    "${WORK_ROOT}/image-context"

  local auth_args=()
  if [[ -n "$AUTHFILE" ]]; then
    auth_args=(--authfile "$AUTHFILE")
  fi
  run podman run --rm "$image_tag" openshift-install version

  if $DRY_RUN; then
    log "Dry-run: would push ${image_tag} and tag vw/v${OCP_VERSION}-tp.${PATCH_REVISION}"
    return 0
  fi

  run podman push "${auth_args[@]}" "$image_tag"
  local pushed_digest
  pushed_digest="$(podman inspect --format='{{index .Digest}}' "$image_tag")"

  local fork_tag="vw/v${OCP_VERSION}-tp.${PATCH_REVISION}"
  run git -C "$wt" tag -f "$fork_tag"
  run git -C "$INSTALLER_REPO" push origin "$fork_tag"

  cat <<EOF

Pushed: ${image_tag}
Digest: ${pushed_digest}
Source tag: ${fork_tag} @ $(git -C "$wt" rev-parse HEAD)

ClusterDeployment snippet:
spec:
  provisioning:
    installerImageOverride: ${PUSH_REGISTRY}@${pushed_digest}
    installerEnv:
      - name: OPENSHIFT_INSTALL_MACHINE_PROVISION_TIMEOUT
        value: "45m"
      - name: OPENSHIFT_INSTALL_NETWORK_TIMEOUT
        value: "30m"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --params-file) PARAMS_FILE="$2"; shift 2 ;;
    --ocp-version) OCP_VERSION="$2"; shift 2 ;;
    --installer-commit) INSTALLER_COMMIT="$2"; shift 2 ;;
    --installer-base-image) INSTALLER_BASE_IMAGE="$2"; shift 2 ;;
    --release-image-mirror) RELEASE_IMAGE_MIRROR="$2"; shift 2 ;;
    --patch-revision) PATCH_REVISION="$2"; shift 2 ;;
    --installer-repo) INSTALLER_REPO="$2"; shift 2 ;;
    --authfile) AUTHFILE="$2"; shift 2 ;;
    --push-registry) PUSH_REGISTRY="$2"; shift 2 ;;
    --builder-image) BUILDER_IMAGE="$2"; shift 2 ;;
    --skip-envtest) SKIP_ENVTEST="$2"; shift 2 ;;
    --work-root) WORK_ROOT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1"; usage ;;
  esac
done

if [[ -n "$PARAMS_FILE" ]]; then
  parse_params_file "$PARAMS_FILE"
fi

validate_inputs
ensure_clean_repo

minor="$(minor_from_version "$OCP_VERSION")"
if [[ -z "$PATCH_REVISION" ]]; then
  PATCH_REVISION="$(patch_revision_from_carrier "$minor")"
fi
[[ -n "$PATCH_REVISION" ]] || { echo "error: could not determine patch revision"; exit 1; }

wt="$(prepare_source_tree "$minor")"
build_binary "$wt"
