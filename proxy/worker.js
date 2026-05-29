/**
 * PhotoDeduper AI Proxy — Cloudflare Worker
 *
 * Sits between the macOS app and OpenAI. The real API key never reaches
 * the device. The Worker:
 *   1. Verifies the request came from the app (HMAC-SHA256 signature)
 *   2. Rate-limits per IP (KV-backed, eventually consistent)
 *   3. Reconstructs the outbound body from scratch — model and max_tokens
 *      are HARDCODED here; the client cannot override them
 *   4. Forwards to OpenAI and streams the response back
 *
 * Secrets (set with `wrangler secret put`, never committed):
 *   OPENAI_API_KEY   — your OpenAI key
 *   APP_HMAC_SECRET  — 64-char lowercase hex (32 raw bytes) shared with the app
 *
 * KV namespace binding: RATE_LIMIT_KV
 */

// ── Constants ────────────────────────────────────────────────────────────────

const MODEL       = "gpt-4.1-mini";
const MAX_TOKENS  = 300;
const MAX_BODY    = 8 * 1024 * 1024;   // 8 MB hard cap
const TS_WINDOW   = 300;               // ±5 minutes clock skew tolerance
const RATE_HOUR   = 200;               // max requests / IP / hour
const RATE_DAY    = 1000;              // max requests / IP / day
const MAX_IMAGES  = 6;                 // max image_url items forwarded to OpenAI
const MAX_TEXTS   = 1;                 // max text items (prompt) forwarded to OpenAI

// ── Entry point ──────────────────────────────────────────────────────────────

