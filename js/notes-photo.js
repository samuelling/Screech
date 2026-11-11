// Screech photos: a tiny baseline-JPEG-style codec sent as a train of modem frames, one 16-pixel stripe per
// frame, so the picture paints in from the top as it arrives (and a lost stripe smears instead of killing it).
// Shared, byte for byte, by Screech (web), RetroSynths' Modem and (ported) Screech for iPhone. Spec: PHOTO.md.
import { synthesize, frameSeconds } from './notes-core.js';
import { deriveKey } from './notes-crypto.js';

export const PHOTO_FRAME_VERSION = 2;
export const KIND = { HEADER: 0, BAND: 1 };
export const CODEC_VERSION = 1;
export const SIZES = { tiny: 64, small: 96, large: 128 };            // longest side, pixels
export const QUALITY = { low: 20, medium: 35, high: 55 };
export const GAP_SECONDS = 0.15;                                   // silence between frames

// ------------------------------------------------------------------ JPEG building blocks
const ZZ = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63];
const QL = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99];
const QC = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99];
/** libjpeg's quality scaling */
export function quantTable(base, quality) {
  const q = Math.max(1, Math.min(100, quality)), s = q < 50 ? Math.floor(5000 / q) : 200 - 2 * q;
  return base.map(v => Math.max(1, Math.min(255, Math.floor((v * s + 50) / 100))));
}
const COS = new Float64Array(64);
for (let u = 0; u < 8; u++) for (let x = 0; x < 8; x++) COS[u * 8 + x] = (u === 0 ? Math.SQRT1_2 : 1) * 0.5 * Math.cos((2 * x + 1) * u * Math.PI / 16);
function fdct(b) {         // in place, 8×8 row-major
  const t = new Float64Array(64);
  for (let y = 0; y < 8; y++) for (let u = 0; u < 8; u++) { let s = 0; for (let x = 0; x < 8; x++) s += COS[u * 8 + x] * b[y * 8 + x]; t[y * 8 + u] = s; }
  for (let u = 0; u < 8; u++) for (let v = 0; v < 8; v++) { let s = 0; for (let y = 0; y < 8; y++) s += COS[v * 8 + y] * t[y * 8 + u]; b[v * 8 + u] = s; }
}
function idct(b) {
  const t = new Float64Array(64);
  for (let v = 0; v < 8; v++) for (let x = 0; x < 8; x++) { let s = 0; for (let u = 0; u < 8; u++) s += COS[u * 8 + x] * b[v * 8 + u]; t[v * 8 + x] = s; }
  for (let x = 0; x < 8; x++) for (let y = 0; y < 8; y++) { let s = 0; for (let v = 0; v < 8; v++) s += COS[v * 8 + y] * t[v * 8 + x]; b[y * 8 + x] = s; }
}

// ------------------------------------------------------------------ Exp-Golomb bit I/O (MSB first)
class BitWriter {
  constructor() { this.out = []; this.acc = 0; this.n = 0; }
  bit(b) { this.acc = (this.acc << 1) | b; if (++this.n === 8) { this.out.push(this.acc); this.acc = 0; this.n = 0; } }
  ue(v) { const x = v + 1, len = 32 - Math.clz32(x); for (let i = 1; i < len; i++) this.bit(0); for (let i = len - 1; i >= 0; i--) this.bit((x >> i) & 1); }
  se(v) { this.ue(v > 0 ? 2 * v - 1 : -2 * v); }
  bytes() { if (this.n) { this.out.push(this.acc << (8 - this.n)); this.acc = 0; this.n = 0; } return Uint8Array.from(this.out); }
}
class BitReader {
  constructor(b) { this.b = b; this.p = 0; }
  bit() { if (this.p >= this.b.length * 8) throw new Error('eof'); const v = (this.b[this.p >> 3] >> (7 - (this.p & 7))) & 1; this.p++; return v; }
  ue() { let z = 0; while (this.bit() === 0) { if (++z > 24) throw new Error('bad code'); } let x = 1; for (let i = 0; i < z; i++) x = (x << 1) | this.bit(); return x - 1; }
  se() { const m = this.ue(); return m & 1 ? (m + 1) >> 1 : -(m >> 1); }
}

