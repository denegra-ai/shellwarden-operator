#!/bin/sh
# Take the Agent Sandbox CRD, the controller's ClusterRole and its Deployment from the
# kubernetes-sigs release manifest at AGENT_SANDBOX_VERSION, unchanged, into config/agent-sandbox.
# The bundled bundle variant (make bundle AGENT_SANDBOX=bundled) is built from these.
set -eu
: "${AGENT_SANDBOX_VERSION:?}"
out=config/agent-sandbox
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/sandbox.yaml" \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$AGENT_SANDBOX_VERSION/sandbox.yaml"
mkdir -p "$out"
yq 'select(.kind == "CustomResourceDefinition")' "$tmp/sandbox.yaml" > "$out/agents.x-k8s.io_sandboxes.yaml"
yq 'select(.kind == "ClusterRole")' "$tmp/sandbox.yaml" > "$out/clusterrole.yaml"
yq 'select(.kind == "Deployment")' "$tmp/sandbox.yaml" > "$out/deployment.yaml"
for f in "$out"/*.yaml; do
  [ -s "$f" ] || { echo "nothing extracted into $f" >&2; exit 1; }
done
echo "vendored Agent Sandbox $AGENT_SANDBOX_VERSION into $out/"
