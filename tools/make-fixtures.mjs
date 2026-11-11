// Reference fixtures from the WEB implementation (RetroSynths Secret Notes), for the Swift tests:
// tone sequences, encrypted notes rendered to WAV, and deflate-raw output.
// usage: node tools/make-fixtures.mjs <path to RetroSynths/apps/oldschool/modem> <out dir>
import fs from 'fs'; import path from 'path'; import zlib from 'zlib';
const [, , modemDir, out] = process.argv;
const core = await import(path.resolve(modemDir, 'notes-core.js'));
const cry = await import(path.resolve(modemDir, 'notes-crypto.js'));
fs.mkdirSync(out, { recursive: true });
let seed = 99; const rnd = () => (seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296;
const wav = (f, fs) => { const b = Buffer.alloc(44 + f.length * 2); b.write('RIFF', 0); b.writeUInt32LE(36 + f.length * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(fs, 24); b.writeUInt32LE(fs * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(f.length * 2, 40); for (let i = 0; i < f.length; i++) b.writeInt16LE(Math.max(-32767, Math.min(32767, Math.round(f[i] * 32767))), 44 + i * 2); return b; };
const symbols = [];
for (const key of core.MODE_KEYS) for (let t = 0; t < 4; t++) {
  const n = [1, 7, 60, 300][t]; const payload = Array.from({ length: n }, () => Math.floor(rnd() * 256)); const flags = t & 3;
  symbols.push({ mode: key, flags, payload, tones: core.frameSymbols(Uint8Array.from(payload), flags, key) });
}
fs.writeFileSync(path.join(out, 'symbols.json'), JSON.stringify(symbols));
const notes = [];
const texts = ['Meet at the hammocks at 4.', 'Café ☕ — ünïcode & emoji 🐢 survive', 'The shed key is in the blue jar. The shed key is in the blue jar. Repeat: the blue jar.'];
let i = 0;
for (const key of core.MODE_KEYS) {
  const text = texts[i % texts.length], pass = i === 1 ? '' : 'tangerine owl ' + i;
  const { payload, flags } = await cry.packNote(text, pass, core.MODES[key].id);
  const fs_ = [16000, 44100, 48000][i % 3];
  const audio = core.synthesize(payload, flags, key, { fs: fs_, amp: 0.4, intro: i === 2 });
  const file = `note-${key}.wav`; fs.writeFileSync(path.join(out, file), wav(audio, fs_));
  notes.push({ file, mode: key, text, passphrase: pass, flags }); i++;
}
fs.writeFileSync(path.join(out, 'notes.json'), JSON.stringify(notes, null, 1));
const sample = 'Meet at the hammocks at 4. Meet at the hammocks at 4. Bring the red flashlight and the red thermos.';
fs.writeFileSync(path.join(out, 'deflate.json'), JSON.stringify({ text: sample, raw: [...zlib.deflateRawSync(Buffer.from(sample))], rawBest: [...zlib.deflateRawSync(Buffer.from(sample.repeat(5)), { level: 9 })], textBest: sample.repeat(5) }));
console.log('fixtures:', symbols.length, 'symbol sets,', notes.length, 'notes');