// ------------------------------------------------------------------ image geometry
export function fitSize(w, h, longest) {
  const s = longest / Math.max(w, h);
  return { w: Math.max(8, Math.round(w * s)), h: Math.max(8, Math.round(h * s)) };
}
const pad16 = (n) => Math.ceil(n / 16) * 16;

/**
 * Encode RGBA pixels (w×h, already at the size to send) into stripes of 16 rows.
 * Returns { w, h, quality, gray, bands: Uint8Array[] }.
 */
export function encodeImage(rgba, w, h, { quality = QUALITY.medium, gray = false } = {}) {
  const W = pad16(w), H = pad16(h), Y = new Float64Array(W * H), Cb = new Float64Array(W * H), Cr = new Float64Array(W * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const sx = Math.min(w - 1, x), sy = Math.min(h - 1, y), o = (sy * w + sx) * 4, r = rgba[o], g = rgba[o + 1], b = rgba[o + 2], i = y * W + x;
    Y[i] = 0.299 * r + 0.587 * g + 0.114 * b;
    Cb[i] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128;
    Cr[i] = 0.5 * r - 0.418688 * g - 0.081312 * b + 128;
  }
  const W2 = W / 2, H2 = H / 2, cb = new Float64Array(W2 * H2), cr = new Float64Array(W2 * H2);
  for (let y = 0; y < H2; y++) for (let x = 0; x < W2; x++) {
    const i = 2 * y * W + 2 * x;
    cb[y * W2 + x] = (Cb[i] + Cb[i + 1] + Cb[i + W] + Cb[i + W + 1]) / 4;
    cr[y * W2 + x] = (Cr[i] + Cr[i + 1] + Cr[i + W] + Cr[i + W + 1]) / 4;
  }
  const ql = quantTable(QL, quality), qc = quantTable(QC, quality);
  const bands = [];
  for (let band = 0; band < H / 16; band++) {
    const bw = new BitWriter(), pred = [0, 0, 0];
    const block = (plane, pw, x0, y0, q, comp) => {
      const b = new Float64Array(64);
      for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) b[y * 8 + x] = plane[(y0 + y) * pw + x0 + x] - 128;
      fdct(b);
      const z = new Int32Array(64); for (let k = 0; k < 64; k++) z[k] = Math.round(b[ZZ[k]] / q[ZZ[k]]);
      bw.se(z[0] - pred[comp]); pred[comp] = z[0];
      // AC: a "coded" bit, then (run, |level|-1, sign, last) for each non-zero coefficient in zigzag order
      let lastK = 0; for (let k = 63; k > 0; k--) if (z[k] !== 0) { lastK = k; break; }
      bw.bit(lastK ? 1 : 0);
      let run = 0;
      for (let k = 1; k <= lastK; k++) {
        if (z[k] === 0) { run++; continue; }
        bw.ue(run); bw.ue(Math.abs(z[k]) - 1); bw.bit(z[k] < 0 ? 1 : 0); bw.bit(k === lastK ? 1 : 0); run = 0;
      }
    };
    for (let m = 0; m < W / 16; m++) {
      const x = m * 16, y = band * 16;
      block(Y, W, x, y, ql, 0); block(Y, W, x + 8, y, ql, 0); block(Y, W, x, y + 8, ql, 0); block(Y, W, x + 8, y + 8, ql, 0);
      if (!gray) { block(cb, W2, m * 8, band * 8, qc, 1); block(cr, W2, m * 8, band * 8, qc, 2); }
    }
    bands.push(bw.bytes());
  }
  return { w, h, quality, gray, bands };
}

