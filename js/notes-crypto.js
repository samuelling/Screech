// Secret Notes payload packing: optional deflate, then (with a passphrase) AES-256-GCM via WebCrypto.
// Encrypted packet = version(1) | salt(16) | iv(12) | ciphertext + 16-byte tag   (45 bytes of overhead)
// Key = PBKDF2-HMAC-SHA256(passphrase, salt, 200 000 iterations) -> 256-bit AES-GCM key.
// The frame header bits (version, speed, flags) are bound in as GCM additional data.
// Nothing here logs passphrases or plaintext.
import { FLAG } from './notes-core.js';

export const CRYPTO_VERSION = 1;
export const PBKDF2_ITERATIONS = 200000;
const subtle = () => (globalThis.crypto && globalThis.crypto.subtle) || null;
const te = new TextEncoder(), td = new TextDecoder('utf-8', { fatal: false });

async function deflate(bytes) {
  if (typeof CompressionStream === 'undefined') return null;
  const s = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(s).arrayBuffer());
}
async function inflate(bytes) {
  const s = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(s).arrayBuffer());
}
export async function deriveKey(passphrase, salt, iterations = PBKDF2_ITERATIONS) {
  const base = await subtle().importKey('raw', te.encode(passphrase.normalize('NFC')), 'PBKDF2', false, ['deriveKey']);
  return subtle().deriveKey({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}
const aad = (flags, modeId) => Uint8Array.of(1, flags & 3, modeId & 3);

/** text (+ optional passphrase) -> { payload: Uint8Array, flags } ready for synthesize() */
export async function packNote(text, passphrase, modeId = 0) {
  let data = te.encode(text), flags = 0;
  const z = await deflate(data).catch(() => null);
  if (z && z.length + 1 < data.length) { data = z; flags |= FLAG.DEFLATE; }
  if (!passphrase) return { payload: data, flags };
  if (!subtle()) throw new Error('This browser has no WebCrypto (needs a secure context: https or localhost).');
  flags |= FLAG.ENCRYPTED;
  const salt = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveKey(passphrase, salt);
  const ct = new Uint8Array(await subtle().encrypt({ name: 'AES-GCM', iv, additionalData: aad(flags, modeId), tagLength: 128 }, key, data));
  const out = new Uint8Array(1 + 16 + 12 + ct.length); out[0] = CRYPTO_VERSION; out.set(salt, 1); out.set(iv, 17); out.set(ct, 29);
  return { payload: out, flags };
}
/** a frame that passed CRC-32 -> { status: 'open'|'secret'|'locked'|'badpass', text } */
export async function unpackNote(bytes, flags, passphrase, modeId = 0) {
  let data = bytes;
  if (flags & FLAG.ENCRYPTED) {
    if (!passphrase) return { status: 'locked' };
    if (bytes.length < 1 + 16 + 12 + 16 || bytes[0] !== CRYPTO_VERSION) return { status: 'badpass' };
    try {
      const key = await deriveKey(passphrase, bytes.slice(1, 17));
      data = new Uint8Array(await subtle().decrypt({ name: 'AES-GCM', iv: bytes.slice(17, 29), additionalData: aad(flags, modeId), tagLength: 128 }, key, bytes.slice(29)));
    } catch (e) { return { status: 'badpass' }; }
  }
  if (flags & FLAG.DEFLATE) { try { data = await inflate(data); } catch (e) { return { status: (flags & FLAG.ENCRYPTED) ? 'badpass' : 'garbled' }; } }
  return { status: (flags & FLAG.ENCRYPTED) ? 'secret' : 'open', text: td.decode(data) };
}
/** payload size in bytes before compression (for the airtime estimate while typing) */
export const estimateBytes = (text, secret) => te.encode(text).length + (secret ? 45 : 0);
