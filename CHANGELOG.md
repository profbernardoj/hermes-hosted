# Changelog

## 2026.10.20 (v6 + v7 — Fred ContainerExited fixes)

### Fixed
- **v6:** `CMD ["sleep","infinity"]` replaces `["gateway","run"]` — `gateway
  run` is the MESSAGING-gateway invocation (exits with no channels → /init
  stage-3 shutdown → container dies during Fred's startup supervision; three
  rejected leases). `sleep infinity` is the documented bare-exec main
  program; the s6 services (main-hermes, dashboard, loopback api_server,
  cig-adapter, auth-proxy) do all the work.
- **v6:** Dashboard ALWAYS on + ALWAYS loopback (image invariant): cont-init
  writes HERMES_DASHBOARD=1 / HOST=127.0.0.1 / PORT=9119 into
  /run/s6/container_environment. Upstream's dashboard s6 service defaults to
  0.0.0.0, which engages its own auth gate and fail-closes without a
  provider ("Refusing to bind dashboard", crash-loop in the v5 smoke log).
  Our Privy auth-proxy fronts :18789 → 127.0.0.1:9119.
- **v6:** smoke-boot.yml hard gates: 10-minute liveness window (hard fail,
  Fred parity — the old 45s window was a false pass), per-service assertions
  (auth-proxy login 200, dashboard loopback 200, api_server listening,
  cig-adapter /healthz 200), dashboard-bind regression guard, idempotent
  `docker rm -f smoke` pre-flight, synthetic ES256 pub key so the auth-proxy
  boots fully in smoke.
- **v7:** Auth-proxy login bundle is now BUILT at image build time
  (`npm ci --ignore-scripts` → `npm run build` (esbuild bundles login-app.jsx
  + React + Privy SDK → dist/login-bundle.js) → prod-only reinstall) — the
  everclaw auth-proxy-builder pattern. Without it the auth-proxy exits with
  ENOENT and crash-loops; masked in v1–v6 because the missing-PRIVY
  validation exited earlier. Also COPYs login-app.jsx, build-login.mjs,
  package-lock.json (npm ci reproducibility), and assets/logo.png
  (server.mjs:1619 login-page logo).
- **v7:** smoke assertion curl made failure-safe (`|| echo fail`) — `set -e`
  killed the step on curl exit 56 before the HTTP-code check could report.

### Audits
- Grok 4.20 reasoning (v6 delta): R1 FIX_REQUIRED (C=1: missing docker rm -f
  pre-flight) → fixed → R2 SHIP (C=0 S=0 Y=2).
- Grok 4.20 reasoning (v7 delta): see audit trail in the rollout record.

## 2026.10.20 (v1 initial build)

### Added
- Initial hermes-hosted image: NousResearch hermes-agent v0.22.2 base +
  everclaw auth-proxy (unmodified, OPENCLAW_INTERNAL_PORT=9119) fronting the
  hermes dashboard, loopback cig-adapter (OpenAI-compatible → CIG token
  minting), headless cont-init config writer (config.yaml + .env + SOUL.md),
  s6 service definitions, GitHub Actions → GHCR (amd64).
- First build of the InstallHermes vertical (SOP-001 Stage 2, plan v2).

## 2026.10.20.1 (v2 staging fix)

### Fixed
- **ContainerExited during startup** (first staging buffer, lease 01a156ce): the
  base image's default CMD is the interactive `hermes` TUI, which exits without
  a TTY. Headless CMD is now `gateway run` (supervised heartbeat; s6 runs the
  gateway + dashboard).
- `node` symlinked into /usr/local/bin (s6 services run with a minimal PATH).
- ARG re-declared after FROM so the base-image LABEL resolves.

## 2026.10.20.2 (v4 smoke-diagnosed fixes)

### Fixed
- auth-proxy crashed at boot: `egress-probes.mjs` was not copied into the image
  (server.mjs imports it). Full runtime file set now copied.
- s6 services ran with a SCRUBBED environment (`/init` scrubs env before
  services; the base image's own main-wrapper rehydrates via `with-contenv`).
  Both service run scripts now wrap with `/command/with-contenv` — without it
  CIG_*/BRAND_*/HANDOFF_* env was invisible to auth-proxy and cig-adapter.
