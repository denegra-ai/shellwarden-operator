#!/bin/sh
# End-to-end test on the lab kind cluster (make e2e): install the operator from a local catalog
# through OLM, create an OpenShell, start a sandbox with the openshell CLI, and check that writing
# into the resource changes what is deployed. Evidence goes to $EVIDENCE (default dist/e2e).
set -eu
: "${CATALOG_IMG:?}" "${VERSION:?}" "${LAB_REGISTRY:?}" "${LAB_PUSH:?}"
OPENSHELL_VERSION=${OPENSHELL_VERSION:-0.1.8}
EVIDENCE=${EVIDENCE:-dist/e2e}
NS=openshell
mkdir -p "$EVIDENCE"
step() { printf '\n== %s\n' "$*"; }
# wait_for <seconds> <description> <command…>: retry until the command succeeds.
wait_for() {
  t=$1 what=$2; shift 2
  i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 5)); [ $i -ge "$t" ] && { echo "timed out after ${t}s waiting for $what" >&2; return 1; }
    sleep 5
  done
  echo "ok: $what"
}

step "catalog $CATALOG_IMG"
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: shellwarden-lab
  namespace: olm
spec:
  sourceType: grpc
  image: $CATALOG_IMG
  displayName: Shellwarden lab
  publisher: lab
  grpcPodConfig:
    securityContextConfig: restricted
EOF
wait_for 300 "catalog ready" sh -c \
  '[ "$(kubectl -n olm get catalogsource shellwarden-lab -o jsonpath={.status.connectionState.lastObservedState})" = READY ]'

step "subscribe (AllNamespaces, namespace operators)"
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: shellwarden-operator
  namespace: operators
spec:
  channel: alpha
  name: shellwarden-operator
  source: shellwarden-lab
  sourceNamespace: olm
  installPlanApproval: Automatic
EOF
wait_for 600 "CSV shellwarden-operator.v$VERSION Succeeded" sh -c \
  "[ \"\$(kubectl -n operators get csv shellwarden-operator.v$VERSION -o jsonpath={.status.phase})\" = Succeeded ]"
kubectl -n operators get csv,deploy,pods -o wide | tee "$EVIDENCE/olm-install.txt"
kubectl -n operators logs deploy/shellwarden-operator | head -5 | tee "$EVIDENCE/operator-start.txt"
kubectl get crd sandboxes.agents.x-k8s.io openshells.openshell.denegra.ai openshellworkspaces.openshell.denegra.ai \
  | tee -a "$EVIDENCE/olm-install.txt"

step "OpenShell resource"
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n $NS -f config/samples/openshell_v1alpha1_openshell.yaml
wait_for 600 "OpenShell Deployed" kubectl -n $NS wait openshell/openshell --for=condition=Deployed --timeout=5s
kubectl -n $NS rollout status statefulset/openshell --timeout=600s
kubectl -n $NS get openshell openshell -o yaml > "$EVIDENCE/openshell-cr.yaml"
kubectl -n $NS get all,secrets,networkpolicies,roles,rolebindings -o wide > "$EVIDENCE/openshell-objects.txt"

step "telemetry is off by default"
kubectl -n $NS get openshell openshell -o jsonpath='{.spec.server.telemetryEnabled}' | grep -qx false
kubectl -n $NS get statefulset openshell \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_TELEMETRY_ENABLED")].value}' | grep -qx false
echo "ok: spec.server.telemetryEnabled=false (CRD default) and OPENSHELL_TELEMETRY_ENABLED=false"

step "images are the pinned digests"
kubectl -n $NS get statefulset openshell -o jsonpath='{.spec.template.spec.containers[0].image}' | tee "$EVIDENCE/gateway-image.txt"
echo
grep -q '@sha256:' "$EVIDENCE/gateway-image.txt"

step "writing into the resource has an effect"
before=$(kubectl -n $NS get configmap -o name | xargs -I{} kubectl -n $NS get {} -o yaml | grep -c 'log_level = "debug"' || true)
kubectl -n $NS patch openshell openshell --type merge -p '{"spec":{"server":{"logLevel":"debug"}}}'
wait_for 300 "gateway config shows log_level debug" sh -c \
  "kubectl -n $NS get configmap -o yaml | grep -q 'log_level = \"debug\"'"
