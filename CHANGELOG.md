# Changelog

## 2026.10.20 (v9.2 — HERMES_HOME writability chain + boot forensics: Fred restriction #3)

### Fixed
- **THIRD Fred restriction found via lease 01a15a53** (v9.1 image
  2026.10.20.1656, container logs via fred-ops): the drop shim let the boot
  reach stage2's `as_hermes mkdir -p` seed block, which died
  `mkdir: cannot create directory '/opt/data': Permission denied` x14 — the
  auto-attached VOLUME at the declared `/opt/data` (Manifest attaches 20 GB
  at declared VOLUME paths) is UNWRITABLE even for container-root. The
  everclaw fleet's volumes (`/home/node/*`, uid-1000 workload) work on the
  same backend, so the attach is not universally writable.
- **v9.2: boot forensics (every boot, in the container log):** id, key-dir
  ls -ld, /proc/mounts extract, and a write-probe matrix across /opt/data,
  /opt, /tmp, /run, /root — retrievable via the fred-ops logs endpoint on
  any lease, dead or alive.
- **v9.2: HERMES_HOME writability chain:** when `$HERMES_HOME` is unset, try
  /opt/data, /opt/hermes-data, /tmp/hermes-data, /run/hermes-data — first
  writable wins (mkdir + touch probe), exported BEFORE cont-init so every
  consumer (upstream stage2, our cont-init, all service spawns) follows
  it. Relocation logs loudly. No writable candidate = FATAL 115. Tradeoff:
  a relocated HOME does not ride the backend volume — buffer containers
  are disposable by design; the forensics lines make it diagnosable.
- **Service spawns follow `$HERMES_HOME`** (cwd + HOME) instead of the
  hard-coded /opt/data; the dashboard adds `--skip-build` (serve the dist
  baked into the image — never npm-rebuild the web UI at container boot:
  deterministic, faster, and immune to unwritable install trees).
- **smoke: the main run now stacks the FULL Fred-parity gauntlet:**
  `--read-only` rootfs + a read-only tmpfs MOUNTED AT `/opt/data` (models
  the unwritable attach) + `--tmpfs /run:rw,noexec` + the cap drops. v9.2
  must boot every service through that stack; stricter than Fred (if it
  passes here, it passes there).

## 2026.10.20 (v9 — degraded-root mode: Fred denies the hermes privilege drop)

