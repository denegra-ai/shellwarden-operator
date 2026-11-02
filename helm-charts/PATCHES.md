# Vendored charts

Both charts are NVIDIA's, Apache-2.0 (`third_party/OpenShell-LICENSE`), copied by
`make vendor` (`hack/vendor-charts.sh`) from OpenShell **v0.1.6**:

| Directory | Source |
|---|---|
| `openshell/` | `oci://ghcr.io/nvidia/openshell/helm-chart:0.1.6`, digest `sha256:036f3fe3b0ef9603c2b43ab8e32ddfaeb101f1e5041109017681bf5d61e7a7b5` |
| `openshell-workspace/` | `deploy/helm/openshell-workspace` at tag `v0.1.6` of github.com/NVIDIA/OpenShell (templates, `Chart.yaml`, `values.yaml`; README and tests left out) |

No template is changed. Only these default values are, by `hack/vendor-charts.sh`:

1. `openshell/values.yaml` `server.telemetryEnabled`: `true` → `false`. OpenShell's anonymous
   telemetry to NVIDIA is off unless the `OpenShell` resource turns it on.
2. `openshell/values.yaml` `gateway.image.digest`, `supervisor.image.digest`,
   `sandboxRuntime.image.digest`, `sandbox.image.digest`: empty → the digests of the v0.1.6
   images (and of `nvcr.io/nvidia/base/ubuntu:24.04` for the default sandbox image). The chart
   prefers a digest to a tag, so the images are exactly the ones tested, and a mirror needs only
   `global.image.registry`.
3. `openshell-workspace/Chart.yaml` `version` and `appVersion`: `0.0.0` → `0.1.6`, so the Helm
   release names the version it came from.

4. `openshell-openshift/` is a generated copy of `openshell/` for OpenShift
   (`watches-openshift.yaml`). Its `values.yaml` drops the pinned pod IDs exactly where NVIDIA's
   `ci/values-openshift-scc.yaml` overlay nulls them — `podSecurityContext.fsGroup`,
   `securityContext.runAsUser`, `supervisor.podSecurityContext.{runAsUser,runAsGroup,fsGroup}` —
   so the restricted-v2 SCC assigns the namespace's range. A copy rather than a value override,
   because helm-operator's `overrideValues` cannot delete a value (`"null"` arrives as a string).
   Templates are identical to `openshell/`.