/** Decode one stripe into `rgba` (w×h×4). Returns false if the stripe's bits don't make sense. */
export function decodeBand(bytes, band, { w, h, quality, gray }, rgba) {
  const W = pad16(w), ql = quantTable(QL, quality), qc = quantTable(QC, quality);
  const Yb = new Float64Array(W * 16), cb = new Float64Array(W / 2 * 8), cr = new Float64Array(W / 2 * 8);
  if (gray) { cb.fill(128); cr.fill(128); }
  const br = new BitReader(bytes), pred = [0, 0, 0];
  const block = (plane, pw, x0, y0, q, comp) => {
    const z = new Int32Array(64);
    z[0] = pred[comp] + br.se(); pred[comp] = z[0];
    if (br.bit()) {
      let k = 1;
      for (;;) {
        k += br.ue(); if (k > 63) throw new Error('overrun');
        const mag = br.ue() + 1; z[k++] = br.bit() ? -mag : mag;
        if (br.bit()) break;
        if (k > 63) throw new Error('overrun');
      }
    }
    const b = new Float64Array(64); for (let i = 0; i < 64; i++) b[ZZ[i]] = z[i] * q[ZZ[i]];
    idct(b);
    for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) plane[(y0 + y) * pw + x0 + x] = b[y * 8 + x] + 128;
  };
  try {
    for (let m = 0; m < W / 16; m++) {
      const x = m * 16;
      block(Yb, W, x, 0, ql, 0); block(Yb, W, x + 8, 0, ql, 0); block(Yb, W, x, 8, ql, 0); block(Yb, W, x + 8, 8, ql, 0);
      if (!gray) { block(cb, W / 2, m * 8, 0, qc, 1); block(cr, W / 2, m * 8, 0, qc, 2); }
    }
  } catch (e) { return false; }
  const clamp = (v) => v < 0 ? 0 : v > 255 ? 255 : Math.round(v);
  for (let y = 0; y < 16; y++) {
    const py = band * 16 + y; if (py >= h) break;
    for (let x = 0; x < w; x++) {
      const Yv = Yb[y * W + x], c = (y >> 1) * (W / 2) + (x >> 1), u = cb[c] - 128, v = cr[c] - 128, o = (py * w + x) * 4;
      rgba[o] = clamp(Yv + 1.402 * v); rgba[o + 1] = clamp(Yv - 0.344136 * u - 0.714136 * v); rgba[o + 2] = clamp(Yv + 1.772 * u); rgba[o + 3] = 255;
    }
  }
  return true;
}

/** a lost stripe: smear the row above it down through the stripe, with a little static, like a corrupt JPEG */
export function smearBand(band, { w, h }, rgba, seed = 1) {
  let s = seed >>> 0 || 1;
  const rnd = () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
  const src = band * 16 - 1;
  for (let y = 0; y < 16; y++) {
    const py = band * 16 + y; if (py >= h) break;
    for (let x = 0; x < w; x++) {
      const o = (py * w + x) * 4, so = (Math.max(0, src) * w + Math.min(w - 1, x + (y >> 2))) * 4, n = (rnd() - 0.5) * 60;
      for (let c = 0; c < 3; c++) rgba[o + c] = src >= 0 ? Math.max(0, Math.min(255, rgba[so + c] + n)) : 96 + n;
      rgba[o + 3] = 255;
    }
  }
}

// ------------------------------------------------------------------ packets
const te = new TextEncoder();
const subtle = () => (globalThis.crypto && globalThis.crypto.subtle) || null;
async function aesKey(passphrase, salt) { return deriveKey(passphrase, salt); }
const bandNonce = (prefix, i) => { const n = new Uint8Array(12); n.set(prefix, 0); n[8] = (i >>> 24) & 255; n[9] = (i >>> 16) & 255; n[10] = (i >>> 8) & 255; n[11] = i & 255; return n; };
const bandAad = (header, i) => { const a = new Uint8Array(header.length + 1); a.set(header); a[header.length] = i; return a; };

