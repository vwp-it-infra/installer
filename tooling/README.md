# VW OpenShift installer patch tooling

The `vw-tooling` branch holds build and sync scripts. Patched installer source lives
on `release-<OCP_MINOR>-timeout-patch` carrier branches in the same fork.
`<OCP_MINOR>` means the OpenShift major/minor release; `<OCP_VERSION>` means the full
release version. Replace placeholders in the commands below with your selected values.

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

## Mirror a release to JFrog from macOS

Use [mirror-release.sh](mirror-release.sh) to mirror a complete OpenShift release
with **oc-mirror v2 inside Podman**. It does not configure or install a cluster,
mirror additional Operator catalogs, build the patched installer, or push Git tags.
Pass the release, architecture and registry explicitly when preparing a build.
Use the script's `--help` output to inspect its current defaults.

Prerequisites:

- Podman with an existing, running machine on macOS, plus `jq`.
- Access to the Red Hat/Quay source registries, the OpenShift release graph and
  downloads, UBI package repositories, and the destination JFrog registry.
- Permission to push images into the destination registry's repository paths.
- A **separate mirroring auth JSON file outside Git**, initially copied from your
  Red Hat pull secret. Add JFrog credentials to that copy interactively:

  ```bash
  chmod 600 "$HOME/.config/containers/mirror-auth.json"
  podman login --authfile "$HOME/.config/containers/mirror-auth.json" \
    vwpinf-docker.jfrog.devstack.vwgroup.com
  ```

The file must contain `auths` entries for `quay.io` and the destination registry;
keep it outside the workspace and keep the other Red Hat entries from the pull
secret. Credential helpers from the
macOS keychain are not a substitute for credentials accessible inside the Linux
container. Do not use this push-capable auth file as a cluster pull secret.

From the installer repository root, preview the selected release and architecture:

```bash
bash tooling/mirror-release.sh \
  --release "<OCP_VERSION>" \
  --arch "<ARCH>" \
  --registry "<REGISTRY_HOST>" \
  --authfile "$HOME/.config/containers/mirror-auth.json" \
  --dry-run
```

Remove `--dry-run` to upload the images. To choose another release or architecture,
change `--release` and `--arch`; accepted architectures are `amd64`, `arm64`,
`ppc64le`, `s390x`, and `multi`. The selected release must exist in its
`stable-<OCP_MINOR>` channel. The tool runs natively in an arm64 or amd64 Podman VM,
independently of the architecture being mirrored, so an Apple Silicon Mac can
mirror an amd64 release without emulating an amd64 tool.

Use `--registry HOST[:PORT]` for another destination or `--work-dir DIR` for a
different persistent workspace. By default, state is kept in the ignored
`.vw-build/mirror/HOST/VERSION-ARCH/` directory. Reuse the same workspace to retry;
the script rejects a workspace for a different release, architecture or registry.
It never creates or starts a Podman VM and mounts the credentials read-only.

The [runner Containerfile](Containerfile.oc-mirror) builds a local UBI image with
the latest available RHEL oc-mirror binary for the selected release minor,
verified against Red Hat's published SHA-256 checksum. Builds are cached by
Podman. Even `--dry-run` can download the runner and query remote metadata, but it
does not upload release payloads. Normal mode copies the **whole selected
release**, not just the three inputs needed for an installer build.

When run in a terminal, the script enables oc-mirror's native per-image spinners
and overall image-count progress bar, including elapsed time and percentage.
This measures images processed, not bytes uploaded. Redirected output stays in
plain log format; `--dry-run` does not transfer images.

Inspect the mappings and generated resources in the workspace's `working-dir`.
**Do not assume the generated destination paths match the existing build
scripts**: `extract-params.sh`, `vw-build.sh`, and the other original helpers still
target `pf34-docker` and their existing repository layout. Adapt those separately
before building an installer from this mirror.

Safe local wrapper tests (no registry access):

```bash
bash tooling/tests/mirror-release-test.sh
```

Reference: [OpenShift documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/).
Select your release and its oc-mirror v2 documentation.

## Prepare and build a release

1. Choose the full OpenShift release and target architecture, then mirror that
   release. Use the generated mappings to identify the release, installer and
   installer-artifacts images in the destination registry.

