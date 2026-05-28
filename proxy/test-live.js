/**
 * Live integration test for the deployed PhotoDeduper proxy.
 *
 * Usage:
 *   node test-live.js <worker-url>
 *
 * Example:
 *   node test-live.js https://photodeduper-proxy.YOUR_SUBDOMAIN.workers.dev
 *
 * What it checks:
 *   1. Worker is reachable
 *   2. Missing signature  → 401
 *   3. Expired timestamp  → 401
 *   4. Bad signature      → 401
 *   5. Valid signed request with a tiny text payload → 200 from OpenAI
 *      (uses 0 image tokens — just confirms the full auth+proxy chain works)
 */

const crypto = require("crypto");

// ── Config ────────────────────────────────────────────────────────────────────

// The secret encoded in AppConfig.swift (xorKey XOR masked at runtime)
const XOR_KEY = [
  0x43, 0x25, 0x4D, 0x35, 0xF0, 0xD6, 0x95, 0x3C,
  0xDE, 0x4C, 0x73, 0x61, 0xF8, 0xD5, 0x17, 0x83,
  0x6C, 0xAB, 0x80, 0xCA, 0x18, 0x26, 0x94, 0xB1,
  0x05, 0x6C, 0xBC, 0x19, 0x02, 0x3D, 0xB7, 0xC1,
];
const MASKED = [
  0x40, 0xCF, 0x2B, 0x50, 0x9A, 0x2F, 0x40, 0xD6,
  0x36, 0x07, 0x65, 0xA4, 0xD1, 0xE9, 0x03, 0x54,
  0xD0, 0x5F, 0xBE, 0x1C, 0x6E, 0x9E, 0x54, 0x93,
  0xB8, 0xB9, 0x91, 0xC2, 0xE8, 0xBF, 0xAF, 0xF1,
];
const SECRET = Buffer.from(XOR_KEY.map((b, i) => b ^ MASKED[i]));

// ── Helpers ───────────────────────────────────────────────────────────────────

function sign(body, timestamp) {
  const bodyHex = crypto.createHash("sha256").update(body).digest("hex");
  const signedStr = `${timestamp}.${bodyHex}`;
  return crypto.createHmac("sha256", SECRET).update(signedStr, "utf8").digest("hex");
}

async function post(url, body, headers = {}) {
  const bodyStr = typeof body === "string" ? body : JSON.stringify(body);
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: bodyStr,
  });
  let text;
  try { text = await res.text(); } catch { text = "(empty)"; }
  return { status: res.status, text };
}

function pass(label) { console.log(`  ✓ ${label}`); }
function fail(label, detail) { console.error(`  ✗ ${label}\n    ${detail}`); process.exitCode = 1; }

// ── Main ──────────────────────────────────────────────────────────────────────

(async () => {
  const workerURL = process.argv[2];
  if (!workerURL) {
    console.error("Usage: node test-live.js <worker-url>");
    console.error("  e.g. node test-live.js https://photodeduper-proxy.YOUR_SUBDOMAIN.workers.dev");
    process.exit(1);
  }
  const endpoint = workerURL.replace(/\/$/, "") + "/v1/chat/completions";

  console.log(`\nTesting: ${endpoint}\n`);

  const validBody = JSON.stringify({
    model: "gpt-4.1-mini",
    max_tokens: 5,
    messages: [{ role: "user", content: [{ type: "text", text: "Reply with the single word OK." }] }],
  });
  const now = String(Math.floor(Date.now() / 1000));

  // ── Test 1: No auth headers at all ────────────────────────────────────────
  {
    const { status } = await post(endpoint, validBody);
    status === 400 || status === 401
      ? pass(`No auth headers → ${status}`)
      : fail("No auth headers", `expected 400 or 401, got ${status}`);
  }

  // ── Test 2: Missing X-Signature ───────────────────────────────────────────
  {
    const { status } = await post(endpoint, validBody, { "X-Timestamp": now });
    status === 401
      ? pass(`Missing X-Signature → 401`)
      : fail("Missing X-Signature", `expected 401, got ${status}`);
  }

  // ── Test 3: Expired timestamp (10 minutes ago) ────────────────────────────
  {
    const oldTs = String(Math.floor(Date.now() / 1000) - 600);
    const sig = sign(Buffer.from(validBody), oldTs);
    const { status } = await post(endpoint, validBody, {
      "X-Timestamp": oldTs,
      "X-Signature": sig,
    });
    status === 401
      ? pass(`Expired timestamp → 401`)
      : fail("Expired timestamp", `expected 401, got ${status}`);
  }

  // ── Test 4: Wrong signature ───────────────────────────────────────────────
  {
    const { status } = await post(endpoint, validBody, {
      "X-Timestamp": now,
      "X-Signature": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    });
    status === 401
      ? pass(`Wrong signature → 401`)
      : fail("Wrong signature", `expected 401, got ${status}`);
  }

  // ── Test 5: Valid signed request → 200 from OpenAI ───────────────────────
  {
    const sig = sign(Buffer.from(validBody), now);
    const { status, text } = await post(endpoint, validBody, {
      "X-Timestamp": now,
      "X-Signature": sig,
      "X-App-Version": "1.0",
    });
    if (status === 200) {
      let model = "unknown";
      try { model = JSON.parse(text).model; } catch {}
      pass(`Valid request → 200  (model: ${model})`);
    } else {
      let detail = text.slice(0, 200);
      fail(`Valid request`, `expected 200, got ${status}\n    ${detail}`);
    }
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log(
    process.exitCode === 1
      ? "\n  Some tests failed — check Worker logs: npx wrangler tail\n"
      : "\n  All tests passed — proxy is working correctly ✓\n"
  );
})();
