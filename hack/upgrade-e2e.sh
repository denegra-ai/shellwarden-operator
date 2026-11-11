#!/bin/sh
# Upgrade test on a fresh lab kind cluster (make upgrade-e2e): install the PREVIOUS version from its
# published bundle with OLM, start a sandbox, approve the upgrade to this version's lab bundle, and
# check that the operator, the gateway and the sandbox come through it. Evidence goes to $EVIDENCE.
#
# The previous bundle is the one the community catalog serves (bundled: Red Hat's pipeline image,
# required: OperatorHub.io's), copied into the lab registry so opm can read both over plain HTTP.
set -eu
: "${VERSION:?}" "${PREVIOUS:?}" "${AGENT_SANDBOX:?}" "${LAB_REGISTRY:?}" "${LAB_PUSH:?}"
PREVIOUS_OPENSHELL=${PREVIOUS_OPENSHELL:-0.1.6}
OPENSHELL_VERSION=${OPENSHELL_VERSION:-0.1.8}
EVIDENCE=${EVIDENCE:-dist/upgrade-e2e-$AGENT_SANDBOX}
NS=openshell
case $AGENT_SANDBOX in
  bundled) PREVIOUS_SRC=${PREVIOUS_BUNDLE:-quay.io/community-operator-pipeline-prod/shellwarden-operator:$PREVIOUS} ;;
  required) PREVIOUS_SRC=${PREVIOUS_BUNDLE:-quay.io/operatorhubio/shellwarden-operator:v$PREVIOUS} ;;
  *) echo "AGENT_SANDBOX is bundled or required" >&2; exit 1 ;;
