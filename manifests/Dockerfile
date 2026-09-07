# syntax=docker/dockerfile:1.7
FROM python:3.9

ENV DEBIAN_FRONTEND=noninteractive

RUN mkdir -p /mnt/vlan-ip /root/.linode-cli

RUN apt-get update && apt-get install -y \
    jq curl parallel net-tools apt-transport-https \
    ca-certificates iproute2 bash gnupg \
    iputils-ping dnsutils \
    iptables ipset && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip && \
    pip install linode-cli flask flask-cors etcd3 requests filelock aiohttp psutil kubernetes pyyaml 'protobuf<4.0.0,>=3.20.0'

RUN curl -L https://github.com/etcd-io/etcd/releases/download/v3.5.12/etcd-v3.5.12-linux-amd64.tar.gz -o etcd.tar.gz && \
    tar xzf etcd.tar.gz --strip-components=1 -C /usr/local/bin etcd-v3.5.12-linux-amd64/etcdctl && \
    chmod +x /usr/local/bin/etcdctl && rm -f etcd.tar.gz

RUN curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/kubectl

# === LNG NAT fleet sidecar: bake in the compiled client-agent binary ===
#
# client-agent turns a private GitHub NAT gateway fleet's roster into a
# working ECMP default route on this node's VLAN interface - see the NAT
# fleet integration design (ENABLE_NAT_FLEET/NAT_FLEET_ROSTER_URL) for the
# full picture. Baked in at image-build time, pinned to one exact release,
# rather than fetched at pod-start - a version bump is a one-line ARG
# change + rebuild, never a silent runtime drift (the sync-gap mistake the
# LNG project's own HANDOVER.md documents having made once already).
#
# sandipgangdhar/linode-nat-gateway is a PRIVATE repo, so this needs a
# real credential - but never as an ARG/ENV, which would bake the token
# into this image's layer history (`docker history` would show it
# forever, a real leak even if the layer is later removed). Supplied
# ONLY via a BuildKit --secret mount, scoped to just this one RUN layer,
# never written to any layer or printed. Every `docker build` of this
# image now requires (run from the REPO ROOT, not manifests/ - the build
# context now has to include scripts/06-rest-api.py for the Nuitka-compile
# stage further down this file, which manifests/ alone doesn't contain):
#
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=github_token,src=manifests/.github-client-agent-token \
#     -t ghcr.io/sandipgangdhar/linode-lke-private-network:latest \
#     -f manifests/Dockerfile .
#
# manifests/.github-client-agent-token is a gitignored, local-only file
# holding a fine-grained GitHub PAT scoped to ONLY this one repo with
# Contents: Read-only - nothing broader. See CLAUDE.md's Commands section
# for the full command and .gitignore's comment on this file.
#
# github.com/<repo>/releases/download/<tag>/<asset> does NOT work against
# a private repo even with a valid bearer token - that URL path is built
# for authenticated browser sessions, not API tokens (confirmed live,
# 2026-09-02: a correctly-scoped token still got a plain 404 there). The
# REST API's two-step asset flow below is the actually-correct path:
# resolve the release by tag to get the numeric asset id, then fetch that
# specific asset id with Accept: application/octet-stream.
ARG CLIENT_AGENT_REPO=sandipgangdhar/linode-nat-gateway
ARG CLIENT_AGENT_VERSION=v0.1.10

RUN --mount=type=secret,id=github_token,required=true \
    set -eu && \
    GH_TOKEN="$(cat /run/secrets/github_token)" && \
    ASSET_ID="$(curl -fsSL \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${CLIENT_AGENT_REPO}/releases/tags/${CLIENT_AGENT_VERSION}" \
      | jq -r '.assets[] | select(.name=="client-agent") | .id')" && \
    if [ -z "$ASSET_ID" ] || [ "$ASSET_ID" = "null" ]; then \
      echo "client-agent asset not found in release ${CLIENT_AGENT_VERSION} of ${CLIENT_AGENT_REPO} - check the tag exists and the token can read this repo." >&2; \
      exit 1; \
    fi && \
    curl -fsSL \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -o /usr/local/bin/client-agent \
      "https://api.github.com/repos/${CLIENT_AGENT_REPO}/releases/assets/${ASSET_ID}" && \
    [ "$(stat -c%s /usr/local/bin/client-agent)" -gt 1000000 ] && \
    chmod +x /usr/local/bin/client-agent

# === Compile scripts/06-rest-api.py via Nuitka, baked directly into this image ===
#
# NOT delivered via the vlan-manager-scripts ConfigMap the way scripts/*.sh
# are, and NOT compiled by the customer-repo publish pipeline the way
# scripts/*.sh are (see scripts/publish/shc_compile.sh) - both found live to
# be structurally impossible for this one file. A Kubernetes ConfigMap is
# hard-capped around 1-3MB regardless of etcd flags (confirmed live:
# `kubectl create cm ...` failed outright with "Request entity too large:
# limit is 3145728"), and a *standalone* Nuitka build (bundling a full
# self-contained Python runtime + every dependency - the only viable option
# when compiling on an unrelated CI runner for the customer-repo pipeline,
# which has no guarantee its environment matches whatever ships in this
# image) came out around 146MB - nowhere close to fitting either mechanism.
#
# Compiled HERE instead, in plain (non-standalone) Nuitka mode: this RUN
# layer runs inside the exact same Python environment/site-packages this
# binary will execute against at runtime (the `pip install` two layers
# above, in this same image) - no bundling needed at all, since the
# environment is guaranteed identical, not just "close enough." Produces a
# small, genuinely native-compiled binary. scripts/06-rest-api.py itself
# never ships to the customer repo at all as a result - not as plaintext,
# not as a compiled artifact - see assemble_customer_repo.py's own explicit
# removal of it from the assembled tree.
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc patchelf ccache && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir nuitka

COPY scripts/06-rest-api.py /tmp/06-rest-api.py
RUN python3 -m nuitka \
      --output-dir=/tmp/nuitka-build \
      --output-filename=06-rest-api \
      --remove-output \
      --assume-yes-for-downloads \
      /tmp/06-rest-api.py && \
    mv /tmp/nuitka-build/06-rest-api /usr/local/bin/06-rest-api && \
    chmod +x /usr/local/bin/06-rest-api && \
    rm -rf /tmp/06-rest-api.py /tmp/nuitka-build

CMD ["bash"]
