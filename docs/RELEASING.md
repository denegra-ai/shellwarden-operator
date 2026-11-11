# Releasing

A release is an operator image, pinned by digest, and one bundle per community catalog.

## 1. Version and upstream

- Bump `VERSION` in the Makefile. From the second release on, set
  `REPLACES=shellwarden-operator.v<previous>` and `SKIP_RANGE='>=0.1.0 <<new>'` (`ci.yaml` uses
  `replaces-mode`; see [DESIGN.md](DESIGN.md), "Upgrade graph").
- If OpenShell moved, set `OPENSHELL_VERSION` and the image digests, then `make vendor` and review
  the diff against [helm-charts/PATCHES.md](../helm-charts/PATCHES.md).
- `make validate e2e scorecard`. Before a release that replaces another, also
  `make kind-down upgrade-e2e AGENT_SANDBOX=bundled` and the same with `required`: each installs
  the previous version from the bundle its catalog publishes, starts a sandbox, upgrades to this
  tree, and checks the sandbox survives.

## 2. Operator image

Both community CIs pull the operator image anonymously, so it must be public. OpenShift's catalog
builds the bundle image in its own pipeline; only the operator image is ours to push.

Run the `image` workflow (Actions → image → Run workflow, version `X.Y.Z`); it pushes
`ghcr.io/denegra-ai/shellwarden-operator:vX.Y.Z` and prints the digest. Then pin it by digest in the Makefile (`IMG ?= ghcr.io/denegra-ai/shellwarden-operator@sha256:…`), so
`features.operators.openshift.io/disconnected: "true"` holds, and regenerate the bundle.

Before 1.0, build for arm64 too (`docker buildx build --platform linux/amd64,linux/arm64`; the
OpenShell images are already multi-arch) and add `operatorframework.io/arch.arm64: supported`.

## 3. Pull-request trees

```sh
make community-dirs
# dist/community-operators/operators/shellwarden-operator/{ci.yaml,VERSION/}       Agent Sandbox: required
# dist/community-operators-prod/operators/shellwarden-operator/{ci.yaml,VERSION/}  Agent Sandbox: bundled
```

`reviewers:` in `ci.yaml` lists the GitHub logins whose pull requests for this operator may merge
without a catalog maintainer.

## 4. Pull requests

One pull request per catalog, one commit, only the new version directory:
`k8s-operatorhub/community-operators` (OperatorHub.io) and
`redhat-openshift-ecosystem/community-operators-prod` (OpenShift). Title:
`operator shellwarden-operator (VERSION)`.

Both repositories require a DCO sign-off (`git commit -s`) whose name and email match the commit
author. A new operator is reviewed by the catalog maintainers; later versions merge after the
CI passes when a listed reviewer opens or approves them.

Never edit a published version directory; a bad bundle is followed by a fixed one that
`replaces` (and, if needed, `skips`) it.

OpenShift's catalog recommends FBC (`fbc.enabled` in `ci.yaml` with a catalog template) for new
operators; today that is a warning, not a failure.
