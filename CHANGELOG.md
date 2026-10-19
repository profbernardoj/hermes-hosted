# Changelog

## 2026.10.20 (v1 initial build)

### Added
- Initial hermes-hosted image: NousResearch hermes-agent v0.22.2 base +
  everclaw auth-proxy (unmodified, OPENCLAW_INTERNAL_PORT=9119) fronting the
  hermes dashboard, loopback cig-adapter (OpenAI-compatible → CIG token
  minting), headless cont-init config writer (config.yaml + .env + SOUL.md),
  s6 service definitions, GitHub Actions → GHCR (amd64).
- First build of the InstallHermes vertical (SOP-001 Stage 2, plan v2).
