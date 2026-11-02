#!/bin/sh
# Run a make target inside the tools image, for hosts without make, Python, opm or operator-sdk
# (Windows with Docker Desktop, for one). The host's Docker socket is passed in, so the docker
# and kind targets work too; the container joins the "kind" network when it exists, so it can
# reach a kind cluster's API server and the local registry by name.
#
#   hack/make.sh bundle
#   hack/make.sh e2e
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
# Docker Desktop on Windows wants the Windows form of the path for a bind mount.
src=$(cd "$here" && { pwd -W 2>/dev/null || pwd; })
img=${TOOLS_IMG:-shellwarden-tools:dev}
docker image inspect "$img" >/dev/null 2>&1 \
  || docker build -q -f "$here/hack/tools.Dockerfile" -t "$img" "$here/hack" >/dev/null
# The container joins the kind network, so it reaches the cluster's API and the lab registry by
# name. Create it first if this is the first run (kind uses an existing network of that name).
docker network inspect kind >/dev/null 2>&1 || docker network create kind >/dev/null
net="--network kind"
# Git Bash on Windows rewrites /src-style arguments into Windows paths; this stops it.
MSYS_NO_PATHCONV=1 exec docker run --rm $net \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$src":/src -w /src \
  -e KIND_INTERNAL=1 \
  "$img" make "$@"
