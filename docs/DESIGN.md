# Design: a community operator for NVIDIA OpenShell

Status: v0.1.0 design, 2026-11-02. Product name **Denegra Shellwarden** (package
`shellwarden-operator`). The API group does not depend on the name.

## What it is

An open-source (Apache-2.0), Helm-based OLM operator that installs
[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell), the Apache-2.0 runtime that runs AI
agents in kernel-confined sandboxes, on OpenShift and on any Kubernetes with OLM. It targets the
two community catalogs: OperatorHub.io (`k8s-operatorhub/community-operators`) and OpenShift's
community catalog (`redhat-openshift-ecosystem/community-operators-prod`).

OpenShell ships only a Helm chart, labelled "Experimental" for Kubernetes, and no operator. This
one makes it a one-click install from OperatorHub with upgrades managed by OLM.

It is a community project by Denegra. It is not made, endorsed or supported by NVIDIA.

## Shape

```
OLM bundle (one CSV)
├── Deployment shellwarden-operator          helm-operator (operator-sdk), UBI 9
│     reconciles  OpenShell            → upstream chart  openshell 0.1.6   (cluster: one per cluster)
│                 OpenShellWorkspace   → upstream chart  openshell-workspace (one per namespace)
├── Deployment agent-sandbox-controller  kubernetes-sigs/agent-sandbox v1.0.9, unchanged image
└── CRDs  openshells.openshell.denegra.ai
          openshellworkspaces.openshell.denegra.ai
          sandboxes.agents.x-k8s.io          (from agent-sandbox v1.0.9, unchanged)
```

- **Helm-based, not Go.** The upstream chart is the tested description of an OpenShell install.
  A Go controller would be a second description that drifts. The CR's `spec` is the chart's
  values, so NVIDIA's documented values work as written. Reconciling is `helm upgrade --install`
  on every change, and edits to owned objects are put back.
- **Upstream charts are vendored unchanged** under `helm-charts/`, pinned to the release tag,
  except for the default values listed in `helm-charts/PATCHES.md` (telemetry off, images by
  digest, workspace chart version). `make vendor` redoes this from the tag, so an upstream bump
  is a reviewed diff.

## CRDs

### `OpenShell` (namespaced; one per cluster)

The gateway install. `spec` = the `openshell` chart's values. The CRD types the fields most
installs need, gives them console form descriptors, and keeps every other upstream value open
(`x-kubernetes-preserve-unknown-fields` on `spec`) for advanced setups.

| Area | Fields | Default here |
|---|---|---|
| Gateway | `replicaCount`, `resources`, `nodeSelector`, `tolerations`, `server.logLevel`, `server.dataStorageClass`, `server.dataStorageSize` | upstream |
| **Telemetry** | `server.telemetryEnabled` | **`false`** (upstream: `true`). The CRD default writes `false` into every new CR, so it is visible, and the vendored chart default is `false` too |
| **Workspace mode** | `server.drivers.kubernetes.workspaceMode` (`shared` / `managed` / `operator`), `server.drivers.kubernetes.operatorNamespaceLabel` | `shared` (upstream). Multi-tenant platforms use `operator` |
| **Images / mirrors** | `global.image.registry`, `global.image.pullPolicy`, `{gateway,supervisor,sandboxRuntime}.image.{registry,repository,tag,digest}`, `sandbox.image.*`, `imagePullSecrets`, `server.sandboxImagePullSecrets` | Every image pinned by digest. A mirror needs only `global.image.registry: mirror.example.com/nvidia`: the digest stays, so the mirrored image is provably the same. On OpenShift an `ImageDigestMirrorSet` does it with no CR change |
| **NetworkPolicy** | `networkPolicy.enabled` | `true`: sandbox SSH ingress only from the gateway. The per-sandbox egress fence is created by the gateway's driver and cannot be turned off. **The CNI must enforce NetworkPolicy** (OVN-Kubernetes, Calico, Cilium; kindnet does) |
| Auth | `server.oidc.*`, `server.tls.*` | upstream (mTLS) |
| Exposure | `openshiftRoute.{enabled,host}`, `grpcRoute.*` | off |
| Observability | `server.otlp.endpoint`, `server.ocsfLog.enabled` | off |
| Storage | `server.workspaceStorageClass`, `server.workspaceDefaultStorageSize` | cluster default |

Status: helm-operator's `conditions` (`Initialized`, `Deployed`, `ReleaseFailed`,
`Irreconcilable`) and `deployedRelease`. A missing prerequisite surfaces as `ReleaseFailed` with
the chart's own message (see the preflight below).

The CR should be named `openshell` in namespace `openshell`: the workspace chart's defaults point
at that gateway. Other names work if each `OpenShellWorkspace` names the gateway.

### `OpenShellWorkspace` (namespaced; one per sandbox namespace)

