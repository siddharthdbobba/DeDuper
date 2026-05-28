/**
 * Known-answer HMAC fixture test.
 * Run with: node test.js
 *
 * Both this file and ProxySignatureTests.swift must produce the same
 * signature for these fixed inputs. If they disagree, the app will never
 * authenticate against the Worker.
 *
 * Inputs (fixed, do not change):
 *   secret    = [0x74, 0x65, 0x73, 0x74]  ("test" in ASCII)
 *   timestamp = "1716850000"
 *   body      = {"test":1}                 (exact UTF-8 bytes, no trailing newline)
 *
 * Expected outputs:
 *   bodyHex   = 1da06016289bd76a5ada4f52fc805ae0c394612f17ec6d0f0c29b636473c8a9d
 *   signature = ad9b51ce3a6dfa07e2b39db65233e3f5b20fe67dcba0d7f5d89d55cfb9ff5498
 */

const crypto = require("crypto");

const SECRET    = Buffer.from([0x74, 0x65, 0x73, 0x74]);
const TIMESTAMP = "1716850000";
const BODY      = Buffer.from('{"test":1}', "utf8");

const EXPECTED_BODY_HEX = "1da06016289bd76a5ada4f52fc805ae0c394612f17ec6d0f0c29b636473c8a9d";
const EXPECTED_SIG      = "ad9b51ce3a6dfa07e2b39db65233e3f5b20fe67dcba0d7f5d89d55cfb9ff5498";

// Reproduce the Worker's signing algorithm
const bodyHex    = crypto.createHash("sha256").update(BODY).digest("hex");
const signedStr  = TIMESTAMP + "." + bodyHex;
const signature  = crypto.createHmac("sha256", SECRET).update(signedStr, "utf8").digest("hex");

let passed = true;

if (bodyHex !== EXPECTED_BODY_HEX) {
  console.error("FAIL bodyHex");
  console.error("  expected:", EXPECTED_BODY_HEX);
  console.error("  got:     ", bodyHex);
  passed = false;
}

if (signature !== EXPECTED_SIG) {
  console.error("FAIL signature");
  console.error("  expected:", EXPECTED_SIG);
  console.error("  got:     ", signature);
  passed = false;
}

if (passed) {
  console.log("PASS — HMAC fixture matches expected values");
  console.log("  bodyHex:  ", bodyHex);
  console.log("  signature:", signature);
} else {
  process.exit(1);
}
