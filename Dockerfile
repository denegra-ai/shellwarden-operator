# The operator image: operator-sdk's helm-operator on UBI 9 minimal, with the two vendored
# OpenShell charts and the watches files. Build: make docker-build.
ARG HELM_OPERATOR_IMAGE=quay.io/operator-framework/helm-operator:v1.42.3@sha256:80e0787ff36e85129d7983dc219736ba8a61e69857fbe46ec7389fddcbbf92f1

FROM ${HELM_OPERATOR_IMAGE} AS helm-operator

FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8

ARG VERSION=dev
ARG REVISION=unknown
ARG BUILD_DATE=unknown
ARG SOURCE=https://github.com/denegra-ai/shellwarden-operator
LABEL name="shellwarden-operator" \
      vendor="Denegra" \
      version="${VERSION}" \
      release="1" \
      maintainer="Denegra <opensource@denegra.ai>" \
      summary="Community operator that installs NVIDIA OpenShell" \
      description="Installs and upgrades NVIDIA OpenShell, the agent sandbox runtime, from an OpenShell resource. A community project, not affiliated with NVIDIA." \
      io.k8s.display-name="Denegra Shellwarden for NVIDIA OpenShell" \
      io.k8s.description="Installs and upgrades NVIDIA OpenShell from an OpenShell resource." \
      io.openshift.tags="openshell,agents,sandbox,operator,helm" \
      url="${SOURCE}" \
      vcs-ref="${REVISION}" \
      build-date="${BUILD_DATE}" \
      org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.title="shellwarden-operator" \
      org.opencontainers.image.vendor="Denegra"

ENV HOME=/opt/helm \
    USER_NAME=helm \
    USER_UID=1001

# Take UBI's errata at build time. curl is for the platform check in entrypoint.sh.
RUN microdnf -y update \
 && microdnf -y install --setopt=install_weak_deps=0 curl-minimal \
 && microdnf clean all \
 && echo "${USER_NAME}:x:${USER_UID}:0:${USER_NAME} user:${HOME}:/sbin/nologin" >> /etc/passwd \
 && mkdir -p "${HOME}"

WORKDIR ${HOME}

COPY --from=helm-operator /usr/local/bin/helm-operator /usr/local/bin/helm-operator
COPY LICENSE NOTICE /licenses/
COPY third_party/ /licenses/third_party/
COPY hack/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY watches.yaml watches-openshift.yaml ${HOME}/
COPY helm-charts/openshell ${HOME}/helm-charts/openshell
COPY helm-charts/openshell-openshift ${HOME}/helm-charts/openshell-openshift
COPY helm-charts/openshell-workspace ${HOME}/helm-charts/openshell-workspace

USER ${USER_UID}

ENTRYPOINT ["/bin/sh", "/usr/local/bin/entrypoint.sh"]
