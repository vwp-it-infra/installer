#!/usr/bin/env bash
# Mirror an OpenShift release to JFrog using oc-mirror v2 inside Podman.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="4.22.20"
ARCH="amd64"
REGISTRY="vwpinf-docker.jfrog.devstack.vwgroup.com"
AUTHFILE=""
WORK_DIR=""
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: bash tooling/mirror-release.sh --authfile PATH [options]

Options:
  --release VERSION   OpenShift release (default: 4.22.20)
  --arch ARCH         Payload architecture: amd64, arm64, ppc64le, s390x, multi
                      (default: amd64; independent of the Podman VM architecture)
  --registry HOST     Destination registry, optionally with a port
                      (default: vwpinf-docker.jfrog.devstack.vwgroup.com)
  --authfile PATH     Registry auth JSON containing Red Hat/Quay and JFrog access
  --work-dir DIR      Persistent workspace (default: .vw-build/mirror/HOST/VERSION-ARCH)
  --dry-run          Discover images and print the plan without uploading payloads
  -h, --help         Show this help

Requires a running Podman machine on macOS, jq, internet and JFrog access.
The runner is built locally from UBI9 and an official checksum-verified oc-mirror
binary. Dry-run still downloads the runner and reads remote release metadata.
Interactive terminals show native per-image and overall mirroring progress.
No cluster configuration is applied.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release|--arch|--registry|--authfile|--work-dir)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value"
      case "$1" in
        --release) RELEASE="$2" ;;
        --arch) ARCH="$2" ;;
        --registry) REGISTRY="$2" ;;
        --authfile) AUTHFILE="$2" ;;
        --work-dir) WORK_DIR="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
done

[[ "$RELEASE" =~ ^4\.[0-9]+\.[0-9]+$ ]] || die "release must have the form 4.MINOR.PATCH"
case "$ARCH" in
  amd64|arm64|ppc64le|s390x|multi) ;;
  *) die "unsupported architecture: $ARCH" ;;
esac
[[ "$REGISTRY" =~ ^[a-z0-9]+([.-][a-z0-9]+)*(:[0-9]+)?$ ]] ||
  die "registry must be a hostname with an optional port, without a scheme or path"
[[ -n "$AUTHFILE" && -f "$AUTHFILE" && -r "$AUTHFILE" ]] ||
  die "--authfile must point to a readable registry auth JSON file"

for tool in jq podman; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
if ! jq -e --arg registry "$REGISTRY" \
  '.auths | type == "object" and has("quay.io") and has($registry)' "$AUTHFILE" >/dev/null; then
  die "authfile must contain auths entries for quay.io and $REGISTRY"
fi
AUTHFILE="$(cd "$(dirname "$AUTHFILE")" && pwd -P)/$(basename "$AUTHFILE")"
MINOR="${RELEASE%.*}"
IMAGE="localhost/vw-oc-mirror:${MINOR}"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/../.vw-build/mirror/${REGISTRY}/${RELEASE}-${ARCH}}"
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
case "$AUTHFILE" in
  "$WORK_DIR"/*) die "authfile must be outside the writable workspace" ;;
esac

CONFIG="$(cat <<EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  platform:
    architectures:
      - ${ARCH}
    channels:
      - name: stable-${MINOR}
        minVersion: "${RELEASE}"
        maxVersion: "${RELEASE}"
    graph: false
EOF
)"
CONFIG_FILE="${WORK_DIR}/imageset-config.yaml"
DESTINATION_FILE="${WORK_DIR}/destination"
if [[ -f "$CONFIG_FILE" && "$(cat "$CONFIG_FILE")" != "$CONFIG" ]]; then
  die "workspace contains a different release or architecture; choose another --work-dir"
fi
if [[ -f "$DESTINATION_FILE" && "$(cat "$DESTINATION_FILE")" != "$REGISTRY" ]]; then
  die "workspace belongs to another destination registry; choose another --work-dir"
fi
printf '%s\n' "$CONFIG" > "$CONFIG_FILE"
printf '%s\n' "$REGISTRY" > "$DESTINATION_FILE"

podman info >/dev/null || die "Podman is unavailable; start your existing Podman machine first"
mkdir -p "$WORK_DIR/runner-context"
echo "[mirror-release] Building native Podman runner; release payload: ${RELEASE}/${ARCH}"
podman build --pull=always \
  --build-arg "OCP_MINOR=${MINOR}" \
  -f "${SCRIPT_DIR}/Containerfile.oc-mirror" \
  -t "$IMAGE" "$WORK_DIR/runner-context" ||
  die "failed to build the oc-mirror runner"

MIRROR_ARGS=(
  --config /work/imageset-config.yaml
  --authfile /run/secrets/registry-auth.json
  --workspace file:///work
  --v2
)
if $DRY_RUN; then
  MIRROR_ARGS+=(--dry-run)
fi

RUN_ARGS=(--rm)
if [[ -t 1 && -t 2 ]]; then
  RUN_ARGS+=(--tty)
fi

echo "[mirror-release] Destination: ${REGISTRY}; workspace: ${WORK_DIR}"
podman run "${RUN_ARGS[@]}" \
  --volume "${WORK_DIR}:/work" \
  --volume "${AUTHFILE}:/run/secrets/registry-auth.json:ro" \
  "$IMAGE" "${MIRROR_ARGS[@]}" "docker://${REGISTRY}" ||
  die "oc-mirror failed; workspace retained at ${WORK_DIR}"

if $DRY_RUN; then
  echo "[mirror-release] Dry-run completed; no payload images uploaded."
else
  echo "[mirror-release] Mirror completed."
fi
echo "[mirror-release] Inspect mappings and generated resources under ${WORK_DIR}/working-dir."
