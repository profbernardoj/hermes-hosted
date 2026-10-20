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
set_kv() { # $1=file $2=key $3=value — replace the existing line or append
  if grep -q "^$2=" "$1" 2>/dev/null; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >> "$1"
  fi
}

if [ ! -f "$ENV_FILE" ]; then
  # .env should already exist (01-hermes-setup creates it as hermes, 0600);
  # if it somehow does not, create it under a restrictive umask as hermes so
  # there is no root-owned window (upstream OOF-285 pattern).
  as_hermes sh -c "umask 077 && touch '$ENV_FILE'"
fi
set_kv "$ENV_FILE" OPENAI_BASE_URL "http://127.0.0.1:${CIG_ADAPTER_PORT:-18900}/v1"
set_kv "$ENV_FILE" OPENAI_API_KEY "${CIG_ADAPTER_KEY}"
# Keep the marker comment at the top (once).
if ! grep -q "Managed by hermes-hosted" "$ENV_FILE"; then
  sed -i '1i # Managed by hermes-hosted (installhermes.ai) — regenerated at boot.' "$ENV_FILE"
fi
# .env must stay hermes-owned and private (our sed/appends may run as root).
chown hermes:hermes "$ENV_FILE" 2>/dev/null || true
chmod 600 "$ENV_FILE"

# --- config.yaml: model default + persona basics ---
# Only written when absent or previously written by us (never clobber user edits
# on a restored volume). Written AS hermes: the user may edit it at runtime.
if [ ! -f "$CONFIG_FILE" ] || grep -q "Managed by hermes-hosted" "$CONFIG_FILE"; then
cat > "$CONFIG_FILE" <<EOF
# Managed by hermes-hosted (installhermes.ai) — regenerated at boot.
model:
  default: ${DEFAULT_MODEL}

personality:
  name: ${AGENT_NAME}
EOF
  chown hermes:hermes "$CONFIG_FILE" 2>/dev/null || true
else
  echo "[installhermes] $CONFIG_FILE exists (user-managed) — leaving untouched"
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
