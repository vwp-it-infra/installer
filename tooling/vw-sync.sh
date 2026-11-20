#!/usr/bin/env bash
# Sync upstream release branches and rebase VW installer patch carriers.
set -euo pipefail

usage() {
  echo "Usage: $0 <4.20|4.21|4.22|4.23|all> [--push]"
  exit 1
}

PUSH=false
TARGET="${1:-}"
[[ -n "$TARGET" ]] || usage
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH=true ;;
    *) usage ;;
  esac
  shift
done

if ! git remote get-url upstream &>/dev/null; then
  echo "error: git remote 'upstream' must point at github.com/openshift/installer" >&2
  exit 1
fi

sync_one() {
  local minor="$1"
  local base="release-${minor}"
  local carrier="${base}-timeout-patch"

  echo "==> Syncing ${base}"
  git fetch upstream origin
  git checkout "$base"
  git merge --ff-only "upstream/${base}"
  if $PUSH; then
    git push origin "$base"
  fi

  echo "==> Rebasing ${carrier} onto ${base}"
  git checkout "$carrier"
  if ! git rebase "$base"; then
    echo "error: rebase conflict on ${carrier}; resolve manually, do not auto-merge" >&2
    exit 1
  fi
  if $PUSH; then
    git push --force-with-lease origin "$carrier"
  fi

  local timeout_count auth_count commits
  timeout_count="$(git log --format=%B "${base}..${carrier}" | grep -c '^VW-Patch: timeout-overrides$' || true)"
  auth_count="$(git log --format=%B "${base}..${carrier}" | grep -c '^VW-Patch: rhcos-download-auth$' || true)"
  if [[ "$timeout_count" != "1" || "$auth_count" -gt 1 ]]; then
    echo "error: expected one timeout patch and at most one RHCOS auth patch on ${carrier}" >&2
    exit 1
  fi
  commits="$(git rev-list --count "${base}..${carrier}")"
  if [[ "$commits" != "$((timeout_count + auth_count))" ]]; then
    echo "error: unexpected unlabelled patch commits on ${carrier}" >&2
    exit 1
  fi
  echo "OK ${carrier} is ${base} + ${commits} patch commits"
}

case "$TARGET" in
  4.20|4.21|4.22|4.23) sync_one "$TARGET" ;;
  all)
    for m in 4.20 4.21 4.22 4.23; do
      sync_one "$m"
    done
    ;;
  *) usage ;;
esac
