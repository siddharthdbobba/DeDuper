#!/usr/bin/env bash
# PhotoDeduper Proxy — one-time setup script
# Run this after `npx wrangler login`
set -euo pipefail

WRANGLER="npx wrangler"
TOML="wrangler.toml"
APPCONFIG="../../PhotoDeduper/App/AppConfig.swift"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  PhotoDeduper Proxy Setup"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Step 1: Check auth ────────────────────────────────────────────────────────
echo "▶ Checking Cloudflare authentication…"
if ! $WRANGLER whoami &>/dev/null; then
  echo ""
  echo "  ✗ Not logged in. Run: npx wrangler login"
  echo "    Then re-run this script."
  exit 1
fi
echo "  ✓ Authenticated"

# ── Step 2: Create KV namespaces ─────────────────────────────────────────────
echo ""
echo "▶ Creating KV namespaces for rate limiting…"

PROD_OUTPUT=$($WRANGLER kv namespace create RATE_LIMIT_KV 2>&1)
PROD_ID=$(echo "$PROD_OUTPUT" | grep -oE '"[0-9a-f]{32}"' | tr -d '"' | head -1)
if [ -z "$PROD_ID" ]; then
  # namespace may already exist — try to fetch it
  PROD_ID=$($WRANGLER kv namespace list 2>/dev/null | python3 -c "
import sys, json
ns = json.load(sys.stdin)
match = [n for n in ns if n.get('title','') == 'photodeduper-proxy-RATE_LIMIT_KV']
print(match[0]['id'] if match else '')
" 2>/dev/null || echo "")
fi

PREVIEW_OUTPUT=$($WRANGLER kv namespace create RATE_LIMIT_KV --preview 2>&1)
PREVIEW_ID=$(echo "$PREVIEW_OUTPUT" | grep -oE '"[0-9a-f]{32}"' | tr -d '"' | head -1)
if [ -z "$PREVIEW_ID" ]; then
  PREVIEW_ID=$($WRANGLER kv namespace list 2>/dev/null | python3 -c "
import sys, json
ns = json.load(sys.stdin)
match = [n for n in ns if n.get('title','') == 'photodeduper-proxy-RATE_LIMIT_KV_preview']
print(match[0]['id'] if match else '')
" 2>/dev/null || echo "")
fi

if [ -z "$PROD_ID" ] || [ -z "$PREVIEW_ID" ]; then
  echo "  ✗ Could not retrieve KV namespace IDs automatically."
  echo "    Run: npx wrangler kv namespace list"
  echo "    Then paste the IDs into wrangler.toml manually."
else
  echo "  ✓ Production KV ID: $PROD_ID"
  echo "  ✓ Preview    KV ID: $PREVIEW_ID"

  # Patch wrangler.toml in-place
  sed -i.bak \
    -e "s/REPLACE_WITH_PRODUCTION_KV_ID/$PROD_ID/" \
    -e "s/REPLACE_WITH_PREVIEW_KV_ID/$PREVIEW_ID/" \
    "$TOML"
  rm -f "${TOML}.bak"
  echo "  ✓ wrangler.toml updated"
fi

# ── Step 3: Set secrets ───────────────────────────────────────────────────────
echo ""
echo "▶ Setting Worker secrets…"
echo ""
echo "  You need two secrets. Enter them when prompted."
echo ""
echo "  1/2  OPENAI_API_KEY — your OpenAI API key (starts with sk-)"
$WRANGLER secret put OPENAI_API_KEY

echo ""
echo "  2/2  APP_HMAC_SECRET — the shared HMAC secret (64-char hex)"
echo "       Value: 03ea66656af9d5eae84b16c5293c14d7bcf43ed676b8c022bdd52ddbea821830"
$WRANGLER secret put APP_HMAC_SECRET

# ── Step 4: Deploy ────────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying Worker…"
DEPLOY_OUTPUT=$($WRANGLER deploy 2>&1)
echo "$DEPLOY_OUTPUT"

WORKER_URL=$(echo "$DEPLOY_OUTPUT" | grep -oE 'https://[a-z0-9._-]+\.workers\.dev' | head -1)

# ── Step 5: Patch AppConfig.swift with real URL ───────────────────────────────
if [ -n "$WORKER_URL" ] && [ -f "$APPCONFIG" ]; then
  echo ""
  echo "▶ Updating AppConfig.swift with deployed URL…"
  sed -i.bak \
    "s|https://photodeduper-proxy.YOUR_SUBDOMAIN.workers.dev/v1/chat/completions|${WORKER_URL}/v1/chat/completions|" \
    "$APPCONFIG"
  rm -f "${APPCONFIG}.bak"
  echo "  ✓ AppConfig.swift → ${WORKER_URL}/v1/chat/completions"
else
  echo ""
  echo "  ⚠ Could not auto-detect Worker URL. Update AppConfig.swift manually:"
  echo "    Replace YOUR_SUBDOMAIN with your Cloudflare account subdomain."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✓ Setup complete!"
if [ -n "$WORKER_URL" ]; then
  echo "  Worker URL: $WORKER_URL"
fi
echo ""
echo "  To test locally:  npx wrangler dev"
echo "  To redeploy:      npx wrangler deploy"
echo "═══════════════════════════════════════════════════════"
echo ""
