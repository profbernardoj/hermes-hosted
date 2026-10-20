# Changelog

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
