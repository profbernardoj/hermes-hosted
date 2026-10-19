#!/usr/bin/env node
/**
 * cig-adapter — loopback OpenAI-compatible shim for hosted Hermes Agents.
 *
 * InstallHermes.ai (2026-10-20, SOP-001 Stage 2).
 *
 * WHY: hermes-agent speaks to any OpenAI-compatible endpoint via
 * OPENAI_BASE_URL + OPENAI_API_KEY. Our CIG (cig-inference Edge Function)
 * requires a SHORT-LIVED HS256 token minted with the container's
 * binding_secret — a static provider key cannot satisfy that. This shim
 * bridges the two: it presents a static local key to hermes, and mints /
 * refreshes CIG tokens on the fly (service mode: binding_secret only,
 * identity resolved from the deployment row — same trust model the
 * everclaw auth-proxy uses for CIG).
 *
 * SECURITY:
 *   - Binds 127.0.0.1 ONLY. Never reachable from outside the container.
 *   - Requires Bearer <CIG_ADAPTER_KEY> (static, container-local, from env).
 *   - Never sees or stores the Morpheus master key (it lives server-side
 *     in cig-inference only).
 *   - FQDN for minting: CIG_CONTAINER_FQDN env when set (provision-time),
 *     otherwise mint in binding-secret-only mode (mint-cig-token Path B,
 *     which also works during cold start).
 *
 * Endpoints:
 *   GET  /v1/models            — passes through to CIG (hermes model list)
 *   POST /v1/chat/completions  — forwards to CIG with a fresh token
 *   GET  /healthz              — adapter liveness (no auth)
 */

import http from 'node:http';

const PORT = parseInt(process.env.CIG_ADAPTER_PORT || '18900', 10);
const HOST = '127.0.0.1'; // loopback ONLY
const ADAPTER_KEY = process.env.CIG_ADAPTER_KEY || '';
const CIG_MINT_URL = process.env.CIG_MINT_URL || '';
const CIG_INFERENCE_URL = process.env.CIG_INFERENCE_URL || '';
const BINDING_SECRET = process.env.CIG_BINDING_SECRET || '';
const CONTAINER_FQDN = (process.env.CIG_CONTAINER_FQDN || '').trim();

if (!ADAPTER_KEY || !CIG_MINT_URL || !CIG_INFERENCE_URL || !BINDING_SECRET) {
  console.error('[cig-adapter] missing required env: CIG_ADAPTER_KEY, CIG_MINT_URL, CIG_INFERENCE_URL, CIG_BINDING_SECRET');
  process.exit(1);
}

// --- Token cache (minted token, refreshed ~60s before expiry) ---
let cachedToken = null;
let cachedTokenExp = 0; // epoch ms
const TOKEN_REFRESH_MARGIN_MS = 60_000;

async function mintCigToken() {
  const body = { binding_secret: BINDING_SECRET };
  if (CONTAINER_FQDN) body.fqdn = CONTAINER_FQDN;
  const resp = await fetch(CIG_MINT_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
  if (!resp.ok) {
    const text = await resp.text().catch(() => '');
    throw new Error(`mint-cig-token ${resp.status}: ${text.slice(0, 300)}`);
  }
  const data = await resp.json();
  if (!data.token) throw new Error('mint-cig-token returned no token');
  const ttlSec = Number(data.expires_in || 600);
  cachedToken = data.token;
  cachedTokenExp = Date.now() + Math.max(0, ttlSec - 60) * 1000;
  return cachedToken;
}

async function getCigToken() {
  if (cachedToken && Date.now() < cachedTokenExp - TOKEN_REFRESH_MARGIN_MS) {
    return cachedToken;
  }
  return mintCigToken();
}

function authorized(req) {
  const auth = req.headers['authorization'] || '';
  const parts = auth.split(' ');
  return parts.length === 2 && parts[0].toLowerCase() === 'bearer' &&
    parts[1] === ADAPTER_KEY;
}

async function forward(req, res, path) {
  // Read the full request body (hermes may stream-write it, but upstream
  // CIG is force-non-streaming anyway; we pass stream through untouched and
  // let cig-inference handle SSE re-emission).
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);

  let token;
  try {
    token = await getCigToken();
  } catch (err) {
    console.error('[cig-adapter] token mint failed:', err.message);
    res.writeHead(503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      error: { message: 'inference_auth_unavailable', type: 'server_error' },
    }));
    return;
  }

  const upstream = new URL(path, CIG_INFERENCE_URL.replace(/\/$/, '') + '/');
  const headers = {
    'Content-Type': req.headers['content-type'] || 'application/json',
    Authorization: `Bearer ${token}`,
  };
  // Forward Accept so streaming requests keep their SSE semantics end-to-end.
  if (req.headers['accept']) headers['Accept'] = req.headers['accept'];

  try {
    const upstreamResp = await fetch(upstream, {
      method: req.method,
      headers,
      body: req.method === 'GET' || req.method === 'HEAD' ? undefined : body,
    });
    res.writeHead(upstreamResp.status, {
      'Content-Type': upstreamResp.headers.get('content-type') || 'application/json',
      ...(upstreamResp.headers.get('content-type')?.includes('text/event-stream')
        ? { 'Cache-Control': 'no-cache', Connection: 'keep-alive' }
        : {}),
    });
    if (upstreamResp.body) {
      const reader = upstreamResp.body.getReader();
      const pump = () =>
        reader.read().then(({ done, value }) => {
          if (done) { res.end(); return; }
          res.write(value);
          pump();
        });
      pump().catch((err) => {
        console.error('[cig-adapter] stream error:', err.message);
        res.end();
      });
    } else {
      res.end();
    }
  } catch (err) {
    console.error('[cig-adapter] upstream error:', err.message);
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
    }
    res.end(JSON.stringify({
      error: { message: 'inference_upstream_error', type: 'server_error' },
    }));
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${HOST}:${PORT}`);

  if (url.pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, fqdn: CONTAINER_FQDN || 'auto' }));
    return;
  }

  if (!authorized(req)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      error: { message: 'invalid adapter key', type: 'authentication_error' },
    }));
    return;
  }

  if (url.pathname === '/v1/models' && req.method === 'GET') {
    await forward(req, res, 'v1/models');
    return;
  }
  if (url.pathname === '/v1/chat/completions' && req.method === 'POST') {
    await forward(req, res, 'v1/chat/completions');
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    error: { message: `not found: ${url.pathname}`, type: 'invalid_request_error' },
  }));
});

server.listen(PORT, HOST, () => {
  console.log(`[cig-adapter] listening on ${HOST}:${PORT} (CIG: ${CIG_INFERENCE_URL})`);
});