2. Prepare the matching `release-<OCP_MINOR>-timeout-patch` carrier. Keep the
   timeout patch as a labelled commit and include the RHCOS authentication commit
   if private OVA downloads are required. Sync the carrier with upstream and
   resolve any conflicts before building.

   Patch commits use `VW-Patch: timeout-overrides` or
   `VW-Patch: rhcos-download-auth`. Put `VW-Patch-Revision: <PATCH_REVISION>` in the
   latest patch commit's message and increment it when changing the patch set.
   The sync helper accepts one timeout commit and an optional authentication commit.

3. Extract build parameters from the digest-pinned mirrored release. From the
   installer repository root, on a PowerShell jumpbox:

   ```powershell
   .\tooling\Get-InstallerBuildParams.ps1 `
     -ReleaseImageMirror "<MIRRORED_RELEASE_REPOSITORY>@sha256:<RELEASE_DIGEST>" `
     -OutputPath installer-build-params.json
   ```

   The parameter file identifies the exact payload `installerCommit` and mirrored
   build inputs. Do not substitute the current head of the upstream release branch.
   Check that the referenced installer images match the selected release.

4. Copy the parameter file to the build host and choose a new image revision.
   The default comes from the latest carrier commit's `VW-Patch-Revision`; use
   `--patch-revision` to select another unused revision. The image name is
   `openshift/installer:<OCP_VERSION>-tp.<PATCH_REVISION>`.

   Review the helper's registry settings before running it. The legacy helpers
   target `pf34-docker`; `--push-registry` changes the output repository but does
   not change the mirror-host validation for input images.

   Preview the build commands from the installer repository root:

   ```bash
   bash tooling/vw-build.sh \
     --params-file installer-build-params.json \
     --authfile "$HOME/.config/containers/auth.json" \
     --dry-run
   ```

   Build-helper dry-run still fetches Git refs, creates a source worktree and
   cherry-picks commits. It skips container build/run/push commands and Git tag
   publication, so it is not a read-only repository check.

5. Remove `--dry-run` when ready to build and publish. The helper checks out the
   exact payload commit, cherry-picks all carrier commits in order, compiles
   `openshift-install` and replaces the binary in the matching original installer
   image. It runs the timeout and RHCOS cache tests plus an installer version check.

   A normal run pushes the container image and creates/pushes the source tag
   `vw/v<OCP_VERSION>-tp.<PATCH_REVISION>`. Never reuse a published revision.
   If only an image push is authorized, use a separate build procedure instead
   of running this helper unchanged.

6. Use the published immutable image digest for
   `ClusterDeployment.spec.provisioning.installerImageOverride`. Configure
   `installerEnv` only for the optional behavior you need. Record the release,
   upstream commit, carrier commits, image digest and validation results with
   the build artifacts.

## Timeout overrides (opt-in)

