// Swift ↔ web compatibility check, run in CI after `swift build --product screech-cli`.
//   node tools/web-decode.mjs --self-test      Swift encodes → web decodes, and web encodes → Swift decodes
//   node tools/web-decode.mjs <file.wav> <passphrase|->   decode a WAV with the web code
import fs from 'fs'; import path from 'path'; import os from 'os'; import { execFileSync } from 'child_process';
const here = path.dirname(new URL(import.meta.url).pathname);
const core = await import(path.join(here, '../docs/js/notes-core.js'));
const cry = await import(path.join(here, '../docs/js/notes-crypto.js'));
const cli = fs.existsSync(path.join(here, '../.build/release/screech-cli')) ? path.join(here, '../.build/release/screech-cli') : path.join(here, '../.build/debug/screech-cli');

function readWav(file) {
  const b = fs.readFileSync(file); const rate = b.readUInt32LE(24); let p = 12;
  while (p < b.length) { const id = b.toString('ascii', p, p + 4), sz = b.readUInt32LE(p + 4); if (id === 'data') { const s = new Float32Array(sz / 2); for (let i = 0; i < s.length; i++) s[i] = b.readInt16LE(p + 8 + 2 * i) / 32768; return { s, rate }; } p += 8 + sz; }
  throw new Error('no data chunk');
}
async function webDecode(file, pass) {
  const { s, rate } = readWav(file); const out = [];
  for (const f of core.decodeBuffer(s, rate)) { if (!f.ok) { out.push('FAIL ' + f.mode); continue; } const u = await cry.unpackNote(f.bytes, f.flags, pass, core.MODES[f.mode].id); out.push(`${u.status.toUpperCase()} ${f.mode}: ${u.text ?? ''}`); }
  return out;
}
const wav = (f, fs_) => { const b = Buffer.alloc(44 + f.length * 2); b.write('RIFF', 0); b.writeUInt32LE(36 + f.length * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(fs_, 24); b.writeUInt32LE(fs_ * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(f.length * 2, 40); for (let i = 0; i < f.length; i++) b.writeInt16LE(Math.max(-32767, Math.min(32767, Math.round(f[i] * 32767))), 44 + i * 2); return b; };

if (process.argv[2] !== '--self-test') { (await webDecode(process.argv[2], process.argv[3] === '-' ? '' : process.argv[3])).forEach(l => console.log(l)); process.exit(0); }

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'screech-'));
const cases = [
  ['sturdy', 'owl moon', 'Swift says hi — 🐢 at the hammocks', 48000, false],
  ['quick', '', 'open note from Swift, no secrets here', 44100, false],
  ['classic', 'x y z', 'Classic screech from the phone', 16000, true],
  ['quick', 'pw', 'The blue jar, the blue jar, the blue jar is where the shed key lives; the blue jar by the door.', 48000, false],
];
let bad = 0;
for (const [mode, pass, text, rate, intro] of cases) {
  // Swift → web
  const f1 = path.join(dir, `sw-${mode}.wav`);
  execFileSync(cli, ['encode', mode, pass || '-', text, f1, String(rate), ...(intro ? ['--intro'] : [])]);
  const got = await webDecode(f1, pass);
  const want = `${pass ? 'SECRET' : 'OPEN'} ${mode}: ${text}`;
  const ok1 = got.length === 1 && got[0] === want;
  if (pass) { const wrong = await webDecode(f1, pass + '!'); if (wrong[0] !== `BADPASS ${mode}: `) { console.log('✗ wrong passphrase accepted', wrong); bad++; } }
  // web → Swift
  const { payload, flags } = await cry.packNote(text, pass, core.MODES[mode].id);
  const f2 = path.join(dir, `web-${mode}.wav`);
  fs.writeFileSync(f2, wav(core.synthesize(payload, flags, mode, { fs: rate, amp: 0.4, intro }), rate));
  const sw = execFileSync(cli, ['decode', f2, pass || '-']).toString().trim();
  const ok2 = sw === want.replace(/^(\w+) (\w+):/, (_, a, b) => `${a} ${b}:`);
  console.log(`${ok1 ? '✓' : '✗'} Swift→web ${mode}   ${ok2 ? '✓' : '✗'} web→Swift ${mode}`);
  if (!ok1) console.log('   web got:', got); if (!ok2) console.log('   swift got:', sw);
  bad += !ok1 + !ok2;
}
// photos: Swift encodes + sends → web hears and unlocks it; pixels must match the web's own decode
{
  const P = await import(path.join(here, '../docs/js/notes-photo.js'));
  const src = fs.readFileSync(path.join(here, '../Tests/ScreechCoreTests/Fixtures/photo-src.rgba')), w = 64, h = 64;
  for (const [mode, pass] of [['quick', 'owl moon'], ['classic', '']]) {
    const f = path.join(dir, `photo-${mode}.wav`);
    execFileSync(cli, ['photo', mode, pass || '-', path.join(here, '../Tests/ScreechCoreTests/Fixtures/photo-src.rgba'), String(w), String(h), f]);
    const { s, rate } = readWav(f); let last = null; const q = [];
    const rx = new P.PhotoReceiver({ passphrase: () => pass, onUpdate: (p) => { last = p; } });
    const dec = new core.NoteDecoder({ sampleRate: rate, onEvent: (e) => { if (e.kind === 'frame' && e.ok && e.version === 2) q.push(rx.feed(e.bytes, e.flags, e.mode)); } });
    dec.push(s); dec.flush(0.5); await Promise.all(q);
    const ref = new Uint8ClampedArray(w * h * 4), enc = P.encodeImage(Uint8ClampedArray.from(src), w, h, { quality: 35 }); enc.bands.forEach((b, i) => P.decodeBand(b, i, enc, ref));
    let md = 0; if (last) for (let i = 0; i < ref.length; i++) md = Math.max(md, Math.abs(ref[i] - last.rgba[i]));
    const ok = last && last.status === 'done' && last.got.size === last.bands && md <= 2;
    console.log(`${ok ? '✓' : '✗'} Swift→web photo ${mode}${pass ? ' (secret)' : ''}: ${last ? last.status + ' ' + last.got.size + '/' + last.bands + ' max pixel diff ' + md : 'nothing'}`);
    bad += !ok;
  }
}
if (bad) { console.log(bad, 'failure(s)'); process.exit(1); }
console.log('all compatible');