For `operator` workspace mode. It installs the upstream `openshell-workspace` chart into its own
namespace: the sandbox ServiceAccount, the Role and RoleBinding for the gateway's ServiceAccount,
and the SSH-ingress NetworkPolicy. All namespaced, so a platform can let a tenant's automation
create it without cluster rights.

`spec` = that chart's values: `gateway.serviceAccount.{name,namespace}`,
`gateway.networkPolicy.podSelector`, `gateway.allowDriverConfig`, `sandboxServiceAccount.*`,
`networkPolicy.enabled`.

The namespace still needs the label the gateway watches (`operatorNamespaceLabel`). Labelling a
namespace is the platform's decision, so the operator does not do it.

## Agent Sandbox: a dependency where OLM can resolve one, bundled where it cannot

OpenShell's Kubernetes driver needs the Agent Sandbox CRD and controller
(`sandboxes.agents.x-k8s.io`, kubernetes-sigs, Apache-2.0). The OpenShell chart does not install
them.

kubernetes-sigs publishes its own **agent-sandbox-operator** on OperatorHub.io
(`k8s-operatorhub/community-operators`, 0.5.6, from `kubernetes-sigs/agent-sandbox/olm`). Its CRD
serves `v1beta1` (storage) and `v1alpha1`; OpenShell 0.1.6 accepts either. It is **not** in
OpenShift's community catalog. One source builds two bundle variants (`make bundle
AGENT_SANDBOX=required|bundled`):

| Catalog | Variant | What the bundle carries |
|---|---|---|
| OperatorHub.io | `required` | `metadata/dependencies.yaml`: `olm.gvk agents.x-k8s.io/v1beta1 Sandbox`. OLM installs agent-sandbox-operator alongside. No CRD conflict with the operator that owns it |
| community-operators-prod (OpenShift) | `bundled` | The `sandboxes.agents.x-k8s.io` CRD and the controller from the v1.0.9 release manifest, unchanged, as the CSV's second Deployment with upstream's ClusterRole; image from `registry.k8s.io` by digest. The CRD is an internal object, so the console does not offer it for hand creation |

Why not bundle everywhere: two CSVs owning one CRD conflict in OLM, so on OperatorHub.io a user
could not install both. Why not depend everywhere: on OpenShift there is nothing to resolve to.

Risks and the exit:

- `bundled`: a cluster that already has Agent Sandbox from `kubectl apply` gets a second
  controller. The docs say to remove the standalone controller first; OLM takes over the CRD.
- `required`: agent-sandbox-operator 0.5.6 writes its webhook Secret into `agent-sandbox-system`
  whatever namespace OLM installs it in, and crash-loops when that namespace is missing (found in
  the local OLM test, 2026-11-02). The 0.1.0 CSV text tells users to create it first.
  agent-sandbox-operator 1.0.9 (OperatorHub.io, 2026-11-02) no longer runs that webhook (its
  controller's `--webhook-namespace` and certificate code are gone), so the namespace is not needed
  there; it serves only `v1beta1`, which is what this bundle requires and the controller the
  `bundled` variant ships. The next release drops the note once an install against 1.0.9 passes.
- When agent-sandbox-operator reaches community-operators-prod (best done by its maintainers;
  Denegra can ask), a minor release switches the OpenShift bundle to `required`.
- The chart's own preflight stays on in both: if the Sandbox API is not served, the `OpenShell`
  CR shows `ReleaseFailed` with "Agent Sandbox is required…" rather than a half-installed gateway.

## OpenShift

- **Version: 4.19 or later.** Bundle annotation `com.redhat.openshift.versions: "v4.19"`. The
  RHCOS kernels of 4.16–4.18 are built without Landlock; OpenShell needs Landlock ABI 3+ and
  seccomp user notification, plus a CNI that enforces NetworkPolicy (OVN-Kubernetes does).
- **SCC: restricted-v2, nothing privileged.** No SCC is created or bound. The gateway, the
  supervisors and the sandboxes run without added capabilities. What OpenShift needs is that pods
  do not pin UIDs: the chart's defaults pin `runAsUser: 1000` and `fsGroup: 1000`, which
  restricted-v2 refuses. The operator detects OpenShift at start (the `security.openshift.io` API
  is served) and then uses `watches-openshift.yaml`, which installs a vendored copy of the chart
  whose defaults drop those pinned IDs exactly where NVIDIA's `values-openshift-scc.yaml` overlay
  nulls them (helm-operator's `overrideValues` cannot delete a value; tried, the API server got
  the string `"null"`). The SCC then assigns the namespace's range;
  sandbox pods read that range from the namespace annotation themselves. `SHELLWARDEN_PLATFORM` set on
  the Deployment overrides the detection. The gateway relies on the SCC here: it reads its 0400
  signing key through the `fsGroup` restricted-v2 injects. kind has no SCC, so there the OpenShift
  mode is checked only up to a clean upgrade and the rendered StatefulSet.
- **Tested on OpenShift 4.20.5** (CRC, RHCOS 9.6, kernel 5.14.0-570, LSMs include `landlock`;
  2026-11-02), both bundle variants installed through OLM into `openshift-operators`:
  - Every pod was admitted by `restricted-v2` with a UID from the namespace range: the operator,
    the agent-sandbox controller, the gateway, the supervisor and the sandbox pod.
  - A sandbox started through the openshell CLI ran as that UID, and its write to `/etc` was
    denied (Landlock).
  - Spec changes, drift repair, `OpenShellWorkspace` and a stable Helm revision behaved as on kind.
  - `required`: OLM resolved agent-sandbox-operator 0.5.6 from the OperatorHub.io catalog
    (`quay.io/operatorhubio/catalog`), with `agent-sandbox-system` created first.
- Exposure: `openshiftRoute.enabled` gives a passthrough Route (the gateway terminates its own
  TLS).
- The operator's own pods: UBI 9 minimal, non-root, no UID pinned, `RuntimeDefault` seccomp,
  all capabilities dropped. The bundled agent-sandbox controller runs the same way.

On plain Kubernetes the node kernel must be 6.2-class (Landlock ABI 3). `minKubeVersion` is
`1.29.0`, OpenShell's documented floor.

## Install modes and RBAC

- `AllNamespaces` only. OpenShell is a cluster service: its gateway needs cluster-scoped rights
  (namespaces, nodes, TokenReviews, sandboxes in all namespaces in `managed`/`operator` mode).
- The operator's ClusterRole lists every kind the two charts create and, because Kubernetes only
  lets a subject grant permissions it holds, every permission the gateway's ClusterRole and Roles
  grant. No `*` verbs or resources. `escalate` and `bind` are not used.
- `config/rbac/role.yaml` is the single source; `make bundle` copies it into the CSV.

## Upgrade graph for a pre-1.0 upstream

OpenShell 0.1.x releases weekly, supports only the latest minor and the one before it, and may
change Experimental interfaces within a patch.

- **Channel `alpha`** until OpenShell reaches 1.0 and this operator has run in production. Then a
  `stable` channel starts; `alpha` keeps receiving the same bundles for a while.
- **Operator versions are independent semver** (`0.1.0`, `0.1.1`, …). Each CSV carries the
  OpenShell version it installs (`spec.labels`, description table). The README keeps the mapping.
- **`ci.yaml`: `updateGraph: replaces-mode`.** Each bundle `replaces` the previous one and sets
  `olm.skipRange: ">=0.1.0 <X.Y.Z"`, so a cluster several releases behind upgrades in one step.
- **Cadence:** not every upstream patch. A release follows a new upstream minor (to stay inside
  N-1 support), a security fix, or an operator fix. Bundles are never edited after publishing; a
  bad one is followed by a fixed one that `replaces` it (and `skips` it if it must not be
  installed).
- **Before each release:** install the previous bundle from a local catalog, create the CRs,
  start a sandbox, upgrade to the new bundle, and check the sandbox state survives (the gateway's
  SQLite database lives on its PVC). `make e2e` runs the install half today.
- **Breaking upstream changes** (OpenShell already removed an inference route within 0.1.x) are
  called out in the CSV description's "Upgrade notes".

## Naming and trademarks

- Never "NVIDIA" in the product, operator, package or repository name. The display name and the
  description say "for NVIDIA OpenShell" or "works with NVIDIA OpenShell".
- Never "partner", "certified", "validated by", "official" or "supported by NVIDIA".
- The description states it is a community project not affiliated with or endorsed by NVIDIA,
  and attributes the marks.
- No NVIDIA logo; the icon is our own.
- The CRD kind `OpenShell` uses the name to describe what it installs, like `Prometheus` in
  prometheus-operator.

Names, decided 2026-11-02:

| Where | Name |
|---|---|
| Display name (CSV `displayName`, README title, image label) | **Denegra Shellwarden for NVIDIA OpenShell**; "Denegra Shellwarden" where OpenShell is clear from context |
| Package, repository, image | `shellwarden-operator`, `denegra-ai/shellwarden-operator`, `ghcr.io/denegra-ai/shellwarden-operator` |

"Denegra" belongs to our name, never to NVIDIA's: "Denegra OpenShell Operator" was rejected
because it would join NVIDIA's product name to ours. Small unrelated GitHub projects also use
"shellwarden" (one is shell tooling for AI agents).

## Not in v0.1.0

- Postgres-backed HA gateway (works through `spec` values, not tested here).
- cert-manager, Gateway API routes, Vault credential driver (values pass through, untested).
- An OpenShift run on a multi-node cluster or on 4.19 itself (only CRC 4.20.5, single node, so far).
- An upgrade between two operator versions (there is only 0.1.0).
- Arm64 operator image (the upstream images are multi-arch; ours is amd64 for now).