export default {
  async fetch(request, env) {
    // Step 1 — Method + Content-Type gate
    if (request.method !== "POST") {
      return jsonError(405, "Method not allowed");
    }
    const ct = request.headers.get("Content-Type") || "";
    if (!ct.includes("application/json")) {
      return jsonError(400, "Content-Type must be application/json");
    }

    // Step 2 — Body size cap
    const bodyBuffer = await request.arrayBuffer().catch(() => null);
    if (!bodyBuffer) return jsonError(400, "Could not read request body");
    if (bodyBuffer.byteLength > MAX_BODY) return jsonError(413, "Request too large");

    // Step 3 — Timestamp freshness
    const tsHeader = request.headers.get("X-Timestamp");
    if (!tsHeader || !/^\d+$/.test(tsHeader)) {
      return jsonError(400, "Missing or invalid X-Timestamp header");
    }
    const tsInt = parseInt(tsHeader, 10);
    const nowSec = Math.floor(Date.now() / 1000);
    if (Math.abs(nowSec - tsInt) > TS_WINDOW) {
      return jsonError(401, "Timestamp out of window");
    }

    // Step 4 — HMAC-SHA256 verification
    const sigHeader = request.headers.get("X-Signature");
    if (!sigHeader) return jsonError(401, "Missing X-Signature header");

    const secretHex = env.APP_HMAC_SECRET;
    if (!secretHex) return jsonError(500, "Proxy misconfigured");

    const secretBytes = hexToBytes(secretHex);
    const hmacKey = await crypto.subtle.importKey(
      "raw", secretBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
    );

    // signed string = timestamp + "." + lowercase_hex(SHA-256(body))
    const bodyHashBuf = await crypto.subtle.digest("SHA-256", bodyBuffer);
    const bodyHex = bufToHex(bodyHashBuf);
    const signedStr = new TextEncoder().encode(tsHeader + "." + bodyHex);
    const macBuf = await crypto.subtle.sign("HMAC", hmacKey, signedStr);
    const expectedSig = bufToHex(macBuf);

    if (!timingSafeEqual(expectedSig, sigHeader.toLowerCase())) {
      return jsonError(401, "Invalid signature");
    }

    // Step 5 — One-time-use (replay) protection
    // The verified signature is bound to (timestamp, body), so a captured tuple
    // can otherwise be replayed for up to TS_WINDOW. Record each accepted
    // signature in KV with a TTL of TS_WINDOW; once a signature is seen again
    // we reject it. The key auto-expires precisely when the timestamp can no
    // longer pass the freshness window above, so this needs no manual cleanup.
    // Caveat: KV is eventually consistent — a near-simultaneous replay hitting a
    // different edge PoP before the put propagates may still slip through, but
    // this closes the common (single-PoP, sequential) replay window.
    const nonceKey = `nonce:${expectedSig}`;
    if (await env.RATE_LIMIT_KV.get(nonceKey)) {
      return jsonError(401, "Replay detected");
    }
    // Awaited (not fire-and-forget) since it precedes the slow OpenAI fetch and
    // we want the nonce durably recorded before forwarding upstream.
    await env.RATE_LIMIT_KV.put(nonceKey, "1", { expirationTtl: TS_WINDOW });

    // Step 6 — Rate limiting via KV
    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    const hourEpoch = Math.floor(Date.now() / 3_600_000);
    const dayStr = new Date().toISOString().slice(0, 10);
    const hourKey = `rl:${ip}:${hourEpoch}`;
    const dayKey  = `rl:${ip}:day:${dayStr}`;

    const [hourCount, dayCount] = await Promise.all([
      env.RATE_LIMIT_KV.get(hourKey).then(v => parseInt(v || "0", 10)),
      env.RATE_LIMIT_KV.get(dayKey).then(v => parseInt(v || "0", 10)),
    ]);

    if (hourCount >= RATE_HOUR) return jsonRateLimit("hour");
    if (dayCount  >= RATE_DAY)  return jsonRateLimit("day");

    // Increment both counters (fire-and-forget; eventual consistency is acceptable)
    env.RATE_LIMIT_KV.put(hourKey, String(hourCount + 1), { expirationTtl: 3600 });
    env.RATE_LIMIT_KV.put(dayKey,  String(dayCount  + 1), { expirationTtl: 86400 });

    // Step 7 — Parse and sanitize body (NEVER forward client body directly)
    let parsed;
    try {
      parsed = JSON.parse(new TextDecoder().decode(bodyBuffer));
    } catch {
      return jsonError(400, "Invalid JSON body");
    }

    const messages = parsed.messages;
    if (!Array.isArray(messages) || messages.length === 0) {
      return jsonError(400, "messages array is required");
    }

    // Take only the first user message
    const userMsg = messages.find(m => m.role === "user");
    if (!userMsg || !Array.isArray(userMsg.content)) {
      return jsonError(400, "No valid user message found");
    }

    // Whitelist image_url and text items; partition so the prompt is always
    // kept. Cap images (MAX_IMAGES) and texts (MAX_TEXTS) separately, then
    // keep order images-then-text so the prompt is never sliced off.
    const images = userMsg.content
      .filter(item => item.type === "image_url")
      .slice(0, MAX_IMAGES);
    const texts = userMsg.content
      .filter(item => item.type === "text")
      .slice(0, MAX_TEXTS);

    const sanitizedContent = [...images, ...texts]
      .map(item => {
        if (item.type === "text") {
          return { type: "text", text: String(item.text || "").slice(0, 4096) };
        }
        // image_url — keep only the url field, drop "detail" or anything else
        const url = item.image_url?.url;
        if (!url || typeof url !== "string") return null;
        return { type: "image_url", image_url: { url } };
      })
      .filter(Boolean);

    if (sanitizedContent.length === 0) {
      return jsonError(400, "No valid content items after sanitization");
    }

    // Hardcoded outbound body — client cannot override model or max_tokens
    const outboundBody = {
      model: MODEL,
      max_tokens: MAX_TOKENS,
      messages: [{ role: "user", content: sanitizedContent }],
    };

    // Step 8 — Forward to OpenAI
    const openaiKey = env.OPENAI_API_KEY;
    if (!openaiKey) return jsonError(500, "Proxy misconfigured");

    let openaiResp;
    try {
      openaiResp = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${openaiKey}`,
        },
        body: JSON.stringify(outboundBody),
      });
    } catch (e) {
      return jsonError(502, "Upstream request failed");
    }

    // Pass through OpenAI's status and body as-is
    const responseBody = await openaiResp.arrayBuffer();
    return new Response(responseBody, {
      status: openaiResp.status,
      headers: { "Content-Type": "application/json" },
    });
  },
};

// ── Helpers ──────────────────────────────────────────────────────────────────

function jsonError(status, message) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function jsonRateLimit(window) {
  return new Response(JSON.stringify({ error: "rate_limit", window }), {
    status: 429,
    headers: { "Content-Type": "application/json" },
  });
}

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function bufToHex(buf) {
  return Array.from(new Uint8Array(buf))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Constant-time string comparison to prevent timing attacks. */
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
