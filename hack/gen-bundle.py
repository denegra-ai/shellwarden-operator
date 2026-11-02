#!/usr/bin/env python3
"""Write the OLM bundle (manifests, metadata, scorecard config) from the sources in this repository.

The CSV embeds the operator's RBAC and Deployment, the CRDs' list and the samples. Each of those
is written down once, under config/, and copied here, so `make bundle` is the only way the bundle
changes and the copy cannot drift from what `make deploy` installs.

Environment (the Makefile sets all of it):
  VERSION, IMG                operator version and image
  OPENSHELL_VERSION           the upstream release the vendored charts come from
  AGENT_SANDBOX               required | bundled (see docs/DESIGN.md)
  AGENT_SANDBOX_VERSION, AGENT_SANDBOX_IMG   the controller, for the bundled variant
  OPENSHIFT_VERSIONS          com.redhat.openshift.versions, e.g. v4.19
  REPLACES, SKIP_RANGE        the upgrade edge (both optional; the first release has none)
  CREATED_AT                  defaults to now (UTC)
  OUT                         output directory, default bundle
"""

import base64
import datetime
import json
import os
import shutil
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = "shellwarden-operator"
CHANNEL = "alpha"


class Dumper(yaml.SafeDumper):
    pass


def _str(dumper, value):
    style = "|" if "\n" in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


Dumper.add_representer(str, _str)


def dump(data, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.dump(data, Dumper=Dumper, sort_keys=False, width=1000), encoding="utf-8")


def load(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def load_all(path: Path):
    return [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None or value == "":
        sys.exit(f"{name} is not set; run make bundle")
    return value


def image_ref(values, key, global_registry):
    image = values[key]["image"]
    registry = image.get("registry") or global_registry
    repository = f"{registry}/{image['repository']}" if registry else image["repository"]
    if not image.get("digest"):
        sys.exit(f"helm-charts/openshell/values.yaml has no {key}.image.digest; run make vendor")
    return f"{repository}@{image['digest']}"


def hardened(pod_spec):
    """Restricted pod security for a container we did not write: non-root, no privilege
    escalation, no capabilities, RuntimeDefault seccomp. No UID, so OpenShift's SCC assigns one."""
    pod_spec.setdefault("securityContext", {}).update(
        {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}})
    for container in pod_spec["containers"]:
        container.setdefault("securityContext", {}).update(
            {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}})
        # Upstream sets no requests; a namespace with a quota would refuse the pod.
        container.setdefault("resources", {"requests": {"cpu": "50m", "memory": "64Mi"},
                                           "limits": {"memory": "512Mi"}})


