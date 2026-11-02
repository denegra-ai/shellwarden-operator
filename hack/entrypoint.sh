#!/bin/sh
# Start helm-operator with the watches file for this platform.
#
# SHELLWARDEN_PLATFORM=openshift|kubernetes decides. Unset, the platform is OpenShift when the API
# server serves security.openshift.io/v1 (discovery is open to every authenticated identity).
set -eu

platform=${SHELLWARDEN_PLATFORM:-}
if [ -z "$platform" ]; then
  sa=/var/run/secrets/kubernetes.io/serviceaccount
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --cacert "$sa/ca.crt" -H "Authorization: Bearer $(cat "$sa/token")" \
    "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/apis/security.openshift.io/v1" || true)
  case "$code" in
    200) platform=openshift ;;
    404) platform=kubernetes ;;
    *) echo "cannot tell the platform (discovery answered '$code'); set SHELLWARDEN_PLATFORM" >&2; exit 1 ;;
  esac
fi

case "$platform" in
  openshift) watches=./watches-openshift.yaml ;;
  kubernetes) watches=./watches.yaml ;;
  *) echo "SHELLWARDEN_PLATFORM must be openshift or kubernetes, not '$platform'" >&2; exit 1 ;;
esac
echo "platform: $platform, watches: $watches"
exec /usr/local/bin/helm-operator run --watches-file="$watches" "$@"
