// Secret Notes — an over-the-air data modem (speaker → air → microphone). Pure JS, no DOM; runs in Node too.
//
// Three speeds, all built from tones on a 0.9–3.3 kHz grid where phone speakers and mics are comfortable:
//   Sturdy:  MFSK-8 at 75 baud, 3 bits/symbol (Gray-mapped). Consecutive symbols alternate between two interleaved
//            banks of 8 tones (1050–3300 Hz on a 150 Hz grid), so the echo/reverb of one symbol lands in the
//            other bank instead of on top of the next one.
//   Quick:   the same at 150 baud.
//   Classic: 300 baud binary FSK; the mark/space pair hops over 4 pairs (8 tones 900–3000 Hz) — the modem sound.
// Frame: preamble (two-tone alternation) | sync word | header (version, flags, length, CRC-8) | payload + CRC-32.
// FEC: rate-1/2 K=7 convolutional code (171/133 octal) with soft-decision Viterbi, whitening, block interleaving.
// The receiver tracks symbol timing with a transition (mid-symbol) detector and a 2nd-order loop, so ±0.5 %
// clock mismatch between devices is followed, and all soft decisions are energy ratios (level-independent).

export const NOTE_FS = 9600;          // decoder's internal rate: 32 samples/symbol at 300 baud, 64 at 150 baud
export const FRAME_VERSION = 1;
export const FLAG = { ENCRYPTED: 1, DEFLATE: 2 };

const range = (a, n, step) => Array.from({ length: n }, (_, i) => a + i * step);
export const MODES = {
  // MFSK-8 at 75 baud, two interleaved banks of 8 tones (300 Hz apart within a bank): 225 bit/s gross
  sturdy: { key: 'sturdy', id: 2, name: 'Sturdy', baud: 75, Ns: 128, bps: 3, P: 2, tones: range(1050, 16, 150), pre: [4, 11], preSyms: 38,
    sync: [10, 5, 12, 3, 8, 15, 0, 7], syncThr: 0.65 },
  // the same at 150 baud: 450 bit/s gross
  quick: { key: 'quick', id: 1, name: 'Quick', baud: 150, Ns: 64, bps: 3, P: 2, tones: range(1050, 16, 150), pre: [0, 15], preSyms: 75,
    sync: [2, 13, 4, 11, 6, 1, 14, 9], syncThr: 0.65 },
  // 300 baud binary FSK whose mark/space pair hops over 4 pairs (8 tones 900–3000 Hz): the classic modem sound
  classic: { key: 'classic', id: 0, name: 'Classic', baud: 300, Ns: 32, bps: 1, tones: range(900, 8, 300), P: 4, pre: [1, 5], preSyms: 150,
    sync: [0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0], syncThr: 0.32 }, // peak sidelobe 4
};
export const MODE_KEYS = ['sturdy', 'quick', 'classic'];
export const modeById = (id) => Object.values(MODES).find(m => m.id === id);
// test-only variant: plain MFSK-16 (no bank alternation), for the comparison in the README
export const MODE_VARIANTS = { quick16: { ...MODES.quick, key: 'quick16', bps: 4, P: 1, sync: [2, 13, 5, 10, 3, 12, 7, 8] } };
const HDR_BYTES = 4, POST_SYMS = 4;

