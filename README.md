# Denegra Shellwarden for NVIDIA OpenShell

> Community project by Denegra; not made, endorsed or supported by NVIDIA.

Denegra Shellwarden installs [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) — the Apache-2.0 runtime
that runs AI agents in kernel-confined sandboxes — on OpenShift and on any Kubernetes with OLM,
and keeps it upgraded. OpenShell ships a Helm chart and no operator; this is a Helm-based OLM
operator that installs that chart, pinned and tested, from one `OpenShell` resource.

| This operator | NVIDIA OpenShell | Agent Sandbox (kubernetes-sigs) |
|---|---|---|
| 0.1.0 | 0.1.6 | v1.0.9 (bundled) / Agent Sandbox Operator (OperatorHub.io) |

Design and decisions: [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- Nodes with a Landlock ABI 3+ kernel (6.2-class) and seccomp user notification.
- **OpenShift 4.19 or later** (4.16–4.18 kernels lack Landlock), or Kubernetes 1.29+ with OLM.
- A network plugin that enforces NetworkPolicy (OVN-Kubernetes, Calico, Cilium).
- A default block-storage StorageClass, or `spec.server.dataStorageClass`.

## Use

After installing from OperatorHub:

```yaml
apiVersion: openshell.denegra.ai/v1alpha1
kind: OpenShell
metadata:
  name: openshell
  namespace: openshell
spec:
  server:
    telemetryEnabled: false        # the default here; upstream's default is true
    drivers:
      kubernetes:
        workspaceMode: shared      # or operator, with OpenShellWorkspace per namespace
```

`spec` is the upstream chart's values, so OpenShell's Kubernetes documentation applies. The
client certificate for the `openshell` CLI is in the Secret `openshell-client-tls`:

```sh
mkdir -p ~/.config/openshell/gateways/k8s/mtls
for k in ca.crt tls.crt tls.key; do
  kubectl -n openshell get secret openshell-client-tls -o jsonpath="{.data.${k//./\\.}}" | base64 -d \
    > ~/.config/openshell/gateways/k8s/mtls/$k
done
openshell gateway add https://openshell.openshell.svc.cluster.local:8080 --local --name k8s
openshell sandbox create -- sh -c 'echo hello from a sandbox'
```

### Differences from the upstream chart's defaults

- Telemetry to NVIDIA is **off** unless `spec.server.telemetryEnabled: true`.
- Images are pinned **by digest**; for a mirror set `spec.global.image.registry`.
- On OpenShift the pinned pod UIDs are removed so `restricted-v2` assigns them
  (`watches-openshift.yaml`, detected at start; `SHELLWARDEN_PLATFORM` overrides).

Everything changed is listed in [helm-charts/PATCHES.md](helm-charts/PATCHES.md).

## Running OpenShell for many teams or customers

Shellwarden installs OpenShell and keeps it running. It does not decide who may use it, what that
costs, or what data an agent may send to a model. Denegra builds two commercial products for that
layer. They are optional; Shellwarden works the same without them.

- **Denegra TenantTab** runs on the same OpenShift cluster and sells "agent sandboxes" to
  tenants. Each tenant gets its own `OpenShellWorkspace`, its users mapped from your identity
  provider, quotas, and usage on its invoice. An agent's model calls go through TenantTab's
  model gateway with the tenant's key, so the agent never sees the key and every token is
  metered. TenantTab is Red Hat certified and listed in the Red Hat Ecosystem Catalog.
- **Denegra Derbent** sits between agents and models and masks personal data before a prompt
  leaves your network (KVKK and GDPR). Point an OpenShell provider profile at Derbent instead of
  the model.

14-day trial and contact: https://denegra.ai/trial

## Develop

Everything runs in Docker; `hack/make.sh <target>` runs a target in the tools image when the host
has no make, Python, opm or operator-sdk.

| Target | |
|---|---|
| `vendor` | Re-vendor the charts and Agent Sandbox at the pinned versions |
| `bundle` | Write `bundle/` (`AGENT_SANDBOX=bundled` or `required`) |
| `validate` | operator-sdk bundle validation as both catalogs run it, yamllint, helm lint |
| `e2e` | kind + OLM: install from a local catalog, create the resource, start a sandbox, check spec changes and drift |
| `scorecard` | The bundle's scorecard tests on the lab cluster |
| `community-dirs` | The pull-request trees for both community catalogs under `dist/` |
| `lab-down` | Delete the kind cluster and the lab registry |

Releasing and the community catalog submissions: [docs/RELEASING.md](docs/RELEASING.md).

## Licence

Apache-2.0. The vendored OpenShell charts are NVIDIA's (Apache-2.0); the Agent Sandbox manifests
are the Kubernetes Authors' (Apache-2.0). See [NOTICE](NOTICE).

NVIDIA is a trademark of NVIDIA Corporation. Other names may be trademarks of their owners.
