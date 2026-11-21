#!/usr/bin/env node
// Generate a DEV-ONLY RS256 key pair for JWTs.
//
//   node scripts/gen-keys.mjs           # creates keys/ if missing, refuses to overwrite
//   node scripts/gen-keys.mjs --force   # replace existing keys (invalidates issued tokens)
//
// keys/private.pem  PKCS#8, read ONLY by the gateway (api-identity) to sign tokens.
// keys/public.pem   SPKI, read by the order-orchestrator to verify tokens itself
//                   (rule 16: it never trusts the gateway's word).
// keys/ is git-ignored. Never commit these files; real environments use a secret store.

import { generateKeyPairSync } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync, chmodSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const keyDir = join(root, 'keys');
const privPath = join(keyDir, 'private.pem');
const pubPath = join(keyDir, 'public.pem');
const force = process.argv.includes('--force');

if (!force && (existsSync(privPath) || existsSync(pubPath))) {
  console.log(`[SKIP] keys already exist in ${keyDir} (use --force to replace)`);
  process.exit(0);
}

// RS256 = RSASSA-PKCS1-v1_5 with SHA-256; 2048-bit modulus is the RFC 7518 minimum.
const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicExponent: 0x10001,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});

mkdirSync(keyDir, { recursive: true });
writeFileSync(privPath, privateKey, { mode: 0o600 });
writeFileSync(pubPath, publicKey, { mode: 0o644 });
try { chmodSync(privPath, 0o600); } catch { /* no-op on Windows */ }

console.log(`[OK] wrote ${privPath}`);
console.log(`[OK] wrote ${pubPath}`);
