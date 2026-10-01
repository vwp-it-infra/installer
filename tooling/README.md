# VW OpenShift installer timeout patch — tooling

This branch (`vw-tooling`) holds build/sync scripts only. Patched installer source lives on carrier branches `release-4.x-timeout-patch` in the same fork.

**Warning:** A custom `openshift-install` image is **not supported by Red Hat**. Longer timeouts do not fix slow bootstrap root causes (mirror auth, quay.io fallback, vSphere performance). Check bootstrap logs before relying on overrides.

## Prerequisites

- Linux **amd64** build host with `git`, `podman`, `jq`, and network to GitHub + JFrog (`pf34-docker.jfrog.devstack.vwgroup.com`). No quay.io required.
- Registry login (do not commit credentials):

  ```bash
  podman login pf34-docker.jfrog.devstack.vwgroup.com -u '<your-user>' --password-stdin <<<"$JFROG_TOKEN"
  # or: --authfile ~/.config/containers/auth.json
  ```
- Windows jumpbox with `oc` and access to the **mirrored** release image.
- Fork clone with carrier branches pushed to `origin`.

## End-to-end flow

1. **Jumpbox (PowerShell):** extract params from mirrored release:

   ```powershell
   .\Get-InstallerBuildParams.ps1 `
     -ReleaseImageMirror "pf34-docker.jfrog.devstack.vwgroup.com/openshift/release-images@sha256:…" `
     -OutputPath installer-build-params.json
   ```

2. **Build host:** copy `installer-build-params.json`, run:

   ```bash
   ./vw-build.sh --params-file installer-build-params.json --authfile ~/.config/containers/auth.json
   ```

3. **Hive / ACM:** use printed `installerImageOverride` (by digest) and `installerEnv` on `ClusterDeployment.spec.provisioning`.

## Timeout overrides (opt-in)

Full reference: **[installer-timeout-env.md](installer-timeout-env.md)** — phase order, value format, Hive YAML, and VW defaults for the **15m provisioning** wall and slow bootstrap API VIP / keepalived (~20m).

Summary:

| Variable | Purpose |
|----------|---------|
| `OPENSHIFT_INSTALL_NETWORK_TIMEOUT` | CAPI infrastructure ready (default 15m) |
| `OPENSHIFT_INSTALL_MACHINE_PROVISION_TIMEOUT` | Control-plane machines (default 15m; after platform `Timeouts`) |
| `OPENSHIFT_INSTALL_API_TIMEOUT` | Bootstrap Kubernetes API (default 20m) |
| `OPENSHIFT_INSTALL_BOOTSTRAP_TIMEOUT` | Bootstrap complete (default 45m / 60m vSphere+baremetal) |
| `OPENSHIFT_INSTALL_INSTALL_COMPLETE_TIMEOUT` | Cluster init **and** operator stability (defaults 40m/60m and 30m) |

Invalid or unset values keep upstream defaults. Maximum override: **3h**. For slow provisioning, start with **45m** on network + machine provision and **30m** on API timeout (see linked doc).

## Sync carriers with upstream

Add upstream once:

```bash
git remote add upstream https://github.com/openshift/installer.git
```

From the **installer repo root** (not only this branch):

```bash
/path/to/tooling/vw-sync.sh 4.21 --push
/path/to/tooling/vw-sync.sh all --push
```

Stops on rebase conflict; never auto-resolves.

## Z-stream builds

`vw-build.sh` checks out the payload `installerCommit`, cherry-picks the VW patch from the matching carrier, tags `vw/v<version>-tp.<revision>`, builds, and pushes `openshift/installer:<version>-tp.<revision>`.

Dry-run:

```bash
./vw-build.sh --params-file installer-build-params.json --dry-run
```

## Troubleshooting

- **Cherry-pick failed:** payload commit may not match carrier base; re-sync carrier or bump patch revision.
- **CAPI binary extract failed:** mirrored `installer-artifacts` often only ships `openshift-install` (no kube-apiserver/etcd). `vw-build.sh` continues with `SKIP_ENVTEST=y` and in-tree `make -C cluster-api all`.
- **Podman volume format error on macOS:** ensure `prepare_source_tree` git output stays on stderr (worktree progress must not pollute the captured path).
- **`go: not found` in builder:** use `bash -c` (not `bash -lc`) so the official `golang` image PATH is preserved.
- **`zip: not found` in hack/build.sh:** `vw-build.sh` installs `zip` in the builder container before `hack/build.sh`; use a custom image from `Containerfile.builder` to avoid repeated `apt-get`.
- **`no space left on device` during `go build`:** the Podman VM disk is full. `vw-build.sh` puts `GOCACHE`/`GOTMPDIR` on the host under `.vw-build/run.*/go-build-cache`. Also run `podman system prune -a` (careful), remove old `.vw-build/run.*` dirs, or grow the Podman machine disk in Podman Desktop settings (~40GB+ recommended for installer builds).
- **Install still hits 15m:** confirm Hive provision pod env and image digest; search logs for `Using OPENSHIFT_INSTALL_`.

## Adding OpenShift 4.24+

1. Track `upstream/release-4.24`, create `release-4.24-timeout-patch` with the patch commit.
2. Extend `VERSION_RE` in `vw-build.sh`.
3. Run tests and first z-stream build.