// ------------------------------------------------------------------ checksums, whitening, FEC
const CRC32_T = new Uint32Array(256);
for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; CRC32_T[n] = c >>> 0; }
export function crc32(b) { let c = 0xffffffff; for (let i = 0; i < b.length; i++) c = CRC32_T[(c ^ b[i]) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
export function crc8(b) { let c = 0; for (const x of b) { c ^= x; for (let k = 0; k < 8; k++) c = c & 0x80 ? ((c << 1) ^ 0x07) & 255 : (c << 1) & 255; } return c; }

const bytesToBits = (b) => { const o = new Uint8Array(b.length * 8); for (let i = 0; i < b.length; i++) for (let k = 0; k < 8; k++) o[i * 8 + k] = (b[i] >> (7 - k)) & 1; return o; };
const bitsToBytes = (bits) => { const o = new Uint8Array(bits.length >> 3); for (let i = 0; i < o.length; i++) { let v = 0; for (let k = 0; k < 8; k++) v = (v << 1) | bits[i * 8 + k]; o[i] = v; } return o; };
/** PRBS9 (x^9 + x^5 + 1) whitening, so long runs of equal bits still make tone transitions */
function whiten(bits, seed) { let r = seed & 511; const o = new Uint8Array(bits.length); for (let i = 0; i < bits.length; i++) { const b = ((r >> 8) ^ (r >> 4)) & 1; r = ((r << 1) | b) & 511; o[i] = bits[i] ^ b; } return o; }
const SEED_HDR = 0x1a5, SEED_PAY = 0x0f3;

const G1 = 0o171, G2 = 0o133, K = 7, NST = 64;
const PAR = new Uint8Array(128); for (let i = 0; i < 128; i++) { let p = 0, x = i; while (x) { p ^= x & 1; x >>= 1; } PAR[i] = p; }
/** rate-1/2 K=7 convolutional encoder, terminated with 6 zero bits */
export function convEncode(bits) {
  const out = new Uint8Array((bits.length + K - 1) * 2); let st = 0, j = 0;
  for (let i = 0; i < bits.length + K - 1; i++) { const b = i < bits.length ? bits[i] : 0; const reg = (b << 6) | st; out[j++] = PAR[reg & G1]; out[j++] = PAR[reg & G2]; st = reg >> 1; }
  return out;
}
/** soft-decision Viterbi: soft[i] in [-1, 1], +1 = coded bit 1. Returns nBits decoded bits (tail removed). */
export function viterbi(soft, nBits) {
  const steps = nBits + K - 1; let pm = new Float64Array(NST).fill(-1e9); pm[0] = 0; let nx = new Float64Array(NST);
  const dec = new Uint8Array(steps * NST);
  const o1 = new Int8Array(128), o2 = new Int8Array(128); for (let r = 0; r < 128; r++) { o1[r] = PAR[r & G1] ? 1 : -1; o2[r] = PAR[r & G2] ? 1 : -1; }
  for (let t = 0; t < steps; t++) {
    const s1 = soft[2 * t] || 0, s2 = soft[2 * t + 1] || 0;
    for (let ns = 0; ns < NST; ns++) {
      const r0 = (ns << 1), r1 = r0 | 1;                        // predecessor state = reg & 63, dropped oldest bit = 0/1
      const m0 = pm[r0 & 63] + o1[r0] * s1 + o2[r0] * s2, m1 = pm[r1 & 63] + o1[r1] * s1 + o2[r1] * s2;
      if (m1 > m0) { nx[ns] = m1; dec[t * NST + ns] = 1; } else { nx[ns] = m0; dec[t * NST + ns] = 0; }
    }
    const tmp = pm; pm = nx; nx = tmp;
  }
  const bits = new Uint8Array(steps); let st = 0;                // terminated: end in state 0
  for (let t = steps - 1; t >= 0; t--) { bits[t] = st >> 5; const reg = (st << 1) | dec[t * NST + st]; st = reg & 63; }
  return bits.subarray(0, nBits);
}
/** block interleaver: write row-wise (C columns), read column-wise */
function interleave(a, C) { const N = a.length, R = Math.ceil(N / C), o = new (a.constructor)(N); let k = 0; for (let c = 0; c < C; c++) for (let r = 0; r < R; r++) { const i = r * C + c; if (i < N) o[k++] = a[i]; } return o; }
function deinterleave(a, C) { const N = a.length, R = Math.ceil(N / C), o = new (a.constructor)(N); let k = 0; for (let c = 0; c < C; c++) for (let r = 0; r < R; r++) { const i = r * C + c; if (i < N) o[i] = a[k++]; } return o; }
const IL_HDR = 8, IL_PAY = 24;

// ------------------------------------------------------------------ framing
const hdrCoded = () => (HDR_BYTES * 8 + K - 1) * 2;                          // 76 coded bits
const payCoded = (n) => ((n + 4) * 8 + K - 1) * 2;
const symsFor = (bits, m) => Math.ceil(bits / m.bps);
/** symbols (as tone indices) for a frame; sync/hdr/payload symbol i uses hop index i (Sturdy) */
export function frameSymbols(payload, flags, mode) {
  const m = typeof mode === 'string' ? (MODES[mode] || MODE_VARIANTS[mode]) : mode;
  const hdr = [(FRAME_VERSION << 4) | ((m.id & 3) << 2) | (flags & 3), payload.length >> 8, payload.length & 255, 0]; hdr[3] = crc8(hdr.slice(0, 3));
  const hBits = interleave(convEncode(whiten(bytesToBits(hdr), SEED_HDR)), IL_HDR);
  const body = new Uint8Array(payload.length + 4); body.set(payload); const c = crc32(payload); body[payload.length] = c >>> 24; body[payload.length + 1] = (c >>> 16) & 255; body[payload.length + 2] = (c >>> 8) & 255; body[payload.length + 3] = c & 255;
  const pBits = interleave(convEncode(whiten(bytesToBits(body), SEED_PAY)), IL_PAY);
  const tones = [];
  for (let i = 0; i < m.preSyms; i++) tones.push(m.pre[i & 1]);
  let idx = 0;
  const put = (bits) => { for (let i = 0; i < bits.length; i += m.bps) { let v = 0; for (let k = 0; k < m.bps; k++) v = (v << 1) | (bits[i + k] || 0); tones.push(mapSym(m, v, idx++)); } };
  if (m.bps === 1) put(Uint8Array.from(m.sync)); else for (const t of m.sync) tones.push(t), idx++;
  put(hBits); put(pBits);
  for (let i = 0; i < POST_SYMS; i++) tones.push(m.pre[0]);
  return tones;
}
const gray = (v) => v ^ (v >> 1);
const ungray = (g) => { let v = g; for (let s = 1; s < 8; s <<= 1) v ^= v >> s; return v; };
/** symbol i carries value v: tone = gray(v) * P + (i mod P) — consecutive symbols use interleaved tone banks */
function mapSym(m, v, i) { return gray(v) * m.P + (i % m.P); }

/** frame airtime in seconds (without the optional intro) */
export function frameSeconds(nBytes, mode) {
  const m = MODES[mode] || MODE_VARIANTS[mode]; const syms = m.preSyms + m.sync.length + symsFor(hdrCoded(), m) + symsFor(payCoded(nBytes), m) + POST_SYMS;
  return syms / m.baud + 0.03;
}
export const INTRO_SECONDS = 1.75;

// ------------------------------------------------------------------ synthesis
/**
 * Render a note to audio at sample rate `fs`. Continuous-phase tones (all tones are whole multiples of the
 * symbol rate) with a short raised-cosine glide between symbols, 10 ms fades, peak `amp`.
 * `intro`: a fake dial-up handshake flourish before the preamble (ignored by the receiver).
 */
export function synthesize(payload, flags, mode, { fs = 48000, amp = 0.5, intro = false } = {}) {
  const m = MODES[mode] || MODE_VARIANTS[mode]; const tones = frameSymbols(payload, flags, m).map(t => m.tones[t]);
  const introS = intro ? INTRO_SECONDS : 0, lead = 0.03;
  const nSym = tones.length, N = Math.ceil((introS + lead + nSym / m.baud + 0.03) * fs);
  const out = new Float32Array(N);
  let n0 = Math.round(lead * fs);
  if (intro) { renderIntro(out, fs, amp, n0); n0 += Math.round(introS * fs); }
  const spS = fs / m.baud, glide = 0.08; let ph = 0;
  const nEnd = n0 + Math.round(nSym * spS), fade = Math.round(0.01 * fs);
  for (let n = n0; n < nEnd; n++) {
    const t = (n - n0) / spS, k = Math.min(nSym - 1, Math.floor(t)), fr = t - k;
    let f = tones[k];
    if (k > 0 && fr < glide) { const w = 0.5 - 0.5 * Math.cos(Math.PI * fr / glide); f = tones[k - 1] + (f - tones[k - 1]) * w; }
    ph += 2 * Math.PI * f / fs; if (ph > 2 * Math.PI) ph -= 2 * Math.PI;
    const e = Math.min(1, (n - n0) / fade, (nEnd - n) / fade);
    out[n] = amp * e * Math.sin(ph);
  }
  return out;
}
function renderIntro(out, fs, amp, n0) {
  // answer tone 2100 Hz with a phase reversal, a V.21 "call menu" chirp, a probe chord, then a pause
  let n = n0; const put = (secs, fn) => { const L = Math.round(secs * fs); for (let i = 0; i < L; i++) { const e = Math.min(1, i / (0.008 * fs), (L - i) / (0.008 * fs)); out[n + i] += amp * 0.85 * e * fn(i / fs, i); } n += L; };
  put(0.8, (t) => Math.sin(2 * Math.PI * 2100 * t + (t > 0.45 ? Math.PI : 0)) * (1 + 0.2 * Math.sin(2 * Math.PI * 15 * t)));
  n += Math.round(0.07 * fs);
  let ph = 0, seed = 7; const bits = []; for (let i = 0; i < 120; i++) { seed = (seed * 1103515245 + 12345) >>> 0; bits.push(i < 10 ? 1 : seed >>> 31); }
  put(0.33, (t) => { const b = bits[Math.min(bits.length - 1, Math.floor(t * 300))]; ph += 2 * Math.PI * (b ? 980 : 1180) / fs; return Math.sin(ph); });
  n += Math.round(0.05 * fs);
  put(0.28, (t) => { let s = 0; for (let k = 1; k <= 25; k++) if (![6, 8, 12, 16].includes(k)) s += Math.cos(2 * Math.PI * k * 150 * t + k * k * 0.7); return s / 7; });
}

// ------------------------------------------------------------------ receiver
/** one mode's demodulator + frame state machine at NOTE_FS */
class Demod {
  constructor(m, emit) {
    this.m = m; this.emit = emit; const T = m.tones.length, Ns = m.Ns;
    this.cw = m.tones.map(f => Math.cos(2 * Math.PI * f / NOTE_FS)); this.sw = m.tones.map(f => Math.sin(2 * Math.PI * f / NOTE_FS));
    this.pc = new Float64Array(T).fill(1); this.ps = new Float64Array(T);
    this.zr = new Float64Array(T * Ns); this.zi = new Float64Array(T * Ns); this.sr = new Float64Array(T); this.si = new Float64Array(T);
    this.B = m.bps === 1 ? 24 : 16;                                    // symbols per timing block
    this.H = (this.B + 5) * Ns; this.E = new Float32Array(T * this.H);  // energy history ring
    this.tot = new Float32Array(this.H);
    this.W = 16 * Ns; this.rr = new Float64Array(this.W); this.ri = new Float64Array(this.W); this.rc = new Float64Array(this.W); this.rb = new Float64Array(this.W); this.Cr = 0; this.Ci = 0; this.Cc = 0; this.Cb = 0;
    this.nf = 1e-9; this.state = 'search'; this.hold = 0; this.n = 0;
  }
  energy(k, n) { return this.E[k * this.H + (n % this.H)]; }
  sample(x, n) {
    const m = this.m, T = m.tones.length, Ns = m.Ns, H = this.H, slot = n % Ns, h = n % H;
    let tot = 0;
    for (let k = 0; k < T; k++) {
      const c = this.pc[k], s = this.ps[k];
      const zr = x * c, zi = -x * s, o = k * Ns + slot;
      this.sr[k] += zr - this.zr[o]; this.si[k] += zi - this.zi[o]; this.zr[o] = zr; this.zi[o] = zi;
      this.pc[k] = c * this.cw[k] - s * this.sw[k]; this.ps[k] = s * this.cw[k] + c * this.sw[k];
      const e = (this.sr[k] * this.sr[k] + this.si[k] * this.si[k]) / (Ns * Ns); this.E[k * H + h] = e; tot += e;
    }
    this.tot[h] = tot;
    if ((n & 1023) === 1023) this._renorm();
    // noise floor: fast down, slow up
    if (n < Ns) return;                                    // running sums not full yet
    if (n === Ns) this.nf = tot + 1e-14;
    if (tot < this.nf) this.nf += (tot - this.nf) * 0.05; else this.nf *= 1.0001;   // fast down, ~4 dB/s up
    if (this.nf < 1e-14) this.nf = 1e-14;
    this.n = n;
    if (this.state === 'search') this._acquire(n, tot);
    else { this._track(n); }
  }
  _renorm() {
    const T = this.m.tones.length, Ns = this.m.Ns;
    for (let k = 0; k < T; k++) {
      const g = 1 / Math.hypot(this.pc[k], this.ps[k]); this.pc[k] *= g; this.ps[k] *= g;
      let a = 0, b = 0; for (let i = 0; i < Ns; i++) { a += this.zr[k * Ns + i]; b += this.zi[k * Ns + i]; } this.sr[k] = a; this.si[k] = b;
    }
  }
  // ---- preamble acquisition: the two preamble tones alternate at the symbol rate
  _acquire(n, tot) {
    const m = this.m, Ns = m.Ns, a = this.energy(m.pre[0], n), b = this.energy(m.pre[1], n);
    const r = (a - b) / (a + b + 0.5 * (tot - a - b) + 1e-20);
    const ang = Math.PI * (n % (2 * Ns)) / Ns, w = n % this.W;
    const vr = r * Math.cos(ang), vi = -r * Math.sin(ang);
    const conc = (a + b) / (tot + 1e-20), bal = a / (a + b + 1e-20);
    this.Cr += vr - this.rr[w]; this.Ci += vi - this.ri[w]; this.Cc += conc - this.rc[w]; this.Cb += bal - this.rb[w];
    this.rr[w] = vr; this.ri[w] = vi; this.rc[w] = conc; this.rb[w] = bal;
    const rho = Math.hypot(this.Cr, this.Ci) / this.W, cm = this.Cc / this.W, bm = this.Cb / this.W;
    // the band's energy sits in the two preamble tones, both are present, and they alternate (or echoes blur it)
    const ok = bm > 0.04 && bm < 0.96 && (cm > 0.7 || (cm > 0.33 && rho > 0.09));   // ratios only: level-independent
    if (ok) { if (++this.hold >= 2 * Ns) this._lock(n, rho > 0.1); } else this.hold = 0;
  }
  _lock(n, phaseKnown = true) {
    const Ns = this.m.Ns;
    let c = -Math.atan2(this.Ci, this.Cr) * Ns / Math.PI; c = ((c % (2 * Ns)) + 2 * Ns) % (2 * Ns);
    // c: window-end index (mod 2Ns) where a preamble symbol is fully inside the window
    let tau = n - (n % (2 * Ns)) + c; while (tau <= n) tau += Ns;
    this.tau = tau; this.per = Ns; this.fe = 0; this.wide = true; this.state = 'sync'; this.symCount = 0; this.hist = []; this.cand = null; this.hold = 0;
    this.emit({ kind: 'carrier', on: true, mode: this.m.key });
  }
  _reset(reason) {
    this.state = 'search'; this.Cr = this.Ci = this.Cc = this.Cb = 0; this.rr.fill(0); this.ri.fill(0); this.rc.fill(0); this.rb.fill(0); this.hold = 0;
    this.emit({ kind: 'carrier', on: false, mode: this.m.key, reason });
  }
  // ---- symbol timing: block tracker. For each block of B symbols pick the offset (±Ns/4) that maximises the summed
  // energy of each symbol's strongest tone, then fold that offset into the phase and (slowly) into the period.
  // A constant bias (echoes, reverb) is absorbed once as an offset; a clock mismatch shows up as a steady
  // per-block offset and is learnt by the period estimate.
  _track(n) {
    const m = this.m, Ns = m.Ns, B = this.B, D = this.wide ? Ns >> 1 : Ns >> 2;
    if (n < Math.ceil(this.tau + (B - 1) * this.per) + D) return;
    const first = this.wide; this.wide = false;
    const T = m.tones.length; let best = -1, bd = 0; const sc = [];
    for (let d = -D; d <= D; d++) {
      let s = 0;
      for (let i = 0; i < B; i++) { const t = Math.round(this.tau + i * this.per) + d; let mx = 0, tot = 0; for (let k = 0; k < T; k++) { const e = this.energy(k, t); tot += e; if (e > mx) mx = e; } s += mx / (tot + 1e-20); }
      sc.push(s); if (s > best) { best = s; bd = d; }
    }
    // parabolic refinement of the peak
    const k0 = bd + D; let frac = 0; if (k0 > 0 && k0 < sc.length - 1) { const a = sc[k0 - 1], b = sc[k0], c = sc[k0 + 1], den = a - 2 * b + c; if (den < 0) frac = Math.max(-0.5, Math.min(0.5, 0.5 * (a - c) / den)); }
    const off = bd + frac;
    for (let i = 0; i < B && this.state !== 'search'; i++) {
      const t = Math.round(this.tau + i * this.per + off); const ev = new Float32Array(T); let mx = 0, bk = 0;
      for (let k = 0; k < T; k++) { const e = this.energy(k, t); ev[k] = e; if (e > mx) { mx = e; bk = k; } }
      this.symbol(ev, bk);
    }
    if (this.state === 'search') return;
    // the first (wide) block only sets the phase; later blocks nudge the period, at most 0.2 % per block
    if (!first) this.per = Math.max(Ns * 0.99, Math.min(Ns * 1.01, this.per + Math.max(-0.002 * Ns, Math.min(0.002 * Ns, 0.35 * off / B))));
    this.fe = this.per / Ns - 1;
    this.tau += B * this.per + off;
  }
  symbol(ev, bk) {
    const m = this.m, L = m.sync.length;
    this.symCount++;
    if (this.state === 'sync') {
      // peak-pick the sync word: take the best-scoring position above threshold, confirmed half a sync-length later
      this.hist.push(ev);
      if (this.hist.length >= L) { const at = this.hist.length - L, sc = this._syncScore(at); if (sc > (this.cand ? this.cand.s : m.syncThr)) this.cand = { s: sc, end: this.hist.length - 1 }; }
      // once the header has arrived after the best candidate, decode it there and at ±1, ±2 symbols: keep the one whose
      // CRC-8 / version / speed check out (the sync peak can be blurred by echoes)
      const hs = symsFor(hdrCoded(), m);
      if (this.cand && this.hist.length - 1 >= this.cand.end + hs + 2) {
        const c = this.cand; this.cand = null; let got = null;
        for (const o of [0, -1, 1, -2, 2]) { const st = c.end + 1 + o; if (st < 0 || st + hs > this.hist.length) continue; const hb = this._header(this.hist.slice(st, st + hs)); if (hb) { got = { hb, st }; break; } }
        if (!got) { this.hist = []; this.emit({ kind: 'frame', ok: false, why: 'header', mode: m.key }); this._reset('header'); return; }
        const rest = this.hist.slice(got.st + hs); this.hist = [];
        this.emit({ kind: 'sync', mode: m.key });
        this._startPayload(got.hb);
        for (const e of rest) if (this.state === 'pay') this._data(e);
        return;
      }
      if (this.symCount > m.preSyms + L + hs + 60) this._reset('nosync');
      return;
    }
    this._data(ev);
  }
  /** decode a header from its symbols (soft bits computed with the hop index after the sync word); null if it fails */
  _header(syms) {
    const m = this.m, save = this.soft; this.soft = [];
    syms.forEach((ev, i) => this._softBits(ev, m.sync.length + i));
    const s = deinterleave(Float32Array.from(this.soft.slice(0, hdrCoded())), IL_HDR); this.soft = save;
    const hb = bitsToBytes(whiten(viterbi(s, HDR_BYTES * 8), SEED_HDR));
    return crc8(hb.subarray(0, 3)) === hb[3] && (hb[0] >> 4) === FRAME_VERSION && ((hb[0] >> 2) & 3) === m.id ? hb : null;
  }
  _startPayload(hb) {
    const m = this.m;
    this.flags = hb[0] & 3; this.len = (hb[1] << 8) | hb[2]; this.need = payCoded(this.len); this.soft = [];
    this.idx = m.sync.length + symsFor(hdrCoded(), m);
    this.emit({ kind: 'header', mode: m.key, len: this.len, flags: this.flags, seconds: frameSeconds(this.len, m.key) });
    this.state = 'pay';
  }
  _data(ev) {
    const m = this.m;
    this._softBits(ev, this.idx++);
    if (this.state === 'pay') {
      if ((this.soft.length & 63) < m.bps) this.emit({ kind: 'progress', mode: m.key, frac: Math.min(1, this.soft.length / this.need) });
      if (this.soft.length >= this.need) {
        const s = deinterleave(Float32Array.from(this.soft.slice(0, this.need)), IL_PAY);
        const body = bitsToBytes(whiten(viterbi(s, (this.len + 4) * 8), SEED_PAY));
        const pay = body.slice(0, this.len), c = crc32(pay);
        const ok = ((body[this.len] << 24) | (body[this.len + 1] << 16) | (body[this.len + 2] << 8) | body[this.len + 3]) >>> 0 === c;
        let q = 0; for (const v of this.soft) q += Math.abs(v); q /= this.soft.length;
        this.emit({ kind: 'frame', ok, why: ok ? '' : 'crc', mode: m.key, flags: this.flags, bytes: ok ? pay : null, quality: q });
        this._reset('done');
      }
    }
  }
  _syncScore(at) {
    const m = this.m; let s = 0; const H = this.hist.slice(at, at + m.sync.length);
    if (m.bps === 1) {
      // pattern match within each symbol's pair (amplitudes), gated by the pair holding a real share of the band
      let pres = 0;
      for (let k = 0; k < m.sync.length; k++) { const ev = H[k], p = k % m.P, a = Math.sqrt(ev[p]), b = Math.sqrt(ev[p + m.P]); let t = 0; for (const e of ev) t += e;
        s += (m.sync[k] ? b - a : a - b) / (a + b + 1e-20); pres += (ev[p] + ev[p + m.P]) / (t + 1e-20); }
      return pres / m.sync.length > 0.4 ? s / m.sync.length : 0;
    }
    for (let k = 0; k < m.sync.length; k++) { const ev = H[k]; let mx = 0; for (const e of ev) if (e > mx) mx = e; s += Math.sqrt(ev[m.sync[k]] / (mx + 1e-20)); }
    return s / m.sync.length;
  }
  /** soft bits from the symbol's tone bank: for each bit, strongest tone with bit=1 vs strongest with bit=0 (amplitudes) */
  _softBits(ev, i) {
    const m = this.m, p = i % m.P, nv = 1 << m.bps;
    for (let j = m.bps - 1; j >= 0; j--) {
      let m1 = 0, m0 = 0;
      for (let g = 0; g < nv; g++) { const a = Math.sqrt(ev[g * m.P + p]), bit = (ungray(g) >> j) & 1; if (bit) { if (a > m1) m1 = a; } else if (a > m0) m0 = a; }
      this.soft.push((m1 - m0) / (m1 + m0 + 1e-20));
    }
  }

}

/**
 * Streaming receiver. push() any-rate audio; events: carrier {on}, sync, header {len, seconds}, progress {frac},
 * frame {ok, why: ''|'crc'|'header', flags, bytes, mode}. Both speeds are listened for at once.
 */
export class NoteDecoder {
  constructor({ sampleRate, onEvent = () => {}, modes = null }) {
    this.fs = sampleRate; this.step = sampleRate / NOTE_FS; this.acc = 0; this.prev = 0; this.n = 0;
    // 4th-order Butterworth low-pass at 4 kHz before decimation
    this.lp = [biquadLP(4000, 0.5412, sampleRate), biquadLP(4000, 1.3066, sampleRate)];
    this.onEvent = onEvent;
    this.demods = (modes || MODE_KEYS.map(k => MODES[k])).map(m => new Demod(m, (e) => this._ev(e)));
  }
  _ev(e) { this.onEvent(e); }
  push(x) {
    for (let i = 0; i < x.length; i++) {
      let v = x[i]; for (const f of this.lp) v = f(v);
      // linear-interpolating decimator to NOTE_FS
      this.acc += 1;
      while (this.acc >= this.step) { this.acc -= this.step; const fr = 1 - this.acc; const y = this.prev + (v - this.prev) * fr; this._tick(y); }
      this.prev = v;
    }
  }
  _tick(y) { const n = this.n++; for (const d of this.demods) d.sample(y, n); }
  /** feed a little silence so a note at the very end of a file completes */
  flush(seconds = 0.3) { this.push(new Float32Array(Math.round(seconds * this.fs))); }
  get busy() { return this.demods.some(d => d.state !== 'search'); }
}
function biquadLP(f, q, fs) {
  const w = 2 * Math.PI * Math.min(f, fs * 0.45) / fs, c = Math.cos(w), al = Math.sin(w) / (2 * q), a0 = 1 + al;
  const b0 = (1 - c) / 2 / a0, b1 = (1 - c) / a0, b2 = b0, a1 = -2 * c / a0, a2 = (1 - al) / a0; let z1 = 0, z2 = 0;
  return (x) => { const y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y; };
}

/** convenience: decode a whole buffer, return the frame events */
export function decodeBuffer(samples, sampleRate, modes = null) {
  const out = []; const d = new NoteDecoder({ sampleRate, modes, onEvent: (e) => { if (e.kind === 'frame') out.push(e); } });
  const CH = 4096; for (let i = 0; i < samples.length; i += CH) d.push(samples.subarray(i, Math.min(samples.length, i + CH))); d.flush(0.5);
  return out;
}
