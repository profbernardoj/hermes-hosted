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
#   3. entrypoint    — v8 PID 1 supervisor (NO s6). Runs the cont-init
#                     scripts, starts the services (privilege-dropped via
#                     s6-setuidgid from the IMAGE LAYER), supervises with
#                     backoff. NOTHING EXECUTES FROM /run — Fred's tenant
#                     sandbox denies exec under /run, which kills every
#                     s6-overlay image (stage0 execs its runtime-generated
#                     /run/s6/basedir/bin/init; 5/5 leases 2026-10-20).
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
COPY auth-proxy/login-app.jsx /usr/local/lib/installhermes/auth-proxy/login-app.jsx
COPY auth-proxy/build-login.mjs /usr/local/lib/installhermes/auth-proxy/build-login.mjs
COPY auth-proxy/package.json /usr/local/lib/installhermes/auth-proxy/package.json
COPY auth-proxy/package-lock.json /usr/local/lib/installhermes/auth-proxy/package-lock.json
COPY auth-proxy/assets/ /usr/local/lib/installhermes/auth-proxy/assets/

# --- Auth-proxy: deps + LOGIN BUNDLE BUILD (everclaw auth-proxy-builder pattern) ---
# The login page is a BUILD ARTIFACT: build-login.mjs (esbuild) bundles
# login-app.jsx + React + the Privy SDK into dist/login-bundle.js, which
# server.mjs loads at boot. Without it the auth-proxy exits (ENOENT) and
# crash-loops — nothing ever listens on :18789 (v6 smoke catch; masked in
# v1-v5 because the missing-PRIVY validation exited first).
# Sequence mirrors the everclaw Dockerfile: install ALL deps
# (--ignore-scripts skips optional native addon compilation), build the
# bundle, then reinstall prod-only. assets/logo.png is served on the login
# page (server.mjs:1619).
RUN cd /usr/local/lib/installhermes/auth-proxy && \
    npm ci --ignore-scripts --no-audit --no-fund && \
    npm run build && \
    rm -rf node_modules && \
    npm ci --omit=dev --no-audit --no-fund && \
    npm cache clean --force

# --- Degraded-mode drop shim (v9) ---
# Fred's tenant sandbox denies the hermes privilege drop (lease 01a159c1:
# s6-applyuidgid fatal, setgroups EPERM; chown to uid 10000 fails the same
# way). Baked at BUILD time with mode 755 — the v9 entrypoint prepends its
# dir to PATH ONLY when its drop probe fails, so upstream cont-init (which
# hard-requires the drop under set -eu) completes as root (the everclaw/IOC
# fleet pattern on the same backend) and NO runtime chmod/chown is needed
# (also denied). When drops work, the real /command/s6-setuidgid stays on
# PATH and this shim is inert.
COPY shims/s6-setuidgid /usr/local/lib/installhermes/shims/s6-setuidgid
RUN chmod 755 /usr/local/lib/installhermes/shims/s6-setuidgid

# --- Service startup: v8 entrypoint supervisor (NO s6 services) ---
# v7 registered cig-adapter + auth-proxy as s6-rc services and let the base
# image's /init run the supervision tree. That is impossible on Fred: s6
# stage0 generates and execs /run/s6/basedir/bin/init, and Fred's tenant
# sandbox denies exec under /run (5/5 rejected leases, "Permission denied",
# exit 126). v8 replaces the base image's ENTRYPOINT entirely — our
# supervisor is PID 1, runs cont-init from the image layer, privilege-drops
# each service via s6-setuidgid (also image-layer), and restarts crashes
# with backoff. main-hermes (upstream no-op sleep) and the gateway (exits
# without channels; api_server :8642 therefore not listening) are not
# started; the dashboard provides the product chat surface.
COPY entrypoint.sh /usr/local/bin/installhermes-entrypoint
RUN chmod +x /usr/local/bin/installhermes-entrypoint

# --- Launchers ---
COPY bin/cig-adapter /usr/local/bin/cig-adapter
COPY bin/auth-proxy /usr/local/bin/auth-proxy
RUN chmod +x /usr/local/bin/cig-adapter /usr/local/bin/auth-proxy

# --- cont-init: headless hermes config (run by the v8 entrypoint, before services) ---
COPY cont-init.d/02-installhermes-config.sh /etc/cont-init.d/02-installhermes-config.sh
RUN chmod +x /etc/cont-init.d/02-installhermes-config.sh

# v8: OUR ENTRYPOINT replaces the base image's s6-overlay entrypoint. No CMD —
# the supervisor never execs a main program; it IS the container's lifetime.
ENTRYPOINT ["/usr/local/bin/installhermes-entrypoint"]
# Env contract (set by provision-buffer / deploy-agent manifests):
#   See README.md "Container environment contract".
