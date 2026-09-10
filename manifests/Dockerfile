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
# never written to any layer or printed. Build from manifests/ (this
# Dockerfile has no COPY of anything outside this directory):
#
#   cd manifests
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=github_token,src=.github-client-agent-token \
#     -t ghcr.io/sandipgangdhar/linode-lke-private-network:latest \
#     .
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
# Bumped v0.1.10 -> v0.1.40 (2026-09-10): confirmed live that v0.1.10 (cut
# 2026-09-02) predates the multi-URL NATCTL_ROSTER_URL fix HANDOVER.md
# section 11 describes landing 2026-09-07 - a comma-separated roster URL
# list (this repo's own documented HA pattern for natctl-on-node pools,
# see 00-vlan-manager-configmap.example.template.yaml's NAT_FLEET_ROSTER_URL
# comment) silently 404'd on every fetch with the old binary. A plain curl
# to the exact same URLs from the same pod succeeded every time, and
# client-agent's own retry loop never once succeeded across a full minute
# of 5s retries - ruling out timing/reachability and pointing straight at
# the binary not actually splitting the list (almost certainly treating
# the whole comma-joined string as one URL, hitting the first host with a
# garbled path). No sibling-project coordination to rely on here (per
# HANDOVER.md's own note, that team dropped this integration from their
# roadmap) - re-check the pinned version against this class of gap
# whenever NAT Fleet integration issues don't have an obvious cause.
ARG CLIENT_AGENT_REPO=sandipgangdhar/linode-nat-gateway
ARG CLIENT_AGENT_VERSION=v0.1.40

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

CMD ["bash"]