[ "$before" = 0 ] || { echo "log_level was debug before the patch" >&2; exit 1; }
kubectl -n $NS patch openshell openshell --type merge -p '{"spec":{"server":{"logLevel":"info"}}}'
wait_for 300 "gateway config back to log_level info" sh -c \
  "! kubectl -n $NS get configmap -o yaml | grep -q 'log_level = \"debug\"'"
echo "ok: spec change reached the release and was reverted" | tee "$EVIDENCE/writing-into-cr.txt"

step "drift is put back"
kubectl -n $NS delete networkpolicy -l app.kubernetes.io/instance=openshell --wait=true
wait_for 300 "operator recreated the NetworkPolicy" sh -c \
  "[ \$(kubectl -n $NS get networkpolicy -l app.kubernetes.io/instance=openshell -o name | wc -l) -gt 0 ]"

step "a sandbox, through the openshell CLI"
cli=$LAB_PUSH/shellwarden-lab-cli:$OPENSHELL_VERSION
if ! docker image inspect "$cli" >/dev/null 2>&1; then
  d=$(mktemp -d)
  base=https://github.com/NVIDIA/OpenShell/releases/download/v$OPENSHELL_VERSION
  curl -fsSL -o "$d/openshell.tgz" "$base/openshell-x86_64-unknown-linux-musl.tar.gz"
  curl -fsSL -o "$d/sums" "$base/openshell-checksums-sha256.txt"
  (cd "$d" && grep ' openshell-x86_64-unknown-linux-musl.tar.gz$' sums | sed 's| openshell-x86_64-unknown-linux-musl.tar.gz$| openshell.tgz|' | sha256sum -c -)
  tar -xzf "$d/openshell.tgz" -C "$d"
  printf 'FROM alpine:3.20\nRUN apk add --no-cache openssh-client\nCOPY openshell /usr/local/bin/openshell\n' > "$d/Dockerfile"
  docker build -q -t "$cli" "$d"
  rm -rf "$d"
fi
docker push -q "$cli"
kubectl -n $NS delete pod openshell-cli --ignore-not-found --wait=true
kubectl -n $NS apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: openshell-cli
spec:
  restartPolicy: Never
  containers:
    - name: cli
      image: $LAB_REGISTRY/shellwarden-lab-cli:$OPENSHELL_VERSION
      command: [sleep, "3600"]
      env:
        - {name: HOME, value: /home/cli}
        - {name: OPENSHELL_COLOR, value: never}
      volumeMounts:
        - {name: home, mountPath: /home/cli}
        - {name: mtls, mountPath: /home/cli/.config/openshell/gateways/lab/mtls, readOnly: true}
  volumes:
    - {name: home, emptyDir: {}}
    - name: mtls
      secret:
        secretName: openshell-client-tls
EOF
kubectl -n $NS wait pod/openshell-cli --for=condition=Ready --timeout=180s
cli() { kubectl -n $NS exec openshell-cli -- "$@"; }
cli openshell gateway add https://openshell.$NS.svc.cluster.local:8080 --local --name lab
cli openshell status | tee "$EVIDENCE/gateway-status.txt"
cli openshell sandbox create --name e2e -- sh -c \
  'echo inside-sandbox; id; uname -r; if touch /etc/shellwarden-e2e 2>/dev/null; then echo etc-writable; else echo etc-write-denied; fi' \
  2>&1 | tee "$EVIDENCE/sandbox-create.txt"
grep -q inside-sandbox "$EVIDENCE/sandbox-create.txt"
grep -q etc-write-denied "$EVIDENCE/sandbox-create.txt"
cli openshell sandbox list | tee "$EVIDENCE/sandbox-list.txt"
kubectl get sandboxes.agents.x-k8s.io -A -o wide | tee "$EVIDENCE/sandbox-crs.txt"
kubectl -n $NS get pods -o wide | tee -a "$EVIDENCE/sandbox-crs.txt"
cli openshell sandbox delete e2e || true