/**
 * Build the frame payloads for a photo: header, every stripe, header again.
 * Returns { id, header, frames: [{ payload, flags, kind, index }] } — send each with version 2.
 */
export async function packPhoto(img, passphrase, modeId) {
  const enc = !!passphrase, id = (Math.random() * 65536) >>> 0;
  if (img.bands.length > 255) throw new Error('photo too tall');
  const hdr = [KIND.HEADER, id >> 8, id & 255, CODEC_VERSION, img.w >> 8, img.w & 255, img.h >> 8, img.h & 255, img.quality, img.bands.length, img.gray ? 1 : 0];
  let key = null;
  if (enc) {
    if (!subtle()) throw new Error('This browser has no WebCrypto (needs https).');
    const salt = crypto.getRandomValues(new Uint8Array(16)), prefix = crypto.getRandomValues(new Uint8Array(8));
    hdr.push(...salt, ...prefix);
    key = await aesKey(passphrase, salt);
  }
  const header = Uint8Array.from(hdr), flags = enc ? 1 : 0;
  const frames = [{ payload: header, flags, kind: KIND.HEADER, index: -1 }];
  for (let i = 0; i < img.bands.length; i++) {
    let body = img.bands[i];
    if (enc) body = new Uint8Array(await subtle().encrypt({ name: 'AES-GCM', iv: bandNonce(header.subarray(27, 35), i), additionalData: bandAad(header, i), tagLength: 128 }, key, body));
    const p = new Uint8Array(4 + body.length); p.set([KIND.BAND, id >> 8, id & 255, i]); p.set(body, 4);
    frames.push({ payload: p, flags, kind: KIND.BAND, index: i });
  }
  frames.push({ payload: header, flags, kind: KIND.HEADER, index: -1 });
  return { id, header, frames };
}

/** total airtime in seconds */
export function photoSeconds(frames, modeKey, intro = false) {
  return frames.reduce((s, f) => s + frameSeconds(f.payload.length, modeKey) + GAP_SECONDS, 0) + (intro ? 1.75 : 0);
}

/**
 * Render a whole photo train to audio. Returns { audio, marks } where marks[i] = { start, end } in seconds for each
 * frame, so the sender can show its own picture painting in time with the sound.
 */
export function synthesizePhoto(frames, modeKey, { fs = 48000, amp = 0.5, intro = false } = {}) {
  const parts = [], marks = []; let t = 0;
  frames.forEach((f, i) => {
    const a = synthesize(f.payload, f.flags, modeKey, { fs, amp, intro: intro && i === 0, version: PHOTO_FRAME_VERSION });
    parts.push(a); marks.push({ start: t, end: t + a.length / fs, kind: f.kind, index: f.index }); t += a.length / fs + GAP_SECONDS;
  });
  const out = new Float32Array(Math.ceil(t * fs)); let n = 0;
  for (const a of parts) { out.set(a, n); n += a.length + Math.round(GAP_SECONDS * fs); }
  return { audio: out, marks };
}

/**
 * Receiver side. feed() every version-2 frame that passed its CRC; onUpdate({ id, photo }) fires whenever a photo
 * changes. photo = { id, w, h, gray, quality, bands, rgba, got: Set, lost: Set, status, encrypted, mode, done }.
 * status: 'receiving' | 'done' | 'locked' (needs passphrase) | 'badpass' | 'waiting' (stripes before the header).
 */
