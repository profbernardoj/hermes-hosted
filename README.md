# hermes-hosted

**InstallHermes.ai container image** — the real [NousResearch hermes-agent](https://github.com/NousResearch/hermes-agent) (MIT), hosted on Manifest Network leases, fronted by our Privy auth-proxy, powered by Morpheus inference through the Central Inference Gateway (CIG).

Part of the InstallHermes vertical (see `memory/projects/installhermes/` in the private workspace; SOP-001 pipeline; David-approved plan v2, 2026-10-19).

## Architecture

```
Browser → https://<lease-fqdn>:443
   └─ auth-proxy (:18789, ingress)          [OURS — everclaw auth-proxy, unmodified]
        ├─ Privy JWT verify (Hermes app)
        ├─ dynamic ownership (verify-owner)
        ├─ SSO handoff (generate/consume-handoff-token)
        └─ proxies to 127.0.0.1:9119
              └─ hermes dashboard (FastAPI + React SPA, embedded Chat tab)
                   └─ hermes agent (full toolset, SOUL.md persona, skills, memory)

hermes LLM calls (outbound):
   └─ OPENAI_BASE_URL=http://127.0.0.1:18900/v1
        └─ cig-adapter (:18900, loopback ONLY)   [OURS]
             ├─ static local key (CIG_ADAPTER_KEY)
             ├─ mints short-lived CIG tokens (service mode: binding_secret)
             └─ forwards to cig-inference (Supabase) → Morpheus Gateway
                  (budgets enforced server-side; no Morpheus key in-container)
```

## Why an adapter?

hermes-agent speaks OpenAI-compatible endpoints natively (`OPENAI_BASE_URL` + `OPENAI_API_KEY`), but our CIG requires short-lived tokens minted per-container with `binding_secret`. The `cig-adapter` bridges the two without ever placing a Morpheus master key inside the container.

## Container environment contract

Set by `provision-buffer` / `deploy-agent` manifests (vertical `installhermes`):

| Env | Purpose |
|---|---|
| `CIG_MINT_URL`, `CIG_INFERENCE_URL` | Supabase endpoints (shared with IOC containers) |
| `CIG_BINDING_SECRET` | Per-container 32-byte hex deployment credential |
| `CIG_CONTAINER_FQDN` | Lease FQDN (empty on cold deploy → binding-secret-only mint) |
| `CIG_ADAPTER_KEY` | Static local key hermes uses against the loopback adapter |
| `EVERCLAW_DEFAULT_MODEL` | Default model (IOC roster, e.g. `deepseek-v4-flash-0731`) |
| `AGENT_NAME` | User-chosen agent name (name-your-agent flow) |
| `PRIVY_APP_ID`, `PRIVY_VERIFICATION_KEY` | Hermes vertical Privy app |
| `VERIFY_OWNER_URL`, `VERIFY_OWNER_SECRET` | Dynamic ownership |
| `BRAND_NAME`, `BRAND_ICON`, `BRAND_TAGLINE` | Login page skin (env-driven, no rebuild) |

## Build & release

- **GHCR only, amd64, via GitHub Actions** — never build locally (SOP-004).
- Base image pinned: `nousresearch/hermes-agent:v0.22.2` (stable 2026-10-15). Record the digest in release notes.
- CalVer tags: `YYYY.M.DD.HHMM` (UTC) + `:latest` on main.
- Image: `ghcr.io/profbernardoj/hermes-hosted:<tag>`

## Verification (before any buffer uses the image)

Staging matrix on a remote Manifest lease (SOP-004 §5.6): image pull time + disk fit on `docker-morpheus-small`, auth-proxy login page at FQDN, Privy login (Hermes app + `allowed_domains` wildcards), dashboard Chat tab E2E through cig-adapter → CIG → Morpheus, restart persistence, `--diagnose` equivalent health checks.

## License notes

- hermes-agent: MIT (third-party hosting permitted).
- Our layers: same terms as the everclaw stack.
- Positioning: "Your Hermes Agent, hosted — powered by Morpheus inference." No implied Nous affiliation.