esac
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
csv_phase() { kubectl -n operators get csv "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
# approve <csv>: approve the InstallPlan that installs it.
approve() {
  wait_for 300 "InstallPlan for $1" sh -c \
    "kubectl -n operators get installplan -o jsonpath='{range .items[*]}{.spec.clusterServiceVersionNames}{\"\\n\"}{end}' | grep -q '\"$1\"'"
  for ip in $(kubectl -n operators get installplan -o name); do
    if kubectl -n operators get "$ip" -o jsonpath='{.spec.clusterServiceVersionNames}' | grep -q "\"$1\""; then
      kubectl -n operators patch "$ip" --type merge -p '{"spec":{"approved":true}}'
    fi
  done
}
# cli_image <openshell version>: the openshell CLI release binary in an image, in the lab registry.
cli_image() {
  img=$LAB_PUSH/shellwarden-lab-cli:$1
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    d=$(mktemp -d)
    base=https://github.com/NVIDIA/OpenShell/releases/download/v$1
    curl -fsSL -o "$d/openshell.tgz" "$base/openshell-x86_64-unknown-linux-musl.tar.gz"
    curl -fsSL -o "$d/sums" "$base/openshell-checksums-sha256.txt"
    (cd "$d" && grep ' openshell-x86_64-unknown-linux-musl.tar.gz$' sums | sed 's| openshell-x86_64-unknown-linux-musl.tar.gz$| openshell.tgz|' | sha256sum -c -)
    tar -xzf "$d/openshell.tgz" -C "$d"
    printf 'FROM alpine:3.20\nRUN apk add --no-cache openssh-client\nCOPY openshell /usr/local/bin/openshell\n' > "$d/Dockerfile"
    docker build -q -t "$img" "$d"
    rm -rf "$d"
  fi
  docker push -q "$img"
}
# cli_pod <openshell version>: (re)start the CLI pod with that version and add the gateway.
cli_pod() {
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
      image: $LAB_REGISTRY/shellwarden-lab-cli:$1
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
  cli openshell gateway add https://openshell.$NS.svc.cluster.local:8080 --local --name lab
}
cli() { kubectl -n $NS exec openshell-cli -- "$@"; }

if kubectl get csv -A 2>/dev/null | grep -q shellwarden-operator; then
  echo "shellwarden-operator is already installed here; start from a fresh cluster (make kind-down)" >&2
  exit 1
fi

step "bundles: $PREVIOUS as published, $VERSION from this tree ($AGENT_SANDBOX)"
prev=shellwarden-operator-bundle:v$PREVIOUS-$AGENT_SANDBOX-published
docker pull -q "$PREVIOUS_SRC"
docker tag "$PREVIOUS_SRC" "$LAB_PUSH/$prev"
docker push -q "$LAB_PUSH/$prev"
docker image inspect "$PREVIOUS_SRC" --format '{{index .RepoDigests 0}}' | tee "$EVIDENCE/previous-bundle.txt"

step "catalog with both"
cat_dir=$EVIDENCE/catalog
rm -rf "$cat_dir" && mkdir -p "$cat_dir/configs/shellwarden-operator"
cat > "$cat_dir/template.yaml" <<EOF
schema: olm.template.basic
entries:
  - schema: olm.package
    name: shellwarden-operator
    defaultChannel: alpha
  - schema: olm.channel
    package: shellwarden-operator
    name: alpha
    entries:
      - name: shellwarden-operator.v$PREVIOUS
      - name: shellwarden-operator.v$VERSION
        replaces: shellwarden-operator.v$PREVIOUS
        skipRange: '>=0.1.0 <$VERSION'
  - schema: olm.bundle
    image: $LAB_REGISTRY/$prev
  - schema: olm.bundle
    image: $LAB_REGISTRY/shellwarden-operator-bundle:v$VERSION-$AGENT_SANDBOX
EOF
opm alpha render-template basic -o yaml --use-http "$cat_dir/template.yaml" > "$cat_dir/configs/shellwarden-operator/catalog.yaml"
opm validate "$cat_dir/configs"
printf 'FROM quay.io/operator-framework/opm:v1.71.0\nENTRYPOINT ["/bin/opm"]\nCMD ["serve", "/configs", "--cache-dir=/tmp/cache"]\nADD configs /configs\nRUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]\nLABEL operators.operatorframework.io.index.configs.v1=/configs\n' > "$cat_dir/Dockerfile"
catalog=shellwarden-operator-catalog:upgrade-$PREVIOUS-$VERSION-$AGENT_SANDBOX
docker build -q -t "$LAB_PUSH/$catalog" "$cat_dir"
docker push -q "$LAB_PUSH/$catalog"
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: shellwarden-upgrade
  namespace: olm
spec:
  sourceType: grpc
  image: $LAB_REGISTRY/$catalog
  displayName: Shellwarden upgrade lab
  publisher: lab
  grpcPodConfig:
    securityContextConfig: restricted
EOF
wait_for 300 "catalog ready" sh -c \
  '[ "$(kubectl -n olm get catalogsource shellwarden-upgrade -o jsonpath={.status.connectionState.lastObservedState})" = READY ]'

step "install $PREVIOUS (manual approval)"
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: shellwarden-operator
  namespace: operators
spec:
  channel: alpha
  name: shellwarden-operator
  source: shellwarden-upgrade
  sourceNamespace: olm
  startingCSV: shellwarden-operator.v$PREVIOUS
  installPlanApproval: Manual
EOF
approve shellwarden-operator.v$PREVIOUS
wait_for 600 "CSV shellwarden-operator.v$PREVIOUS Succeeded" sh -c "[ \"\$(kubectl -n operators get csv shellwarden-operator.v$PREVIOUS -o jsonpath={.status.phase})\" = Succeeded ]"
kubectl -n operators get csv,deploy -o wide | tee "$EVIDENCE/before.txt"

step "OpenShell and a sandbox on $PREVIOUS"
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n $NS -f config/samples/openshell_v1alpha1_openshell.yaml
wait_for 600 "OpenShell Deployed" kubectl -n $NS wait openshell/openshell --for=condition=Deployed --timeout=5s
kubectl -n $NS rollout status statefulset/openshell --timeout=600s
cli_image "$PREVIOUS_OPENSHELL"
cli_pod "$PREVIOUS_OPENSHELL"
cli openshell sandbox create --name upg -- sh -c 'echo before-upgrade' 2>&1 | tee "$EVIDENCE/sandbox-before.txt"
grep -q before-upgrade "$EVIDENCE/sandbox-before.txt"
gateway_before=$(kubectl -n $NS get sts openshell -o jsonpath='{.spec.template.spec.containers[0].image}')
# Shared workspace mode names the Sandbox and its pod <workspace>--<name>.
sandbox_uid=$(kubectl -n $NS get pod default--upg -o jsonpath='{.metadata.uid}')
{ echo "gateway image: $gateway_before"; echo "sandbox pod default--upg uid: $sandbox_uid"; } | tee -a "$EVIDENCE/before.txt"

step "upgrade to $VERSION"
approve shellwarden-operator.v$VERSION
wait_for 600 "CSV shellwarden-operator.v$VERSION Succeeded" sh -c "[ \"\$(kubectl -n operators get csv shellwarden-operator.v$VERSION -o jsonpath={.status.phase})\" = Succeeded ]"
wait_for 300 "CSV shellwarden-operator.v$PREVIOUS gone" sh -c "! kubectl -n operators get csv shellwarden-operator.v$PREVIOUS"
gateway_digest=$(yq '.gateway.image.digest' helm-charts/openshell/values.yaml)
wait_for 600 "gateway on the $OPENSHELL_VERSION image" sh -c \
  "kubectl -n $NS get sts openshell -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q '$gateway_digest'"
kubectl -n $NS rollout status statefulset/openshell --timeout=600s
wait_for 300 "OpenShell Deployed" kubectl -n $NS wait openshell/openshell --for=condition=Deployed --timeout=5s
kubectl -n operators get csv,deploy -o wide | tee "$EVIDENCE/after.txt"
if [ "$AGENT_SANDBOX" = bundled ]; then
  kubectl -n operators get deploy agent-sandbox-controller -o jsonpath='{.metadata.labels.olm\.owner} {.spec.template.spec.containers[0].image}{"\n"}' \
    | tee -a "$EVIDENCE/after.txt" | grep -q "^shellwarden-operator.v$VERSION "
  echo "ok: agent-sandbox-controller belongs to the new CSV"
fi

step "the sandbox came through; a new one starts"
cli_image "$OPENSHELL_VERSION"
cli_pod "$OPENSHELL_VERSION"
cli openshell sandbox list | tee "$EVIDENCE/sandbox-list-after.txt"
grep -q '^upg ' "$EVIDENCE/sandbox-list-after.txt"
[ "$(kubectl -n $NS get pod default--upg -o jsonpath='{.metadata.uid}')" = "$sandbox_uid" ]
echo "ok: sandbox upg listed by the new gateway, its pod not replaced" | tee -a "$EVIDENCE/after.txt"
cli openshell sandbox create --name after -- sh -c 'echo after-upgrade' 2>&1 | tee "$EVIDENCE/sandbox-after.txt"
grep -q after-upgrade "$EVIDENCE/sandbox-after.txt"
{ echo "gateway image: $(kubectl -n $NS get sts openshell -o jsonpath='{.spec.template.spec.containers[0].image}')"; } | tee -a "$EVIDENCE/after.txt"

printf '\nUPGRADE PASSED (%s -> %s, %s). Evidence: %s\n' "$PREVIOUS" "$VERSION" "$AGENT_SANDBOX" "$EVIDENCE"