export class PhotoReceiver {
  constructor({ onUpdate = () => {}, passphrase = () => '' } = {}) { this.onUpdate = onUpdate; this.pass = passphrase; this.photos = new Map(); }
  _get(id) {
    let p = this.photos.get(id);
    if (!p) { p = { id, header: null, pending: new Map(), got: new Set(), lost: new Set(), status: 'waiting', next: 0, rgba: null, done: false }; this.photos.set(id, p); }
    return p;
  }
  async feed(bytes, flags, modeKey) {
    if (!bytes || bytes.length < 4) return;
    const kind = bytes[0], id = (bytes[1] << 8) | bytes[2], p = this._get(id); p.mode = modeKey; p.encrypted = !!(flags & 1);
    if (kind === KIND.HEADER) {
      const first = !p.header; if (!first) { p.done = true; this._finish(p); this.onUpdate(p); return; }
      if (bytes[3] !== CODEC_VERSION) return;
      p.header = bytes; p.w = (bytes[4] << 8) | bytes[5]; p.h = (bytes[6] << 8) | bytes[7]; p.quality = bytes[8]; p.bands = bytes[9]; p.gray = bytes[10] === 1;
      if (!p.w || !p.h || p.w > 1024 || p.h > 1024 || p.bands !== Math.ceil(p.h / 16)) { this.photos.delete(id); return; }
      p.rgba = new Uint8ClampedArray(p.w * p.h * 4);
      for (let i = 3; i < p.rgba.length; i += 4) p.rgba[i] = 255;
      p.status = 'receiving';
      if (p.encrypted) await this._unlock(p);
      const late = p.pending.size > 0;              // stripes came first: this is the closing copy of the header
      for (const [i, b] of [...p.pending].sort((x, y) => x[0] - y[0])) { p.pending.delete(i); await this._band(p, i, b); }
      if (late) { p.done = true; this._finish(p); }
      this.onUpdate(p);
      return;
    }
    if (kind !== KIND.BAND) return;
    const i = bytes[3], body = bytes.subarray(4);
    if (!p.header || (p.encrypted && !p.key)) { p.pending.set(i, body); if (!p.header) p.status = 'waiting'; this.onUpdate(p); return; }
    await this._band(p, i, body);
    this.onUpdate(p);
  }
  /** call when the passphrase changes: tries locked photos again */
  async retry() { for (const p of this.photos.values()) if (p.header && p.encrypted && !p.key) { await this._unlock(p); for (const [i, b] of [...p.pending]) { p.pending.delete(i); await this._band(p, i, b); } if (p.done) this._finish(p); this.onUpdate(p); } }
  async _unlock(p) {
    const pass = this.pass();
    if (!pass) { p.status = 'locked'; return; }
    try { p.key = await deriveKey(pass, p.header.subarray(11, 27)); p.status = 'receiving'; }
    catch (e) { p.status = 'locked'; }
  }
  async _band(p, i, body) {
    if (i >= p.bands || p.got.has(i)) return;
    let data = body;
    if (p.encrypted) {
      if (!p.key) { p.pending.set(i, body); return; }
      try { data = new Uint8Array(await subtle().decrypt({ name: 'AES-GCM', iv: bandNonce(p.header.subarray(27, 35), i), additionalData: bandAad(p.header, i), tagLength: 128 }, p.key, body)); }
      catch (e) { p.key = null; p.status = 'badpass'; p.pending.set(i, body); return; }
    }
    // stripes that should have come before this one and didn't: lost
    for (let j = p.next; j < i; j++) if (!p.got.has(j)) { p.lost.add(j); smearBand(j, p, p.rgba, p.id * 31 + j); }
    if (decodeBand(data, i, p, p.rgba)) { p.got.add(i); p.lost.delete(i); } else { p.lost.add(i); smearBand(i, p, p.rgba, p.id * 31 + i); }
    p.next = Math.max(p.next, i + 1);
    p.status = 'receiving';
  }
  _finish(p) {
    if (!p.header || (p.encrypted && !p.key)) return;
    for (let j = 0; j < p.bands; j++) if (!p.got.has(j) && !p.lost.has(j)) { p.lost.add(j); smearBand(j, p, p.rgba, p.id * 31 + j); }
    p.status = 'done';
  }
  /** the stripe expected next, for the "loading" cursor */
  nextBand(id) { const p = this.photos.get(id); return p ? p.next : 0; }
}
