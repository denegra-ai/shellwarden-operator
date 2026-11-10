# Denegra Shellwarden for NVIDIA OpenShell: the shellwarden-operator.
#
# Needs: docker, and the tools in hack/tools.Dockerfile (opm, operator-sdk, kubectl, helm, yq,
# kind, python3 + PyYAML). Without them, run any target through the tools image:
#   hack/make.sh <target>

VERSION ?= 0.1.2
# The previous release this one replaces, and the range it may skip. Empty for the first release.
REPLACES ?= shellwarden-operator.v0.1.1
SKIP_RANGE ?= >=0.1.0 <0.1.2
OPENSHELL_VERSION ?= 0.1.8
OPENSHIFT_VERSIONS ?= v4.19
# required: OLM installs kubernetes-sigs' Agent Sandbox Operator as a dependency (OperatorHub.io).
# bundled: the bundle carries the Agent Sandbox CRD and controller (OpenShift community catalog).
AGENT_SANDBOX ?= bundled
AGENT_SANDBOX_VERSION ?= v1.0.10
AGENT_SANDBOX_IMG ?= registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.10@sha256:594f4853913bca2b336d0267fe0978445f1aaa5837ed23797e48e745c8d6b610

# The digests make vendor pins into the gateway chart's values (helm-charts/PATCHES.md).
GATEWAY_DIGEST ?= sha256:d66352a54c680b652e5ddd7d19b9c1189568d18016f360b9b8c64014f13d89c4
SUPERVISOR_DIGEST ?= sha256:deadeacfdba6d12ca27e538d0002696369d4de5a4fcad075ab503495503af9d1
SANDBOX_RUNTIME_DIGEST ?= sha256:f0fe7dbf18d833acb5da99c405231124718f23b524aa8e3c0108e6f37530033b
# nvcr.io/nvidia/base/ubuntu:24.04, OpenShell's default sandbox image.
SANDBOX_BASE_DIGEST ?= sha256:fef8f2708dbb85fbfcba6503d805397d89d9210f375362ff3b9f7888eb297ca5

# Where images go. Nothing is pushed to a public registry by any target here; publishing is a
# release step (docs/RELEASING.md). The lab targets use a local registry instead (LAB_*).
REGISTRY ?= ghcr.io/denegra-ai
# The released image, pinned by digest (built by .github/workflows/image.yaml as v$(VERSION)).
IMG ?= $(REGISTRY)/shellwarden-operator@sha256:6d515c50e42f08186fdf5d1718c53af08424a451cd5dabbdac8c0f74f889555c
BUNDLE_IMG ?= $(REGISTRY)/shellwarden-operator-bundle:v$(VERSION)
CATALOG_IMG ?= $(REGISTRY)/shellwarden-operator-catalog:v$(VERSION)
REVISION ?= $(shell git rev-parse HEAD 2>/dev/null)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# Local lab: a kind cluster and a registry:2 container on the kind network. The host pushes to
# localhost:$(LAB_PORT); the cluster and opm pull the same images as $(LAB_REGISTRY).
KIND_CLUSTER ?= shellwarden
LAB_REGISTRY_NAME ?= shellwarden-registry
LAB_PORT ?= 5001
LAB_REGISTRY ?= $(LAB_REGISTRY_NAME):5000
LAB_PUSH ?= localhost:$(LAB_PORT)
KUBECONFIG ?= $(CURDIR)/.kube/config
export KUBECONFIG

DIST ?= dist
PACKAGE = shellwarden-operator

BUNDLE_ENV = VERSION=$(VERSION) IMG=$(IMG) REPLACES=$(REPLACES) SKIP_RANGE='$(SKIP_RANGE)' \
  OPENSHELL_VERSION=$(OPENSHELL_VERSION) OPENSHIFT_VERSIONS=$(OPENSHIFT_VERSIONS) \
  AGENT_SANDBOX=$(AGENT_SANDBOX) AGENT_SANDBOX_VERSION=$(AGENT_SANDBOX_VERSION) \
  AGENT_SANDBOX_IMG=$(AGENT_SANDBOX_IMG)

.PHONY: help tools vendor bundle validate docker-build bundle-build catalog-build \
  lab-registry kind-up olm-install lab-images e2e upgrade-e2e scorecard kind-down lab-down community-dirs deploy undeploy

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

tools: ## Build the tools image (shellwarden-tools:dev) hack/make.sh uses
	docker build -f hack/tools.Dockerfile -t shellwarden-tools:dev hack

vendor: ## Re-vendor the OpenShell charts and Agent Sandbox at the pinned versions
	OPENSHELL_VERSION=$(OPENSHELL_VERSION) GATEWAY_DIGEST=$(GATEWAY_DIGEST) SUPERVISOR_DIGEST=$(SUPERVISOR_DIGEST) \
	  SANDBOX_RUNTIME_DIGEST=$(SANDBOX_RUNTIME_DIGEST) SANDBOX_BASE_DIGEST=$(SANDBOX_BASE_DIGEST) sh hack/vendor-charts.sh
	AGENT_SANDBOX_VERSION=$(AGENT_SANDBOX_VERSION) sh hack/vendor-agent-sandbox.sh

