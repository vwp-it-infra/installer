# Installer timeout environment variables (VW patch)

This package implements **opt-in** duration overrides for `openshift-install`. Upstream defaults are unchanged unless you set environment variables on the install.

Use a **VW-built** installer image from this fork (build scripts on git branch `vw-tooling`) and set `spec.provisioning.installerImageOverride` on the Hive `ClusterDeployment`. Stock release installer images do not include this patch.

## Value format

- Go [`time.ParseDuration`](https://pkg.go.dev/time#ParseDuration) strings, e.g. `20m`, `45m`, `1h`, `1h30m`.
- Allowed range: greater than zero, at most **3 hours** (`MaxDuration` in code).
- Invalid or empty values are ignored; the installer keeps the default for that phase and logs a warning.
- When an override applies, logs contain: `Using OPENSHIFT_INSTALL_<NAME>=<value> (default …)`.

## Install phases (what each variable controls)

Rough order during a Hive-managed install:

```text
1. Network / CAPI infrastructure ready     → OPENSHIFT_INSTALL_NETWORK_TIMEOUT
2. Control-plane machines provisioned      → OPENSHIFT_INSTALL_MACHINE_PROVISION_TIMEOUT
3. Bootstrap Kubernetes API responding     → OPENSHIFT_INSTALL_API_TIMEOUT
4. Bootstrap process complete              → OPENSHIFT_INSTALL_BOOTSTRAP_TIMEOUT
5. Cluster initialization + CO stability   → OPENSHIFT_INSTALL_INSTALL_COMPLETE_TIMEOUT
```

Platform-specific `Timeouts()` (if implemented for your IaaS) are applied **before** the env override for network and machine provision.

| Variable | Default (typical) | When to raise it |
|----------|-------------------|------------------|
| `OPENSHIFT_INSTALL_NETWORK_TIMEOUT` | 15m | CAPI / LB / network assets not ready in time |
| `OPENSHIFT_INSTALL_MACHINE_PROVISION_TIMEOUT` | 15m | **Common Hive “15m provisioning” failure** — VMs slow to become ready |
| `OPENSHIFT_INSTALL_API_TIMEOUT` | 20m | Bootstrap API / **API VIP** / keepalived not up in time (often ~20m in slow environments) |
| `OPENSHIFT_INSTALL_BOOTSTRAP_TIMEOUT` | 45m (60m vSphere/bare metal) | Bootstrap completes but later bootstrap steps exceed default |
| `OPENSHIFT_INSTALL_INSTALL_COMPLETE_TIMEOUT` | 40m/60m init + 30m stability | Post-bootstrap cluster operators / stability |

The same `OPENSHIFT_INSTALL_INSTALL_COMPLETE_TIMEOUT` value is used for **both** cluster initialization and the operator stability window in `wait-for install-complete`.

## VW recommendation (15m provisioning + slow bootstrap VIP)

Typical failure: install stops at **15 minutes** while infrastructure or machines are still coming up, or bootstrap needs **~20 minutes** before keepalived and the API VIP are healthy.

Start with:

| Variable | Suggested value | Rationale |
|----------|-----------------|-----------|
| `OPENSHIFT_INSTALL_MACHINE_PROVISION_TIMEOUT` | `45m` | Removes the default **15m** machine provision ceiling |
| `OPENSHIFT_INSTALL_NETWORK_TIMEOUT` | `45m` | Same ceiling on network/CAPI readiness |
| `OPENSHIFT_INSTALL_API_TIMEOUT` | `30m` | Headroom above ~20m bootstrap API VIP / keepalived bring-up |

Tune down after you have stable timings; do not set values above what you need (longer waits delay failure detection).

## Hive / ACM example

```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
spec:
  provisioning:
    installerImageOverride: pf34-docker.jfrog.devstack.vwgroup.com/openshift/installer@sha256:<digest-from-vw-build>
    installerEnv:
      - name: OPENSHIFT_INSTALL_MACHINE_PROVISION_TIMEOUT
        value: "45m"
      - name: OPENSHIFT_INSTALL_NETWORK_TIMEOUT
        value: "45m"
      - name: OPENSHIFT_INSTALL_API_TIMEOUT
        value: "30m"
```

For a one-off install with a local `openshift-install` binary, export the same variables in the shell before running `create cluster`.

## Verify overrides

1. Confirm the provision pod uses your image digest (`installerImageOverride`).
2. In installer logs, search for `Using OPENSHIFT_INSTALL_`.
3. If you still see failures at exactly 15m, the pod is likely **not** using the patched image or env is not passed through `installerEnv`.

## Out of scope

- Timeouts in Hive, CCM, or cloud APIs (only `openshift-install` phases above).
- Fixing slow bootstrap root causes (registry auth, mirror, vSphere performance, etc.) — overrides only extend waits.
