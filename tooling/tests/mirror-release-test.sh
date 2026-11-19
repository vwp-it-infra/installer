#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_DIR}/mirror-release.sh"
TEST_DIR="$(mktemp -d)"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }

[[ -f "$SCRIPT" ]] || fail "mirror-release.sh has not been implemented"
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/auth directory"
export PODMAN_TEST_LOG="$TEST_DIR/podman.log"
cat > "$TEST_DIR/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>\n' "$@" >> "$PODMAN_TEST_LOG"
case "$1" in
  info) exit "${PODMAN_TEST_INFO_EXIT:-0}" ;;
  build) exit "${PODMAN_TEST_BUILD_EXIT:-0}" ;;
  run) exit "${PODMAN_TEST_RUN_EXIT:-0}" ;;
  *) echo "Unexpected podman command: $1" >&2; exit 99 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/podman"
export PATH="$TEST_DIR/bin:$PATH"
AUTHFILE="$TEST_DIR/auth directory/auth.json"
printf '%s\n' '{"auths":{"quay.io":{},"vwpinf-docker.jfrog.devstack.vwgroup.com":{}}}' > "$AUTHFILE"
cp "$AUTHFILE" "$TEST_DIR/original-auth.json"

bash "$SCRIPT" --help > "$TEST_DIR/help"
contains "$TEST_DIR/help" "--release"
contains "$TEST_DIR/help" "--arch"
[[ ! -e "$PODMAN_TEST_LOG" ]] || fail "help contacted Podman"
echo "PASS: help needs no credentials or Podman"

bash "$SCRIPT" --release 4.22.20 --arch arm64 \
  --authfile "$AUTHFILE" --work-dir "$TEST_DIR/work directory" --dry-run > "$TEST_DIR/output"
CONFIG="$TEST_DIR/work directory/imageset-config.yaml"
contains "$CONFIG" "mirror.openshift.io/v2alpha1"
contains "$CONFIG" 'name: stable-4.22'
contains "$CONFIG" 'minVersion: "4.22.20"'
contains "$CONFIG" 'maxVersion: "4.22.20"'
contains "$CONFIG" '- arm64'
contains "$PODMAN_TEST_LOG" "<--dry-run>"
contains "$PODMAN_TEST_LOG" "<--v2>"
contains "$PODMAN_TEST_LOG" "<${AUTHFILE}:/run/secrets/registry-auth.json:ro>"
contains "$PODMAN_TEST_LOG" "<$TEST_DIR/work directory:/work>"
contains "$PODMAN_TEST_LOG" "<file:///work>"
contains "$PODMAN_TEST_LOG" "<docker://vwpinf-docker.jfrog.devstack.vwgroup.com>"
if grep -Fq '<--tty>' "$PODMAN_TEST_LOG"; then
  fail "redirected output unexpectedly requested a terminal"
fi
cmp -s "$AUTHFILE" "$TEST_DIR/original-auth.json" || fail "credentials were modified"
echo "PASS: selected release/architecture, dry-run and read-only credentials reach the runner"

: > "$PODMAN_TEST_LOG"
case "$(uname -s)" in
  Darwin)
    script -q "$TEST_DIR/terminal.log" bash "$SCRIPT" --authfile "$AUTHFILE" \
      --work-dir "$TEST_DIR/terminal" --dry-run > /dev/null
    ;;
  *)
    printf -v terminal_command '%q ' bash "$SCRIPT" --authfile "$AUTHFILE" \
      --work-dir "$TEST_DIR/terminal" --dry-run
    script -q -e -c "$terminal_command" "$TEST_DIR/terminal.log" > /dev/null
    ;;
esac
contains "$PODMAN_TEST_LOG" '<--tty>'
echo "PASS: an interactive terminal enables native image progress"

: > "$PODMAN_TEST_LOG"
bash "$SCRIPT" --release 4.21.34 --arch multi \
  --authfile "$AUTHFILE" --work-dir "$TEST_DIR/multi" > "$TEST_DIR/output"