### Fixed
- **SECOND Fred sandbox restriction found via lease 01a159c1** (v8 image
  2026.10.20.1417, container logs pulled with fred-ops): after the noexec-/run
  fix, v8 still died at bootstrap — upstream stage2-hook.sh hard-requires the
  privilege drop to the hermes user (`as_hermes()` under `set -eu`), and the
  backend EPERM's the uid/gid syscalls: `s6-applyuidgid: fatal: unable to set
  supplementary group list: Operation not permitted`, plus
  `[stage2] Warning: chown /opt/data failed (rootless container?)` (chown to
  uid 10000 denied the same way). The everclaw/IOC fleet never hits this —
  those containers run as root.
- **v9: drop-capability probe + baked no-op drop shim.** The entrypoint probes
  `s6-setuidgid hermes /bin/true` once at boot. When it works: normal mode,
  upstream contract preserved (services as hermes). When the backend denies
  it: DEGRADED-ROOT mode — the entrypoint prepends
  `/usr/local/lib/installhermes/shims` (baked at build time, mode 755 — no
  runtime chmod/chown, which the backend also denies) to PATH; `shims/
  s6-setuidgid` shifts the user argument and execs the command as-is, so
  upstream cont-init completes and ALL services run as root — the same
  posture as the everclaw/IOC fleet on the same backend (container isolation
  is the security boundary there).
- **cont-init 02: sed-free, chmod-free .env merge.** GNU `sed -i` and bare
  `chmod` perform ownership syscalls the backend EPERM's; the merge is now a
  pure read/printf/mv rewrite with `umask 077` (0600 from creation), and the
  chown/chmod re-asserts are fail-soft. config.yaml/SOUL.md chowns likewise.
- **smoke: the drops-denied gate is `--cap-drop=SETUID,SETGID,CHOWN`** on
  the MAIN smoke container (alongside `--tmpfs /run:rw,noexec` — a real
  lease faces both restrictions simultaneously). Cap drops reproduce Fred's
  exact observed symptoms: setgid()/setuid() to the hermes uid/gid EPERM
  even as root, chown-to-other EPERM, while runc's own container init is
  unaffected (USER-root containers need no uid syscalls; setgroups(∅) is
  cap-free). v8 must FAIL this gate (dies at stage2); v9's degraded-root
  mode must PASS.
- **seccomp was abandoned for the drops gate** (documented dead end):
  adding ERRNO rules for the uid-family conflicts with the profile's
  existing allow rules and runc silently drops them (run 39442666681 — gate
  vacuous), while REMOVING them from the allow rules breaks docker 28.0.4
  itself: every `docker run -p` with the modified profile dies at the
  daemon netns sandbox ("bind-mount /proc/<pid>/ns/net ->
  /var/run/docker/netns/<id>: no such file or directory" — 6 runs,
  restart-proof, ubuntu-24.04 AND 22.04). A same-fleet control dispatch
  WITHOUT the modified profile passed (run 39449661371 on a temp branch
  from 507a53f) — the profile content was the trigger. The v1 profile is
  restored and stays on the informational probe steps only (it has run
  clean all day).
- **smoke: docker daemon self-heal step** (restart + `docker info`) before
  any container run — kept as cheap insurance against runner-daemon state
  flakes.

## 2026.10.20 (v8 — no-s6 entrypoint: the Fred /run exec fix)

### Fixed
- **ROOT CAUSE of all 5 rejected Fred leases** (Manifest container logs,
  2026-10-20): s6-overlay v3 generates its init INTO `/run/s6/basedir/bin/init`
  at boot (`s6-linux-init-maker`) and execs it from there; Fred's tenant
  sandbox denies exec of files under `/run`. Every lease died identically in
  <10s: `stage0: 83: exec: /run/s6/basedir/bin/init: Permission denied`,
  exit 126 — both backends (docker-10, docker-13), images 2026.10.20.050 →
  .339. Plain Docker, `docker run --init`, and a faithful tenant-seccomp
  profile all boot the same image fine (seccomp cannot filter by path; the
  denial is mount/LSM level), which is why every v2–v7 probe passed while
  Fred rejected. PROVEN in CI: `--tmpfs /run:rw,noexec` on the v7 image
  reproduces the exact Fred signature (same error line, ExitCode=126).
- **v8: our own PID 1 entrypoint replaces s6 entirely.** `entrypoint.sh`
  (installed at `/usr/local/bin/installhermes-entrypoint`, image layer —
  nothing ever executes from `/run`): runs the cont-init scripts
  (01-hermes-setup MUST-succeed, ours MUST-succeed, 02-reconcile-profiles
  best-effort — nothing to reconcile without an s6 runtime), loads
  `/run/s6/container_environment` as env (the with-contenv equivalent),
  starts auth-proxy / dashboard / cig-adapter with the same privilege drops
  (s6-setuidgid from the IMAGE LAYER at /command) and the same upstream
  dashboard contract (HOME=/opt/data, cwd /opt/data, loopback bind,
  --no-open), hard-asserts the dashboard invariants (always on, always
  loopback — a manifest value can never override), and supervises with
  per-service restart backoff (2→64s, reset after 300s stable uptime) +
  clean SIGTERM/SIGINT shutdown. `ENTRYPOINT` replaces the base image's
  s6 entrypoint; no CMD (the supervisor IS the container's lifetime).
  main-hermes (upstream no-op sleep) and the messaging gateway (exits with
  no channels; api_server :8642 therefore not listening) are not started;
  the dashboard provides the product chat surface.
- **cont-init 02: MERGE .env instead of clobbering** — upstream
  01-hermes-setup seeds .env (incl. generated API_SERVER_KEY) first; v7's
  `cat > .env` destroyed those seeds. Only OPENAI_BASE_URL /
  OPENAI_API_KEY are replaced/appended now. config.yaml + SOUL.md are
  written with hermes ownership (the user/agent edits them at runtime).
- **smoke: api_server assertion fixed (was vacuous)** — the `|| echo fail`
  fallback concatenated curl's `000` with `fail` producing `000fail`, which
  matched neither failure branch, so it "passed" while nothing listened.
  Now captured correctly; v8 expects :8642 NOT listening (no gateway
  process) — a future gateway enable must update the assertion deliberately.
- **smoke: `--tmpfs /run:rw,noexec` Fred-parity gate on the main smoke
  run** — any image that executes from /run fails CI. v7 fails it
  (verified 2026-10-20, run 39436321478: ExitCode=126, same stage0 error
  as Fred); v8 must pass it. This gate is permanent.

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

## 2026.10.21 (v9.2.2 — login page brand cleanup)

### Fixed
- **Login page title was static "OpenClaw — Sign In"** (login.html:6): the serve-time
  template replacement already handles `__BRAND_NAME__` (server.mjs loadLoginPage),
  but the <title> tag was hardcoded OpenClaw. Now `__BRAND_NAME__ — Sign In`
  → serves "Hermes — Sign In" for the Hermes vertical.
- **Footer attribution "Powered by OpenClaw & Privy"** (login.html:151) →
  "Powered by Privy". OpenClaw strings removed from all user-visible surfaces
  (title, footer). The generic "Your agent. Your inference. Your data." footer
  line is vertical-neutral and stays.

## 2026.10.21 (v9.2.3 — Privy modal logo + brand strings)

### Fixed
- **Privy login modal showed the OpenClaw wordmark** (auth-proxy/assets/logo.png,
  the inherited everclaw 500x110 logo, wired via login-app.jsx appearance.logo
  → /auth/logo.png). Replaced with the Hermes lockup: indigo→violet rounded
  icon + white "Hermes" wordmark (transparent, dark-theme modal safe).
- brandName default 'OpenClaw' → 'Hermes' (server.mjs:82); manifest always
  supplies BRAND_NAME=Hermes, but the fallback must not leak the old brand.
- "Bad Gateway — OpenClaw may still be starting" → brand-aware string.

## 2026.10.21 (v9.2.4 — dashboard Host fix)

### Fixed
- **"Invalid Host header. Dashboard requests must use the bound hostname or the
  configured public hostname"** (400 JSON) on every authenticated page after a
  dashboard restart: the auth-proxy forwarded the browser's Host (the lease
  FQDN) to the hermes dashboard, whose host_header_middleware (DNS-rebinding
  guard) only accepts its bound host or dashboard.public_url. We deliberately
  never set public_url — a non-loopback public hostname engages the dashboard's
  own ticket gate and would lock out the Privy auth-proxy front door.
  Fix: `changeOrigin: true` on the reverse proxy — every proxied request (and
  WS upgrade) presents Host: 127.0.0.1:<port> (the bound host). Deterministic
  acceptance across dashboard restarts; client identity still travels in the
  X-Forwarded-* headers (xfwd: true).

## 2026.10.21 (v9.2.5 — the actual page-path Host fix)

### Fixed
- **v9.2.4 patched the wrong proxy instance.** The module-level
  `httpProxy.createProxyServer` (now with changeOrigin) only serves WebSocket
  upgrades (`proxy.ws`). ALL authenticated HTTP page requests flow through the
  per-attempt proxy created inside `proxyWithBootRetry` — which still forwarded
  the browser's Host (the lease FQDN) and kept 400ing with "Invalid Host
  header" after the dashboard's host_header_middleware check. This change adds
  `changeOrigin: true` to the per-attempt instance: every page request now
  presents Host: 127.0.0.1:<port> (the dashboard's bound host).

## 2026.10.21 (v9.3.0 — CIG model re-assertion)

### Fixed
- **Chat unavailable after onboarding: Main Model reset to Anthropic/Claude-Opus-4.6
  (upstream default, keyless in the hosted container).** The hermes onboarding/
  dashboard rewrites config.yaml after first use and drops our marker, so the
  pre-v9.3.0 "never clobber user edits" rule preserved the broken model on
  every rebuild. The model is infrastructure-owned (CIG-only inference):
  cont-init now surgically re-asserts the TOP-LEVEL `model:` line on EVERY
  boot (sed-free read/printf/mv per v9 Fred restrictions), preserving all
  other user config.
- **Fresh configs now use the runtime's canonical schema** — top-level
  `model: "<id>"` string (v0.22.2 DEFAULT_CONFIG), not the legacy nested
  `model: {default: ...}` form the pre-v9.3.0 script wrote.
- Model id: deepseek-v4-flash-0731 (CIG allowlist bare name, from
  EVERCLAW_DEFAULT_MODEL). Verified by local harness: top-level line replaced,
  nested aux-block `model:` keys and personality preserved; appended when absent.