step "OpenShellWorkspace in a second namespace"
kubectl create namespace shellwarden-e2e-ws --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n shellwarden-e2e-ws -f config/samples/openshell_v1alpha1_openshellworkspace.yaml
wait_for 300 "OpenShellWorkspace Deployed" kubectl -n shellwarden-e2e-ws wait openshellworkspace/workspace --for=condition=Deployed --timeout=5s
kubectl -n shellwarden-e2e-ws get serviceaccounts,roles,rolebindings,networkpolicies | tee "$EVIDENCE/workspace-objects.txt"

step "the release settles (no upgrade on every reconcile)"
rev() { kubectl -n $NS get secret -l owner=helm,name=openshell -o jsonpath='{range .items[*]}{.metadata.labels.version}{"\n"}{end}' | sort -n | tail -1; }
r1=$(rev); sleep 60; r2=$(rev)
echo "helm revision $r1 -> $r2 over 60s" | tee "$EVIDENCE/revision-stable.txt"
[ "$r1" = "$r2" ]

# kind has no SCC. On OpenShift, restricted-v2 injects runAsUser and fsGroup from the namespace's
# range; here nothing does, so the gateway cannot read its 0400 key and does not start. What kind
# can show: the OpenShift chart copy upgrades cleanly and pins no IDs. Then back to Kubernetes
# mode, and the gateway must recover. The pod under restricted-v2 needs an OpenShift run.
step "OpenShift mode (SHELLWARDEN_PLATFORM=openshift): no pinned pod IDs, clean upgrade"
kubectl -n operators patch subscription shellwarden-operator --type merge \
  -p '{"spec":{"config":{"env":[{"name":"SHELLWARDEN_PLATFORM","value":"openshift"}]}}}'
wait_for 300 "operator restarted in OpenShift mode" sh -c \
  "kubectl -n operators logs deploy/shellwarden-operator | grep -q 'platform: openshift'"
wait_for 300 "StatefulSet without runAsUser and fsGroup" sh -c "[ -z \"\$(kubectl -n $NS get sts openshell -o jsonpath='{.spec.template.spec.securityContext.fsGroup}{.spec.template.spec.containers[0].securityContext.runAsUser}')\" ]"
kubectl -n $NS get sts openshell -o jsonpath='{.spec.template.spec.securityContext}{"\n"}{.spec.template.spec.containers[0].securityContext}{"\n"}' \
  | tee "$EVIDENCE/openshift-mode.txt"
kubectl -n $NS get openshell openshell -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' \
  | tee -a "$EVIDENCE/openshift-mode.txt" | grep -qx 'Deployed=True UpgradeSuccessful'
r1=$(rev); sleep 60; r2=$(rev)
echo "helm revision $r1 -> $r2 over 60s (OpenShift mode)" | tee -a "$EVIDENCE/revision-stable.txt"
[ "$r1" = "$r2" ]

step "back to Kubernetes mode: the gateway recovers"
kubectl -n operators patch subscription shellwarden-operator --type merge \
  -p '{"spec":{"config":{"env":[{"name":"SHELLWARDEN_PLATFORM","value":"kubernetes"}]}}}'
wait_for 300 "operator restarted in Kubernetes mode" sh -c \
  "kubectl -n operators logs deploy/shellwarden-operator | grep -q 'platform: kubernetes'"
wait_for 300 "StatefulSet pins runAsUser again" sh -c \
  "[ -n \"\$(kubectl -n $NS get sts openshell -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsUser}')\" ]"
# A pod stuck in CrashLoopBackOff keeps the old revision; StatefulSets do not replace it alone.
kubectl -n $NS delete pod openshell-0 --wait=false
kubectl -n $NS rollout status statefulset/openshell --timeout=300s
wait_for 120 "CLI connects again" sh -c "kubectl -n $NS exec openshell-cli -- openshell status | grep -q Connected"
echo "ok: gateway back after the switch" | tee -a "$EVIDENCE/openshift-mode.txt"

printf '\nE2E PASSED (shellwarden-operator.v%s, OpenShell %s). Evidence: %s\n' "$VERSION" "$OPENSHELL_VERSION" "$EVIDENCE"
