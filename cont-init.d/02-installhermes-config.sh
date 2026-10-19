#!/bin/sh
# /etc/cont-init.d/02-installhermes-config.sh — headless hermes configuration.
#
# Runs at container boot (s6 cont-init, before any service starts).
# Writes the hermes data config from container env — NO interactive setup.
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
CONFIG_DIR="$HERMES_HOME"
ENV_FILE="$HERMES_HOME/.env"
CONFIG_FILE="$HERMES_HOME/config.yaml"

DEFAULT_MODEL="${EVERCLAW_DEFAULT_MODEL:-deepseek-v4-flash-0731}"
AGENT_NAME="${AGENT_NAME:-Hermes}"

echo "[installhermes] writing headless hermes config to $HERMES_HOME"

mkdir -p "$CONFIG_DIR"

# --- .env: provider = custom OpenAI-compatible endpoint (the loopback adapter) ---
# OPENAI_API_KEY is origin-bound by hermes (sent only to the adapter's origin)
# and is a container-local static key — never a real provider key.
cat > "$ENV_FILE" <<EOF
# Managed by hermes-hosted (installhermes.ai) — do not edit; regenerated at boot.
OPENAI_BASE_URL=http://127.0.0.1:${CIG_ADAPTER_PORT:-18900}/v1
OPENAI_API_KEY=${CIG_ADAPTER_KEY}
EOF
chmod 600 "$ENV_FILE"

# --- config.yaml: model default + persona basics ---
# Only written when absent or previously written by us (never clobber user edits
# on a restored volume).
if [ ! -f "$CONFIG_FILE" ] || grep -q "Managed by hermes-hosted" "$CONFIG_FILE"; then
cat > "$CONFIG_FILE" <<EOF
# Managed by hermes-hosted (installhermes.ai) — regenerated at boot.
model:
  default: ${DEFAULT_MODEL}

personality:
  name: ${AGENT_NAME}
EOF
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
fi

# --- Dashboard: enable + bind loopback (the auth-proxy is the only ingress) ---
export HERMES_DASHBOARD=1
mkdir -p /run/installhermes
printf 'HERMES_DASHBOARD=1\n' > /run/installhermes/env

echo "[installhermes] config written (model=${DEFAULT_MODEL}, agent=${AGENT_NAME})"