def main() -> int:
    version = env("VERSION")
    img = env("IMG")
    variant = env("AGENT_SANDBOX")
    if variant not in ("required", "bundled"):
        sys.exit("AGENT_SANDBOX must be required or bundled")
    out = ROOT / env("OUT", "bundle")
    created_at = os.environ.get("CREATED_AT") or datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")

    csv = load(ROOT / "csv-base.yaml")
    meta, spec = csv["metadata"], csv["spec"]
    annotations = meta["annotations"]
    meta["name"] = f"{PACKAGE}.v{version}"
    spec["version"] = version
    annotations["containerImage"] = img
    annotations["createdAt"] = created_at
    if os.environ.get("REPLACES"):
        spec["replaces"] = os.environ["REPLACES"]
    if os.environ.get("SKIP_RANGE"):
        annotations["olm.skipRange"] = os.environ["SKIP_RANGE"]

    # The operator: its Deployment, its ClusterRole and its leader-election Role.
    rbac = load_all(ROOT / "config/rbac/role.yaml")
    cluster_role = next(d for d in rbac if d["kind"] == "ClusterRole")
    role = next(d for d in rbac if d["kind"] == "Role")
    manager = load(ROOT / "config/manager/deployment.yaml")
    pod = manager["spec"]["template"]["spec"]
    pod["containers"][0]["image"] = img
    sa = pod["serviceAccountName"]
    install = spec["install"]["spec"]
    install["clusterPermissions"] = [{"serviceAccountName": sa, "rules": cluster_role["rules"]}]
    install["permissions"] = [{"serviceAccountName": sa, "rules": role["rules"]}]
    install["deployments"] = [{"name": manager["metadata"]["name"],
                               "label": manager["metadata"]["labels"],
                               "spec": manager["spec"]}]

    # The images the operand pulls, all by digest, for mirroring (oc-mirror reads relatedImages).
    values = load(ROOT / "helm-charts/openshell/values.yaml")
    registry = values["global"]["image"]["registry"]
    sandbox = values["sandbox"]["image"]
    related = [
        {"name": "operator", "image": img},
        {"name": "openshell-gateway", "image": image_ref(values, "gateway", registry)},
        {"name": "openshell-supervisor", "image": image_ref(values, "supervisor", registry)},
        {"name": "openshell-sandbox-runtime", "image": image_ref(values, "sandboxRuntime", registry)},
        {"name": "sandbox-base", "image": f"{sandbox['repository']}@{sandbox['digest']}"},
    ]

    manifests = out / "manifests"
    if out.exists():
        shutil.rmtree(out)
    manifests.mkdir(parents=True)
    for crd in sorted((ROOT / "config/crd").glob("*.yaml")):
        shutil.copy(crd, manifests / crd.name)

    owned = spec["customresourcedefinitions"]["owned"]
    as_version = env("AGENT_SANDBOX_VERSION")
    if variant == "bundled":
        as_dir = ROOT / "config/agent-sandbox"
        shutil.copy(as_dir / "agents.x-k8s.io_sandboxes.yaml", manifests / "agents.x-k8s.io_sandboxes.yaml")
        controller = load(as_dir / "deployment.yaml")
        controller_pod = controller["spec"]["template"]["spec"]
        controller_img = env("AGENT_SANDBOX_IMG")
        controller_pod["containers"][0]["image"] = controller_img
        hardened(controller_pod)
        install["clusterPermissions"].append({
            "serviceAccountName": controller_pod["serviceAccountName"],
            "rules": load(as_dir / "clusterrole.yaml")["rules"]})
        install["deployments"].append({"name": controller["metadata"]["name"],
                                       "label": controller["metadata"]["labels"],
                                       "spec": controller["spec"]})
        related.append({"name": "agent-sandbox-controller", "image": controller_img})
        crd = load(as_dir / "agents.x-k8s.io_sandboxes.yaml")
        storage = next(v["name"] for v in crd["spec"]["versions"] if v.get("storage"))
        owned.append({
            "name": crd["metadata"]["name"], "kind": crd["spec"]["names"]["kind"], "version": storage,
            "displayName": "Sandbox (Agent Sandbox)",
            "description": "kubernetes-sigs Agent Sandbox, bundled for OpenShell. OpenShell creates these; do not create them by hand.",
            "resources": [{"kind": "Pod", "version": "v1"}, {"kind": "Service", "version": "v1"},
                          {"kind": "PersistentVolumeClaim", "version": "v1"}]})
        annotations["operators.operatorframework.io/internal-objects"] = json.dumps([crd["metadata"]["name"]])
        note = (f"This bundle includes the Agent Sandbox CRD and controller ({as_version}, kubernetes-sigs, "
                "Apache-2.0) that OpenShell needs. If Agent Sandbox is already installed with kubectl, "
                "remove its controller Deployment (namespace agent-sandbox-system) first.")
    else:
        dump({"dependencies": [{"type": "olm.gvk", "value": {
            "group": "agents.x-k8s.io", "kind": "Sandbox", "version": "v1beta1"}}]},
             out / "metadata/dependencies.yaml")
        # agent-sandbox-operator 0.5.6 writes its webhook Secret into agent-sandbox-system whatever
        # namespace OLM installs it in, and crash-loops when that namespace is missing (seen on kind,
        # 2026-11-02). Remove this once a fixed version is in the catalog.
        note = ("OpenShell needs the Agent Sandbox API (kubernetes-sigs). OLM installs the Agent Sandbox "
                "Operator from the same catalog as a dependency. **Before installing, create the namespace "
                "`agent-sandbox-system`**: Agent Sandbox Operator 0.5.6 stores its webhook certificate there "
                "and does not start without it.")

    for entry in owned:
        if entry["name"].endswith(".openshell.denegra.ai"):
            for res in entry["specDescriptors"] + entry["statusDescriptors"]:
                res.setdefault("description", res["displayName"])
    spec["relatedImages"] = related

    samples = [load(p) for p in sorted((ROOT / "config/samples").glob("*.yaml"))]
    annotations["alm-examples"] = json.dumps(samples, indent=2)

    spec["description"] = (spec["description"]
                           .replace("OPENSHELL_VERSION", env("OPENSHELL_VERSION"))
                           .replace("AGENT_SANDBOX_VERSION", as_version)
                           .replace("AGENT_SANDBOX_NOTE", note))
    spec["icon"][0]["base64data"] = base64.b64encode((ROOT / "icon.svg").read_bytes()).decode()

    text = yaml.dump(csv, Dumper=Dumper, sort_keys=False, width=1000)
    for placeholder in ("VERSION", "IMG", "CREATED_AT", "ICON_BASE64", "AGENT_SANDBOX_NOTE"):
        if f": {placeholder}\n" in text or f" {placeholder}\n" in text:
            sys.exit(f"placeholder {placeholder} left in the CSV")
    (manifests / f"{PACKAGE}.clusterserviceversion.yaml").write_text(text, encoding="utf-8")

    dump({"annotations": {
        "operators.operatorframework.io.bundle.mediatype.v1": "registry+v1",
        "operators.operatorframework.io.bundle.manifests.v1": "manifests/",
        "operators.operatorframework.io.bundle.metadata.v1": "metadata/",
        "operators.operatorframework.io.bundle.package.v1": PACKAGE,
        "operators.operatorframework.io.bundle.channels.v1": CHANNEL,
        "operators.operatorframework.io.bundle.channel.default.v1": CHANNEL,
        "operators.operatorframework.io.test.mediatype.v1": "scorecard+v1",
        "operators.operatorframework.io.test.config.v1": "tests/scorecard/",
        "com.redhat.openshift.versions": env("OPENSHIFT_VERSIONS"),
    }}, out / "metadata/annotations.yaml")

    (out / "tests/scorecard").mkdir(parents=True)
    shutil.copy(ROOT / "config/scorecard/config.yaml", out / "tests/scorecard/config.yaml")
    print(f"wrote {out.relative_to(ROOT)}/ ({variant} Agent Sandbox, {PACKAGE}.v{version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