bundle: ## Write bundle/ from csv-base.yaml and config/ (AGENT_SANDBOX=required|bundled)
	$(BUNDLE_ENV) OUT=bundle python3 hack/gen-bundle.py

validate: bundle ## Validate bundle/ the way both community catalogs do, and lint it
	operator-sdk bundle validate ./bundle --select-optional suite=operatorframework --optional-values=k8s-version=1.37
	operator-sdk bundle validate ./bundle --select-optional name=operatorhub --optional-values=k8s-version=1.37
	operator-sdk bundle validate ./bundle --select-optional name=good-practices
	yamllint -d '{extends: default, rules: {line-length: {max: 180, level: warning}, indentation: {indent-sequences: whatever}, document-start: disable}}' bundle
	helm lint helm-charts/openshell --set agentSandbox.preflight.enabled=false
	helm lint helm-charts/openshell-workspace

docker-build: ## Build the operator image as IMG
	docker build --build-arg VERSION=$(VERSION) --build-arg REVISION=$(REVISION) \
	  --build-arg BUILD_DATE=$(BUILD_DATE) -t $(IMG) .

bundle-build: bundle ## Build the bundle image as BUNDLE_IMG
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

# A file-based catalog with this one bundle, for local OLM tests. opm reads the bundle image from
# a registry, so BUNDLE_IMG must have been pushed where opm can reach it (OPM_FLAGS=--use-http for
# a plain-HTTP lab registry).
OPM_FLAGS ?=
catalog-build: ## Render a one-bundle FBC catalog for BUNDLE_IMG and build CATALOG_IMG
	rm -rf $(DIST)/catalog && mkdir -p $(DIST)/catalog/$(PACKAGE)
	sed -e 's|BUNDLE_IMG|$(BUNDLE_IMG)|' -e 's|VERSION|$(VERSION)|' catalog/template.yaml > $(DIST)/template.yaml
	opm alpha render-template basic -o yaml $(OPM_FLAGS) $(DIST)/template.yaml > $(DIST)/catalog/$(PACKAGE)/catalog.yaml
	opm validate $(DIST)/catalog
	printf 'FROM quay.io/operator-framework/opm:v1.71.0\nENTRYPOINT ["/bin/opm"]\nCMD ["serve", "/configs", "--cache-dir=/tmp/cache"]\nADD catalog /configs\nRUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]\nLABEL operators.operatorframework.io.index.configs.v1=/configs\n' > $(DIST)/catalog.Dockerfile
	docker build -f $(DIST)/catalog.Dockerfile -t $(CATALOG_IMG) $(DIST)

# ---- Local lab: kind + OLM ----

lab-registry: ## Start the lab registry on the kind network (host port LAB_PORT)
	docker network inspect kind >/dev/null 2>&1 || docker network create kind
	docker inspect $(LAB_REGISTRY_NAME) >/dev/null 2>&1 \
	  || docker run -d --restart=no --name $(LAB_REGISTRY_NAME) --network kind -p 127.0.0.1:$(LAB_PORT):5000 registry:2

kind-up: lab-registry ## Create the kind cluster that pulls from the lab registry
	kind get clusters | grep -qx $(KIND_CLUSTER) || kind create cluster --name $(KIND_CLUSTER) --config hack/kind.yaml
	docker exec $(KIND_CLUSTER)-control-plane sh -c 'mkdir -p /etc/containerd/certs.d/$(LAB_REGISTRY) && printf "[host.\"http://$(LAB_REGISTRY)\"]\n  capabilities = [\"pull\", \"resolve\"]\n" > /etc/containerd/certs.d/$(LAB_REGISTRY)/hosts.toml'
	mkdir -p $(dir $(KUBECONFIG))
	kind get kubeconfig --name $(KIND_CLUSTER) $(if $(KIND_INTERNAL),--internal) > $(KUBECONFIG)
	kubectl wait --for=condition=Ready nodes --all --timeout=180s

olm-install: ## Install OLM into the kind cluster
	kubectl get ns olm >/dev/null 2>&1 || operator-sdk olm install --timeout 5m

