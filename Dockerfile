# syntax=docker/dockerfile:1

# =============================================================================
# hermes-hosted — InstallHermes.ai container image
#
# The REAL NousResearch hermes-agent, hosted on Manifest Network leases,
# fronted by our Privy auth-proxy, powered by Morpheus inference via CIG.
#
# Layers added on top of the official image:
#   1. auth-proxy   — Privy JWT auth + dynamic ownership + SSO handoff.
#                     Generic HTTP front (everclaw auth-proxy, unmodified):
#                     ingress :18789 → upstream 127.0.0.1:9119 (hermes dashboard).
#   2. cig-adapter  — loopback OpenAI-compatible shim on :18900.
#                     hermes LLM calls (OPENAI_BASE_URL) hit it with a static
#                     local key; it mints short-lived CIG tokens (service mode,
#                     binding_secret) and forwards to cig-inference → Morpheus.
#                     No Morpheus master key ever enters the container.
#   3. cont-init    — writes hermes config.yaml + .env from container env
#                     (headless, no interactive setup).
#
# SOP-004 hard rules honored: built by GitHub Actions → GHCR only; amd64;
# NEVER built locally on the Mac mini. Base pinned to an immutable version
# tag (v0.22.2, stable 2026-10-15); digest-pin in the release notes.
# =============================================================================

ARG HERMES_BASE_VERSION=v0.22.2
FROM docker.io/nousresearch/hermes-agent:${HERMES_BASE_VERSION}
ARG HERMES_BASE_VERSION

# --- Metadata ---
LABEL org.opencontainers.image.title="hermes-hosted"
LABEL org.opencontainers.image.description="Hosted Hermes Agent (InstallHermes.ai) — Privy auth + Morpheus CIG inference"
LABEL org.opencontainers.image.source="https://github.com/profbernardoj/hermes-hosted"
LABEL io.installhermes.base-image="nousresearch/hermes-agent:${HERMES_BASE_VERSION}"

# --- Our services (copied before s6 service definitions) ---
COPY cig-adapter/server.mjs /usr/local/lib/installhermes/cig-adapter/server.mjs
COPY auth-proxy/server.mjs /usr/local/lib/installhermes/auth-proxy/server.mjs
COPY auth-proxy/egress-probes.mjs /usr/local/lib/installhermes/auth-proxy/egress-probes.mjs
COPY auth-proxy/login.html /usr/local/lib/installhermes/auth-proxy/login.html
COPY auth-proxy/package.json /usr/local/lib/installhermes/auth-proxy/package.json

# --- Runtime deps for the auth-proxy (Node is in the base image via pm) ---
# Pinned exact versions (supply-chain discipline, SOP-001 §6):
RUN cd /usr/local/lib/installhermes/auth-proxy && \
    npm install --omit=dev --no-audit --no-fund \
      cookie@1.0.2 http-proxy@1.18.1 jose@6.0.10 && \
    npm cache clean --force

# --- s6 service definitions (the base image is s6-overlay PID 1) ---
# cig-adapter: loopback-only OpenAI-compatible endpoint for hermes LLM calls.
RUN mkdir -p /etc/s6-overlay/s6-rc.d/cig-adapter /etc/s6-overlay/s6-rc.d/user/contents.d && \
    printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/cig-adapter/type && \
    printf '#!/command/execlineb -P\n/command/with-contenv s6-setuidgid hermes /usr/local/bin/cig-adapter\n' \
      > /etc/s6-overlay/s6-rc.d/cig-adapter/run && \
    chmod +x /etc/s6-overlay/s6-rc.d/cig-adapter/run && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/cig-adapter

# auth-proxy: the ONLY externally-exposed surface (ingress :18789).
RUN mkdir -p /etc/s6-overlay/s6-rc.d/auth-proxy /etc/s6-overlay/s6-rc.d/user/contents.d && \
    printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/auth-proxy/type && \
    printf '#!/command/execlineb -P\n/command/with-contenv s6-setuidgid hermes /usr/local/bin/auth-proxy\n' \
      > /etc/s6-overlay/s6-rc.d/auth-proxy/run && \
    chmod +x /etc/s6-overlay/s6-rc.d/auth-proxy/run && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/auth-proxy

# --- Launchers ---
COPY bin/cig-adapter /usr/local/bin/cig-adapter
COPY bin/auth-proxy /usr/local/bin/auth-proxy
RUN chmod +x /usr/local/bin/cig-adapter /usr/local/bin/auth-proxy

# --- cont-init: headless hermes config (runs before any service) ---
COPY cont-init.d/02-installhermes-config.sh /etc/cont-init.d/02-installhermes-config.sh
RUN chmod +x /etc/cont-init.d/02-installhermes-config.sh

# Headless CMD (staging fix v2): the base image's default CMD is the
# interactive `hermes` TUI — it exits without a TTY and kills the container
# during startup (lease 01a156ce: LEASE_STATE_REJECTED/ContainerExited).
# `gateway run` is the official headless invocation: a supervised sleep
# heartbeat while s6-overlay manages the actual gateway + dashboard.
CMD ["gateway", "run"]

# Base image ENTRYPOINT (/init → s6) is inherited.
# Env contract (set by provision-buffer / deploy-agent manifests):
#   See README.md "Container environment contract".
