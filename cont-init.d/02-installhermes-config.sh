#!/bin/sh
# /etc/cont-init.d/02-installhermes-config.sh — headless hermes configuration.
#
# Runs at container boot — in v7 by s6 cont-init, in v8 by the installhermes
# entrypoint supervisor (still BEFORE any service starts, still as root).
# Writes the hermes data config from container env — NO interactive setup.
#
# v8 changes vs v7:
#   - MERGE .env instead of clobbering it: upstream 01-hermes-setup seeds
#     $HERMES_HOME/.env (incl. the generated API_SERVER_KEY) BEFORE this
#     script runs; v7's `cat > .env` destroyed those seeds. Only the keys we
#     own (OPENAI_BASE_URL, OPENAI_API_KEY) are replaced/appended now.
#   - Data files are written with hermes OWNERSHIP: config.yaml and SOUL.md
#     are user-editable at runtime (the agent evolves SOUL.md), so they must
#     be writable by the hermes user, not root.
#   - The /run/s6/container_environment writes stay: the v8 entrypoint reads
#     that dir as its with-contenv equivalent.
#
# Container env contract (set by provision-buffer / deploy-agent manifests):
#   CIG_MINT_URL            — Supabase mint-cig-token endpoint
#   CIG_INFERENCE_URL       — Supabase cig-inference endpoint
#   CIG_BINDING_SECRET      — per-container 32-byte hex (deployment credential)
#   CIG_CONTAINER_FQDN      — this lease's FQDN (empty on cold deploy)
#   CIG_ADAPTER_KEY         — static local key for the loopback cig-adapter
#   EVERCLAW_DEFAULT_MODEL  — default model id (IOC roster, e.g. deepseek-v4-flash-0731)
#   AGENT_NAME              — user-chosen agent name (name-your-agent flow)
#   PRIVY_APP_ID / PRIVY_VERIFICATION_KEY — Hermes vertical Privy app
#   VERIFY_OWNER_URL / VERIFY_OWNER_SECRET — dynamic ownership
#   BRAND_NAME / BRAND_ICON / BRAND_TAGLINE — login page skin
#
# HERMES_HOME in the official image is /opt/data (the state volume).

set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
ENV_FILE="$HERMES_HOME/.env"
CONFIG_FILE="$HERMES_HOME/config.yaml"

DEFAULT_MODEL="${EVERCLAW_DEFAULT_MODEL:-deepseek-v4-flash-0731}"
AGENT_NAME="${AGENT_NAME:-Hermes}"

# s6-setuidgid lives in the image layer (/command) — running it is fine under
# Fred's sandbox; only EXECUTING files from /run is denied.
SETUIDGID="$(command -v s6-setuidgid || echo /command/s6-setuidgid)"

as_hermes() {
  if [ "$(id -u)" = 0 ]; then
    "$SETUIDGID" hermes "$@"
  else
    "$@"
  fi
}

echo "[installhermes] writing headless hermes config to $HERMES_HOME"

mkdir -p "$HERMES_HOME"

# --- .env: provider = custom OpenAI-compatible endpoint (the loopback adapter) ---
# MERGE, never clobber: upstream 01-hermes-setup seeds .env first (defaults +
# generated API_SERVER_KEY); we own exactly two keys. OPENAI_API_KEY is
# origin-bound by hermes (sent only to the adapter's origin) and is a
# container-local static key — never a real provider key.
#
# v9 (Fred's sandbox): the rewrite is sed-free and chmod-free — GNU sed -i
# and bare chmod do ownership syscalls the backend EPERM's (lease 01a159c1:
# chown + setgroups both denied), and set -e here would abort the boot.
# Pure read/printf/mv with `umask 077` so the rewritten file is 0600 from
# creation; the chown/chmod re-asserts below are tolerated (no-ops fail soft
# in degraded-root mode where everything runs as root anyway).
BASE_URL="http://127.0.0.1:${CIG_ADAPTER_PORT:-18900}/v1"
ADAPTER_KEY="${CIG_ADAPTER_KEY:-}"
ENV_TMP="${ENV_FILE}.v9tmp.$$"
SEEN_URL=0
SEEN_KEY=0
( umask 077
  if [ ! -f "$ENV_FILE" ] || ! grep -q "^# Managed by hermes-hosted" "$ENV_FILE" 2>/dev/null; then
    printf '# Managed by hermes-hosted (installhermes.ai) — regenerated at boot.\n'
  fi
  if [ -f "$ENV_FILE" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
      case "$_line" in
        OPENAI_BASE_URL=*) printf 'OPENAI_BASE_URL=%s\n' "$BASE_URL"; SEEN_URL=1 ;;
        OPENAI_API_KEY=*)  printf 'OPENAI_API_KEY=%s\n' "$ADAPTER_KEY"; SEEN_KEY=1 ;;
        *) printf '%s\n' "$_line" ;;
      esac
    done < "$ENV_FILE"
  fi
  [ "$SEEN_URL" = 1 ] || printf 'OPENAI_BASE_URL=%s\n' "$BASE_URL"
  [ "$SEEN_KEY" = 1 ] || printf 'OPENAI_API_KEY=%s\n' "$ADAPTER_KEY"
) > "$ENV_TMP" && mv "$ENV_TMP" "$ENV_FILE"
# Ownership re-asserts (tolerated: EPERM on degraded backends — everything is
# root there; on drop-capable backends these restore hermes ownership).
chown hermes:hermes "$ENV_FILE" 2>/dev/null || true
chmod 600 "$ENV_FILE" 2>/dev/null || true