contains "$TEST_DIR/multi/imageset-config.yaml" '- multi'
contains "$TEST_DIR/multi/imageset-config.yaml" 'name: stable-4.21'
contains "$PODMAN_TEST_LOG" '<OCP_MINOR=4.21>'
if grep -Fq '<--dry-run>' "$PODMAN_TEST_LOG"; then
  fail "real mirror unexpectedly used --dry-run"
fi
touch "$TEST_DIR/multi/keep-workspace"
bash "$SCRIPT" --release 4.21.34 --arch multi \
  --authfile "$AUTHFILE" --work-dir "$TEST_DIR/multi" > "$TEST_DIR/output"
[[ -f "$TEST_DIR/multi/keep-workspace" ]] || fail "resume removed the workspace"
echo "PASS: another release and multi-architecture mirror can resume without losing state"

: > "$PODMAN_TEST_LOG"
if bash "$SCRIPT" --release 4.22.20 --arch amd64 \
  --authfile "$AUTHFILE" --work-dir "$TEST_DIR/multi" > "$TEST_DIR/output" 2>&1; then
  fail "accepted an existing workspace for a different selection"
fi
[[ ! -s "$PODMAN_TEST_LOG" ]] || fail "workspace conflict contacted Podman"
echo "PASS: a conflicting workspace is rejected before Podman operations"

for args in '--release invalid' '--arch x86_64' '--release' '--unknown' '--registry https://example.com'; do
  : > "$PODMAN_TEST_LOG"
  # Deliberately split these fixed invalid CLI fixtures.
  # shellcheck disable=SC2086
  if bash "$SCRIPT" $args --authfile "$AUTHFILE" --work-dir "$TEST_DIR/invalid" > "$TEST_DIR/output" 2>&1; then
    fail "accepted invalid arguments: $args"
  fi
  [[ ! -s "$PODMAN_TEST_LOG" ]] || fail "invalid arguments contacted Podman"
done
printf '%s\n' '{"auths":{"quay.io":{}}}' > "$TEST_DIR/incomplete-auth.json"
if bash "$SCRIPT" --authfile "$TEST_DIR/incomplete-auth.json" \
  --work-dir "$TEST_DIR/invalid-auth" > "$TEST_DIR/output" 2>&1; then
  fail "accepted credentials without the destination registry"
fi
[[ ! -s "$PODMAN_TEST_LOG" ]] || fail "invalid credentials contacted Podman"
echo "PASS: invalid inputs and incomplete credentials fail before external operations"

: > "$PODMAN_TEST_LOG"
mkdir -p "$TEST_DIR/auth-in-workspace"
cp "$AUTHFILE" "$TEST_DIR/auth-in-workspace/auth.json"
if bash "$SCRIPT" --authfile "$TEST_DIR/auth-in-workspace/auth.json" \
  --work-dir "$TEST_DIR/auth-in-workspace" > "$TEST_DIR/output" 2>&1; then
  fail "accepted credentials inside the writable workspace"
fi
cmp -s "$TEST_DIR/auth-in-workspace/auth.json" "$TEST_DIR/original-auth.json" ||
  fail "credentials inside the workspace were modified"
[[ ! -s "$PODMAN_TEST_LOG" ]] || fail "unsafe credential mount contacted Podman"
echo "PASS: credentials cannot also be exposed through the writable workspace"

for stage in INFO BUILD RUN; do
  : > "$PODMAN_TEST_LOG"
  if env "PODMAN_TEST_${stage}_EXIT=42" bash "$SCRIPT" \
    --authfile "$AUTHFILE" --work-dir "$TEST_DIR/failure-$stage" > "$TEST_DIR/output" 2>&1; then
    fail "ignored Podman $stage failure"
  fi
  if [[ "$stage" != RUN ]] && grep -Fq '<run>' "$PODMAN_TEST_LOG"; then
    fail "started mirror after Podman $stage failure"
  fi
  if grep -Fq 'Mirror completed' "$TEST_DIR/output"; then
    fail "reported success after Podman $stage failure"
  fi
done
echo "PASS: Podman failures stop execution without reporting success"
