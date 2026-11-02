# The tools every make target needs, in one image, so a checkout builds the same on Linux, macOS
# and Windows (Docker only). Build: make tools. Nothing from here ships.
ARG OPM_IMAGE=quay.io/operator-framework/opm:v1.71.0
ARG KUBECTL_IMAGE=registry.k8s.io/kubectl:v1.37.2
ARG HELM_IMAGE=alpine/helm:3.19.0
ARG YQ_IMAGE=mikefarah/yq:4.47.1
ARG DOCKER_IMAGE=docker:28.5.1-cli

FROM ${OPM_IMAGE} AS opm
FROM ${KUBECTL_IMAGE} AS kubectl
FROM ${HELM_IMAGE} AS helm
FROM ${YQ_IMAGE} AS yq
FROM ${DOCKER_IMAGE} AS docker

FROM python:3.12-slim
ARG OPERATOR_SDK_VERSION=v1.42.3
ARG KIND_VERSION=v0.33.0
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git make jq \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir pyyaml==6.0.3 yamllint==1.37.1 \
 && base=https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION} \
 && curl -fsSLo /usr/local/bin/operator-sdk ${base}/operator-sdk_linux_amd64 \
 && curl -fsSL ${base}/checksums.txt | grep ' operator-sdk_linux_amd64$' | sed 's|operator-sdk_linux_amd64|/usr/local/bin/operator-sdk|' | sha256sum -c - \
 && chmod +x /usr/local/bin/operator-sdk \
 && kbase=https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION} \
 && curl -fsSLo /usr/local/bin/kind ${kbase}/kind-linux-amd64 \
 && echo "$(curl -fsSL ${kbase}/kind-linux-amd64.sha256sum | cut -d' ' -f1)  /usr/local/bin/kind" | sha256sum -c - \
 && chmod +x /usr/local/bin/kind
COPY --from=opm /bin/opm /usr/local/bin/opm
COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl
COPY --from=helm /usr/bin/helm /usr/local/bin/helm
COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
# git refuses a checkout owned by another user (the mounted repository) without this.
RUN git config --system --add safe.directory '*'
WORKDIR /src
# opm pulls bundle images through containers/image, which needs a policy; this is the stock default
# (no signature checks; the lab and the catalogs name bundles by tag or digest).
COPY containers-policy.json /etc/containers/policy.json