# Build the operator, bundle and catalog for the lab registry and push them there.
lab-images:
	$(MAKE) docker-build IMG=$(LAB_PUSH)/$(PACKAGE):v$(VERSION)
	docker push $(LAB_PUSH)/$(PACKAGE):v$(VERSION)
	$(MAKE) bundle-build IMG=$(LAB_REGISTRY)/$(PACKAGE):v$(VERSION) BUNDLE_IMG=$(LAB_PUSH)/$(PACKAGE)-bundle:v$(VERSION)
	docker push $(LAB_PUSH)/$(PACKAGE)-bundle:v$(VERSION)
	$(MAKE) catalog-build OPM_FLAGS=--use-http BUNDLE_IMG=$(LAB_REGISTRY)/$(PACKAGE)-bundle:v$(VERSION) CATALOG_IMG=$(LAB_PUSH)/$(PACKAGE)-catalog:v$(VERSION)
	docker push $(LAB_PUSH)/$(PACKAGE)-catalog:v$(VERSION)

e2e: kind-up olm-install lab-images ## Install from a local catalog on kind, start a sandbox, check the CR drives the release
	CATALOG_IMG=$(LAB_REGISTRY)/$(PACKAGE)-catalog:v$(VERSION) VERSION=$(VERSION) LAB_REGISTRY=$(LAB_REGISTRY) \
	  LAB_PUSH=$(LAB_PUSH) sh hack/e2e.sh

# The release this one replaces, as its catalog publishes it. Run on a fresh cluster:
#   make kind-down upgrade-e2e AGENT_SANDBOX=bundled|required
PREVIOUS ?= $(REPLACES:$(PACKAGE).v%=%)
upgrade-e2e: kind-up olm-install ## Upgrade the published PREVIOUS bundle to this one on kind, with a sandbox across it
	$(MAKE) docker-build IMG=$(LAB_PUSH)/$(PACKAGE):v$(VERSION)
	docker push $(LAB_PUSH)/$(PACKAGE):v$(VERSION)
	$(MAKE) bundle-build IMG=$(LAB_REGISTRY)/$(PACKAGE):v$(VERSION) BUNDLE_IMG=$(LAB_PUSH)/$(PACKAGE)-bundle:v$(VERSION)-$(AGENT_SANDBOX)
	docker push $(LAB_PUSH)/$(PACKAGE)-bundle:v$(VERSION)-$(AGENT_SANDBOX)
	VERSION=$(VERSION) PREVIOUS=$(PREVIOUS) AGENT_SANDBOX=$(AGENT_SANDBOX) OPENSHELL_VERSION=$(OPENSHELL_VERSION) \
	  LAB_REGISTRY=$(LAB_REGISTRY) LAB_PUSH=$(LAB_PUSH) sh hack/upgrade-e2e.sh
	@$(MAKE) --no-print-directory bundle >/dev/null

scorecard: bundle ## Run the bundle's scorecard tests on the kind cluster
	kubectl create namespace scorecard --dry-run=client -o yaml | kubectl apply -f -
	operator-sdk scorecard ./bundle -n scorecard --wait-time 300s -o text

kind-down: ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

lab-down: kind-down ## Delete the kind cluster and the lab registry
	docker rm -f $(LAB_REGISTRY_NAME)

# ---- Community catalogs ----

# operators/shellwarden-operator/{ci.yaml,VERSION/{manifests,metadata,tests}} for each catalog, as a pull
# request to it expects: dist/community-operators (OperatorHub.io, Agent Sandbox required) and
# dist/community-operators-prod (OpenShift, Agent Sandbox bundled). Writes files only.
community-dirs: ## Lay out the pull-request trees for both community catalogs under dist/
	@for c in community-operators:required community-operators-prod:bundled; do \
	  repo=$${c%%:*}; variant=$${c##*:}; d=$(DIST)/$$repo/operators/$(PACKAGE); \
	  rm -rf $$d/$(VERSION) && mkdir -p $$d && \
	  $(MAKE) --no-print-directory bundle AGENT_SANDBOX=$$variant >/dev/null && \
	  cp -R bundle $$d/$(VERSION) && cp ci.yaml $$d/ci.yaml && echo "wrote $$d/$(VERSION) ($$variant)"; \
	done
	@$(MAKE) --no-print-directory bundle >/dev/null

# ---- Without OLM ----

deploy: ## Install the CRDs, RBAC and operator with kubectl (no OLM; Agent Sandbox not included)
	kubectl apply -f config/crd/
	kubectl create namespace $(PACKAGE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n $(PACKAGE) -f config/rbac/role.yaml
	kubectl create clusterrolebinding $(PACKAGE) --clusterrole=$(PACKAGE) --serviceaccount=$(PACKAGE):$(PACKAGE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create rolebinding $(PACKAGE)-leader-election -n $(PACKAGE) --role=$(PACKAGE)-leader-election --serviceaccount=$(PACKAGE):$(PACKAGE) --dry-run=client -o yaml | kubectl apply -f -
	sed 's|image: IMG|image: $(IMG)|' config/manager/deployment.yaml | kubectl apply -n $(PACKAGE) -f -

undeploy:
	kubectl delete namespace $(PACKAGE) --ignore-not-found
	kubectl delete clusterrolebinding $(PACKAGE) --ignore-not-found
	kubectl delete -f config/crd/ --ignore-not-found