# --- config.yaml: model default + persona basics (v9.3.0) ---
# TWO rules:
# (1) Fresh/marker configs are written in the runtime's CANONICAL schema:
#     top-level `model: "<id>"` string (v0.22.2 DEFAULT_CONFIG keys are
#     `model` string + `providers` dict), NOT the legacy nested
#     `model: {default: ...}` form the pre-v9.3.0 script wrote.
# (2) USER-MANAGED configs (the hermes onboarding/dashboard rewrites the
#     file after first use and drops our marker): surgically re-assert the
#     TOP-LEVEL model line on EVERY boot. The hosted product's inference is
#     CIG-only — an onboarding-set Main Model pointing at a keyless provider
#     (e.g. anthropic/claude-*) leaves chat unavailable. The model is
#     infrastructure-owned; every other user edit is preserved untouched.
#     Sed-free read/printf/mv per v9 Fred restrictions (no GNU sed -i, no
#     bare chmod — ownership syscalls EPERM).
if [ ! -f "$CONFIG_FILE" ] || grep -q "Managed by hermes-hosted" "$CONFIG_FILE"; then
cat > "$CONFIG_FILE" <<EOF
# Managed by hermes-hosted (installhermes.ai) — regenerated at boot.
model: ${DEFAULT_MODEL}

personality:
  name: ${AGENT_NAME}
EOF
  chown hermes:hermes "$CONFIG_FILE" 2>/dev/null || true
else
  echo "[installhermes] $CONFIG_FILE exists (user-managed) — re-asserting model=${DEFAULT_MODEL} (v9.3.0)"
  _MODEL_TMP="${CONFIG_FILE}.v930tmp.$$"
  ( umask 077
    _SEEN_MODEL=0
    while IFS= read -r _line || [ -n "$_line" ]; do
      case "$_line" in
        "model:"|"model: "*) printf 'model: %s\n' "$DEFAULT_MODEL"; _SEEN_MODEL=1 ;;
        *) printf '%s\n' "$_line" ;;
      esac
    done < "$CONFIG_FILE"
    [ "$_SEEN_MODEL" = 1 ] || printf 'model: %s\n' "$DEFAULT_MODEL"
  ) > "$_MODEL_TMP" && mv "$_MODEL_TMP" "$CONFIG_FILE"
  chown hermes:hermes "$CONFIG_FILE" 2>/dev/null || true
fi

# --- SOUL.md persona (only when absent — user may evolve it later) ---
if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
cat > "$HERMES_HOME/SOUL.md" <<EOF
# ${AGENT_NAME}

You are ${AGENT_NAME} — the user's personal Hermes Agent, hosted on sovereign
infrastructure. Your inference runs on the Morpheus network; the user owns it.

- Be direct and useful. Ship first, explain after.
- Be honest. Never fabricate.
- Keep the user's data private. It never leaves this container unless the user asks.
EOF
  chown hermes:hermes "$HERMES_HOME/SOUL.md" 2>/dev/null || true
fi

# --- Dashboard: ALWAYS on, ALWAYS loopback (the auth-proxy is the only ingress) ---
# Upstream's dashboard service defaults to HERMES_DASHBOARD_HOST=0.0.0.0;
# a non-loopback bind engages the dashboard's OWN auth gate (basic auth /
# Nous OAuth), which we do NOT use — our Privy auth-proxy fronts :18789 and
# reaches the dashboard on 127.0.0.1:9119. Without these writes the dashboard
# refuses to start (fail-closed, "Refusing to bind dashboard to 0.0.0.0") and
# crash-loops (v5 smoke log).
#
# The v8 entrypoint reads this dir as its with-contenv equivalent, and the
# entrypoint HARD-ASSERTS the same invariants after loading it — a manifest
# value can never turn the dashboard off or bind it non-loopback.
# Idempotent per boot.
mkdir -p /run/s6/container_environment
printf '1' > /run/s6/container_environment/HERMES_DASHBOARD
printf '127.0.0.1' > /run/s6/container_environment/HERMES_DASHBOARD_HOST
printf '9119' > /run/s6/container_environment/HERMES_DASHBOARD_PORT

echo "[installhermes] config written (model=${DEFAULT_MODEL}, agent=${AGENT_NAME})"