See [installer-timeout-env.md](installer-timeout-env.md) for phase order, value
format, Hive configuration and timeout guidance.

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
/path/to/tooling/vw-sync.sh "<OCP_MINOR>"
/path/to/tooling/vw-sync.sh all
```

Run this from a clean source checkout. The helper updates the upstream release
branch and rebases the carrier commits onto it. It stops on conflicts without
resolving them automatically. Add `--push` only when publishing Git branch updates
is authorized; publishing a carrier is separate from publishing an installer image.

## Private RHCOS OVA downloads (opt-in)

Include the `VW-Patch: rhcos-download-auth` commit in the carrier for the selected
OpenShift minor. The builder applies it through the same cherry-pick process as
the timeout patch. Authentication is enabled at runtime through environment variables.

Configure `platform.vsphere.clusterOSImage` with the OVA URL and `?sha256=...`,
without a failure-domain template. Inject these environment variables through Hive:

| Variable | Source |
|----------|--------|
| `OPENSHIFT_INSTALL_RHCOS_DOWNLOAD_HOST` | OVA URL host, including an explicit port if present |
| `OPENSHIFT_INSTALL_RHCOS_DOWNLOAD_USERNAME` | Kubernetes Secret key `username` |
| `OPENSHIFT_INSTALL_RHCOS_DOWNLOAD_PASSWORD` | Kubernetes Secret key `password` (read-only token) |

All three values are required when authentication is configured. Credentials are
sent only to that HTTPS origin. Cross-origin and HTTP redirects are rejected;
same-origin redirects retain the normal ten-redirect limit. Other hosts and
unconfigured downloads remain anonymous. URL-embedded credentials are rejected
before logging. SHA-256 verification and the existing retry behavior remain intact.
The installer container must trust the repository's TLS chain; verification is
not disabled, and Docker pull secrets do not authenticate Generic downloads.

PCP's provisioning generator exposes this as `VSPHERE_CLUSTER_OS_IMAGE` and
`RHCOS_DOWNLOAD_AUTH=true`, securely prompts for the token, and generates
Vault/VSS plus Hive Secret references. No token belongs in `.env` or Git.
Automatic import still needs vSphere import and MarkAsTemplate privileges.

If the carrier commits exist only locally, select
`--carrier-ref release-<OCP_MINOR>-timeout-patch`; the default continues to use the remote
carrier. This option resolves the selected ref to a commit before use, and does
not push the carrier branch.

Publish the carrier branch separately when other build hosts need its commits.
The sync helper rebases both labelled patch commits when the carrier includes authentication.

## Troubleshooting

- **Cherry-pick failed:** payload commit may not match carrier base; re-sync carrier or bump patch revision.
- **CAPI binary extract failed:** mirrored `installer-artifacts` often only ships `openshift-install` (no kube-apiserver/etcd). `vw-build.sh` continues with `SKIP_ENVTEST=y` and in-tree `make -C cluster-api all`.
- **Podman volume format error on macOS:** ensure `prepare_source_tree` git output stays on stderr (worktree progress must not pollute the captured path).
- **`go: not found` in builder:** use `bash -c` (not `bash -lc`) so the official `golang` image PATH is preserved.
- **`zip: not found` in hack/build.sh:** `vw-build.sh` installs `zip` in the builder container before `hack/build.sh`; use a custom image from `Containerfile.builder` to avoid repeated `apt-get`.
- **`no space left on device` during `go build`:** the Podman VM disk is full. `vw-build.sh` puts `GOCACHE`/`GOTMPDIR` on the host under `.vw-build/run.*/go-build-cache`. Also run `podman system prune -a` (careful), remove old `.vw-build/run.*` dirs, or grow the Podman machine disk in Podman Desktop settings (~40GB+ recommended for installer builds).
- **`cmd/compile` SIGSEGV / fatal error: fault on macOS:** amd64-in-QEMU builds are fragile. `vw-build.sh` defaults to `GOMAXPROCS=1` and `-p=1` on Darwin; retry once, give Podman **8GB+ RAM**, or run the same script on a native **linux/amd64** host/CI.
- **`chmod: Operation not permitted` on runtime image:** the mirrored `openshift/release` base may run as non-root; `Containerfile.installer` uses `USER root` and `COPY --chmod=755`.
- **Install still hits 15m:** confirm Hive provision pod env and image digest; search logs for `Using OPENSHIFT_INSTALL_`.

## Add support for a new OpenShift minor

1. Track `upstream/release-<OCP_MINOR>` and prepare
   `release-<OCP_MINOR>-timeout-patch` with the required labelled patch commits.
   Adapt the patches to upstream changes and increment `VW-Patch-Revision`.
2. Extend `VERSION_RE` and `default_builder_image()` in [vw-build.sh](vw-build.sh).
   Choose a builder toolchain compatible with the new source tree's `go.mod`.
3. Update the supported-minor cases and the `all` loop in [vw-sync.sh](vw-sync.sh).
   If using automatic latest-release builds, also update the minor list in
   [discover-latest-releases.sh](discover-latest-releases.sh), which feeds
   [build-all-latest.sh](build-all-latest.sh).
4. Extract parameters from a release in the new minor, check patch application
   against its exact installer commit, run the relevant tests and build the image.
   Verify the required CAPI assets and RHCOS stream metadata before publishing.

For another z-stream release within an already supported minor, extract fresh
parameters and use the same carrier. Check that its patches apply to the new
payload commit; support for the minor does not guarantee a conflict-free build.
