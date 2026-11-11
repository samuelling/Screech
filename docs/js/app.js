// Screech (web). Same protocol as Screech for iPhone and RetroSynths' Secret Notes:
// notes-core.js (modem) and notes-crypto.js (AES-256-GCM + PBKDF2) are shared, byte for byte.
import { MODES, NoteDecoder, synthesize, frameSeconds, decodeBuffer, INTRO_SECONDS, FLAG } from './notes-core.js';
import { packNote, unpackNote, estimateBytes } from './notes-crypto.js';

const $ = (id) => document.getElementById(id);
const MAX = 280;
let ctx = null, captureReady = null;
let listening = null, sending = null, ignoreUntil = 0;
const received = [];

// ---------------------------------------------------------------- status + lights
const setStatus = (s) => { $('status').textContent = s; };
function led(id, on, label) { const el = $(id); el.classList.toggle('on', on); el.setAttribute('aria-label', `${label}: ${on ? 'on' : 'off'}`); }
const LEDS = { MR: 'Microphone listening', CD: 'Carrier detected', RD: 'Receiving data', SD: 'Sending data' };
const setLed = (k, on) => led('led' + k, on, LEDS[k]);

// ---------------------------------------------------------------- audio context (created on first gesture)
function audio() {
  if (!ctx) {
    ctx = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'interactive' });
    captureReady = ctx.audioWorklet ? ctx.audioWorklet.addModule(new URL('./capture.js', import.meta.url)) : Promise.reject(new Error('no AudioWorklet'));
  }
  if (ctx.state !== 'running') ctx.resume().catch(() => {});
  return ctx;
}

// ---------------------------------------------------------------- passphrase
const pass = $('pass'), remember = $('remember');
try { const p = localStorage.getItem('screech.pass'); if (p != null) { pass.value = p; remember.checked = true; } } catch {}
const savePass = () => { try { if (remember.checked) localStorage.setItem('screech.pass', pass.value); else localStorage.removeItem('screech.pass'); } catch {} };
pass.addEventListener('input', () => { savePass(); updateSend(); });
remember.addEventListener('change', savePass);
$('reveal').onclick = () => { const show = pass.type === 'password'; pass.type = show ? 'text' : 'password'; $('reveal').textContent = show ? 'HIDE' : 'SHOW'; $('reveal').setAttribute('aria-label', show ? 'Hide passphrase' : 'Show passphrase'); };
$('reveal').setAttribute('aria-label', 'Show passphrase');

// ---------------------------------------------------------------- tabs
const tabs = [$('tabSend'), $('tabListen')], panels = [$('panelSend'), $('panelListen')];
function selectTab(i, focus) {
  tabs.forEach((t, j) => { t.setAttribute('aria-selected', String(i === j)); t.tabIndex = i === j ? 0 : -1; panels[j].hidden = i !== j; });
  if (focus) tabs[i].focus();
}
tabs.forEach((t, i) => {
  t.onclick = () => selectTab(i);
  t.onkeydown = (e) => { if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { e.preventDefault(); selectTab(1 - i, true); } };
});

// ---------------------------------------------------------------- send
const msg = $('msg');
const mode = () => document.querySelector('input[name=speed]:checked').value;
function updateSend() {
  const n = [...msg.value].length, secret = pass.value.length > 0;
  const secs = frameSeconds(estimateBytes(msg.value, secret), mode()) + ($('intro').checked ? INTRO_SECONDS : 0);
  $('counter').textContent = `${n}/${MAX} CHARS · ~${secs.toFixed(1)} S ON AIR`;
  $('openWarn').hidden = secret;
  const b = $('send');
  if (!sending) { b.textContent = secret ? 'SEND SECRET NOTE' : 'SEND OPEN NOTE'; b.disabled = !msg.value; }
  $('save').disabled = !msg.value;
}
msg.addEventListener('input', updateSend);
document.querySelectorAll('input[name=speed]').forEach(r => r.addEventListener('change', updateSend));
$('intro').addEventListener('change', updateSend);
msg.addEventListener('keydown', (e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); if (!$('send').disabled) $('send').click(); } });

async function render(rate) {
  const m = MODES[mode()];
  const { payload, flags } = await packNote(msg.value, pass.value, m.id);
  return { audio: synthesize(payload, flags, m.key, { fs: rate, amp: 0.7, intro: $('intro').checked }), flags, m };
}
$('send').onclick = async () => {
  if (sending) { stopSending(true); return; }
  const c = audio();
  setStatus(pass.value ? 'ENCRYPTING…' : 'SENDING OPEN NOTE…');
  try {
    const { audio: x, m } = await render(c.sampleRate);
    const buf = c.createBuffer(1, x.length, c.sampleRate); buf.copyToChannel(x, 0);
    const src = c.createBufferSource(); src.buffer = buf; src.connect(c.destination);
    sending = src; ignoreUntil = performance.now() + x.length / c.sampleRate * 1000 + 600;
    src.onended = () => stopSending(false);
    src.start();
    setLed('SD', true);
    const b = $('send'); b.textContent = 'STOP'; b.classList.add('stop'); b.classList.remove('solid'); b.disabled = false;
    setStatus(`SENDING ${m.name.toUpperCase()} · ${Math.round(x.length / c.sampleRate)} S`);
  } catch (err) { setStatus('COULDN\'T SEND: ' + (err.message || err)); }
};
function stopSending(stopped) {
  if (!sending) return;
  try { sending.onended = null; sending.stop(); } catch {}
  sending = null; ignoreUntil = performance.now() + 400;
  setLed('SD', false);
  const b = $('send'); b.classList.remove('stop'); b.classList.add('solid');
  updateSend();
  setStatus(stopped ? 'STOPPED.' : 'SENT.');
}

// save as sound: share the file where the browser can (phones), otherwise download it
$('save').onclick = async () => {
  setStatus('MAKING THE SOUND FILE…');
  try {
    const { audio: x } = await render(44100);
    const blob = new Blob([wav(x, 44100)], { type: 'audio/wav' });
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
    const name = `screech-${pass.value ? 'secret' : 'open'}-note-${stamp}.wav`;
    const file = new File([blob], name, { type: 'audio/wav' });
    if (navigator.canShare && navigator.canShare({ files: [file] }) && matchMedia('(pointer: coarse)').matches) {
      try { await navigator.share({ files: [file], title: 'Screech note' }); setStatus('SHARED.'); return; } catch (e) { if (e.name === 'AbortError') { setStatus('READY.'); return; } }
    }
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
    setStatus('SAVED ' + name.toUpperCase());
  } catch (err) { setStatus('COULDN\'T MAKE THE FILE: ' + (err.message || err)); }
};
function wav(f, rate) {
  const b = new DataView(new ArrayBuffer(44 + f.length * 2)), s = (o, t) => { for (let i = 0; i < t.length; i++) b.setUint8(o + i, t.charCodeAt(i)); };
  s(0, 'RIFF'); b.setUint32(4, 36 + f.length * 2, true); s(8, 'WAVEfmt '); b.setUint32(16, 16, true); b.setUint16(20, 1, true); b.setUint16(22, 1, true);
  b.setUint32(24, rate, true); b.setUint32(28, rate * 2, true); b.setUint16(32, 2, true); b.setUint16(34, 16, true); s(36, 'data'); b.setUint32(40, f.length * 2, true);
  for (let i = 0; i < f.length; i++) b.setInt16(44 + i * 2, Math.max(-32767, Math.min(32767, Math.round(f[i] * 32767))), true);
  return b.buffer;
}

// ---------------------------------------------------------------- listen
$('listen').onclick = () => listening ? stopListening('STOPPED LISTENING.') : startListening();
async function startListening() {
  const c = audio();
  const mm = $('micMsg'); mm.hidden = true;
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { mm.textContent = 'THIS BROWSER CAN\'T USE THE MICROPHONE HERE (IT NEEDS HTTPS).'; mm.hidden = false; return; }
  setStatus('ASKING FOR THE MICROPHONE…');
  let stream;
  try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 } }); }
  catch (err) {
    mm.textContent = err && err.name === 'NotAllowedError' ? 'MICROPHONE ACCESS WAS DENIED. ALLOW IT IN YOUR BROWSER\'S SITE SETTINGS, THEN TRY AGAIN. SCREECH NEVER RECORDS OR SAVES AUDIO.' : 'NO MICROPHONE AVAILABLE.';
    mm.hidden = false; setStatus('COULDN\'T LISTEN.'); return;
  }
  try { await captureReady; } catch { setStatus('THIS BROWSER IS TOO OLD FOR LISTENING.'); stream.getTracks().forEach(t => t.stop()); return; }
  const src = c.createMediaStreamSource(stream);
  const cap = new AudioWorkletNode(c, 'screech-capture', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1] });
  const mute = c.createGain(); mute.gain.value = 0;
  src.connect(cap); cap.connect(mute); mute.connect(c.destination);
  const dec = new NoteDecoder({ sampleRate: c.sampleRate, onEvent: (e) => onEvent(e, 'mic') });
  const spec = new Spectrum(c.sampleRate);
  let lv = -90;
  cap.port.onmessage = (ev) => {
    const x = ev.data; dec.push(x);
    for (const row of spec.process(x)) fall.push(row);
    let p = 0; for (let i = 0; i < x.length; i++) p += x[i] * x[i];
    lv = Math.max(10 * Math.log10(p / x.length + 1e-12), lv - 1.5);
    meter(lv);
  };
  listening = { stream, src, cap, mute };
  const track = stream.getAudioTracks()[0]; if (track) track.onended = () => stopListening('MICROPHONE DISCONNECTED.');
  const b = $('listen'); b.textContent = 'STOP LISTENING'; b.classList.remove('solid'); b.classList.add('amber'); b.setAttribute('aria-pressed', 'true');
  setLed('MR', true);
  setStatus('LISTENING… PLAY A NOTE NEAR THE MIC.');
  try { if ('wakeLock' in navigator) listening.lock = await navigator.wakeLock.request('screen'); } catch {}
}
function stopListening(msg) {
  if (!listening) return;
  const L = listening; listening = null;
  try { L.cap.port.postMessage('stop'); L.cap.port.onmessage = null; L.src.disconnect(); L.cap.disconnect(); L.mute.disconnect(); } catch {}
  L.stream.getTracks().forEach(t => t.stop());
  try { L.lock && L.lock.release(); } catch {}
  const b = $('listen'); b.textContent = 'LISTEN'; b.classList.add('solid'); b.classList.remove('amber'); b.setAttribute('aria-pressed', 'false');
  setLed('MR', false); setLed('CD', false); setLed('RD', false); showProgress(null); meter(null);
  setStatus(msg);
}
function meter(db) {
  const f = $('meterFill');
  if (db == null) { f.style.width = '0'; $('meterTxt').textContent = 'OFF'; $('meter').setAttribute('aria-valuenow', '-70'); return; }
  f.style.width = Math.max(0, Math.min(1, (db + 70) / 70)) * 100 + '%'; f.classList.toggle('hot', db > -6);
  $('meterTxt').textContent = `${Math.round(db)} dB`; $('meter').setAttribute('aria-valuenow', String(Math.round(db)));
}
function showProgress(p) {
  $('progress').hidden = p == null; setLed('RD', p != null);
  if (p != null) { $('progressFill').style.width = p * 100 + '%'; $('progressTxt').textContent = `RECEIVING… ${Math.round(p * 100)}%`; }
}
function onEvent(e, source) {
  if (source === 'mic' && performance.now() < ignoreUntil) return;          // don't decode our own note
  if (e.kind === 'carrier') { setLed('CD', e.on); if (!e.on) showProgress(null); }
  else if (e.kind === 'header') { showProgress(0); setStatus(e.flags & FLAG.ENCRYPTED ? 'RECEIVING A SECRET NOTE…' : 'RECEIVING AN OPEN NOTE…'); }
  else if (e.kind === 'progress') showProgress(e.frac);
  else if (e.kind === 'frame') {
    showProgress(null);
    if (e.ok) accept(e.bytes, e.flags, MODES[e.mode], source);
    else if (e.why === 'crc') setStatus('GARBLED NOTE. MOVE CLOSER, TURN THE VOLUME UP, OR TRY STURDY.');
  }
}
async function accept(bytes, flags, m, source) {
  if (flags & FLAG.ENCRYPTED) setStatus('DECRYPTING…');
  const st = await unpackNote(bytes, flags, pass.value, m.id);
  const n = { date: new Date(), m, source, flags, bytes, st };
  received.unshift(n); drawNotes();
  setStatus(describe(st.status));
  if (navigator.vibrate) navigator.vibrate(st.status === 'badpass' ? [60, 60, 60] : 40);
}
const describe = (s) => ({ secret: '✓ SECRET NOTE (PASSPHRASE MATCHED)', open: 'OPEN NOTE RECEIVED (NOT SECRET)', locked: '🔒 SECRET NOTE. ENTER THE PASSPHRASE TO READ IT.', badpass: '✗ WRONG PASSPHRASE.', garbled: 'GARBLED NOTE.' }[s]);
function drawNotes() {
  const ol = $('notes'); ol.innerHTML = '';
  $('emptyMsg').hidden = received.length > 0; $('clear').hidden = !received.length;
  for (const n of received) {
    const li = document.createElement('li');
    const meta = document.createElement('p'); meta.className = 'meta';
    meta.textContent = `${n.date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })} · ${n.m.name.toUpperCase()} · ${n.source === 'mic' ? 'MIC' : 'FILE'}`;
    const kind = document.createElement('p'); kind.className = 'kind';
    const k = n.st.status;
    kind.textContent = { secret: '✓ SECRET', open: 'OPEN NOTE (NOT SECRET)', locked: '🔒 SECRET NOTE. ENTER THE PASSPHRASE ABOVE, THEN:', badpass: '✗ WRONG PASSPHRASE.', garbled: 'GARBLED.' }[k];
    if (k === 'open' || k === 'locked') kind.classList.add('open'); if (k === 'badpass' || k === 'garbled') kind.classList.add('bad');
    li.append(meta, kind);
    const row = document.createElement('div'); row.className = 'row';
    if (k === 'secret' || k === 'open') {
      const t = document.createElement('p'); t.className = 'text'; t.textContent = n.st.text; li.append(t);
      const cp = document.createElement('button'); cp.type = 'button'; cp.textContent = 'COPY'; cp.setAttribute('aria-label', 'Copy note text');
      cp.onclick = async () => { try { await navigator.clipboard.writeText(n.st.text); setStatus('COPIED.'); } catch { setStatus('COULDN\'T COPY.'); } };
      row.append(cp);
    } else if (k === 'locked' || k === 'badpass') {
      const tr = document.createElement('button'); tr.type = 'button'; tr.className = 'tbtn amber'; tr.textContent = k === 'locked' ? 'TRY PASSPHRASE' : 'TRY AGAIN';
      tr.onclick = async () => { n.st = await unpackNote(n.bytes, n.flags, pass.value, n.m.id); drawNotes(); setStatus(describe(n.st.status)); };
      row.append(tr);
    }
    li.append(row); ol.append(li);
  }
}
$('clear').onclick = () => { received.length = 0; drawNotes(); setStatus('CLEARED.'); };

// decode a sound file
$('decodeBtn').onclick = () => $('file').click();
$('file').onchange = async () => {
  const f = $('file').files[0]; $('file').value = ''; if (!f) return;
  setStatus('DECODING ' + f.name.toUpperCase() + '…');
  try {
    const c = audio();
    const ab = await c.decodeAudioData(await f.arrayBuffer());
    const x = new Float32Array(ab.length);
    for (let ch = 0; ch < ab.numberOfChannels; ch++) { const d = ab.getChannelData(ch); for (let i = 0; i < x.length; i++) x[i] += d[i] / ab.numberOfChannels; }
    const frames = decodeBuffer(x, ab.sampleRate);
    const good = frames.filter(e => e.ok);
    for (const e of good) await accept(e.bytes, e.flags, MODES[e.mode], 'file');
    if (!good.length) setStatus(frames.some(e => e.why === 'crc') ? 'THAT FILE HOLDS A NOTE, BUT IT\'S TOO DAMAGED TO READ.' : 'NO NOTE FOUND IN THAT FILE.');
  } catch (err) { setStatus('COULDN\'T OPEN THAT FILE.'); }
};

// ---------------------------------------------------------------- waterfall (Goertzel bank, like the iPhone app)
class Spectrum {
  constructor(fs, bands = 48, lo = 600, hi = 3600, block = 0.03) {
    this.L = Math.max(64, Math.floor(fs * block)); this.bands = bands;
    this.k = Array.from({ length: bands }, (_, i) => 2 * Math.cos(2 * Math.PI * (lo + (hi - lo) * i / (bands - 1)) / fs));
    this.w = Float32Array.from({ length: this.L }, (_, i) => 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (this.L - 1)));
    this.buf = new Float32Array(this.L); this.n = 0;
  }
  process(x) {
    const rows = [];
    for (let j = 0; j < x.length; j++) {
      this.buf[this.n++] = x[j];
      if (this.n === this.L) {
        const row = new Float32Array(this.bands);
        for (let b = 0; b < this.bands; b++) {
          let a = 0, c = 0; const k = this.k[b];
          for (let i = 0; i < this.L; i++) { const s = this.buf[i] * this.w[i] + k * a - c; c = a; a = s; }
          const p = a * a + c * c - k * a * c, db = 10 * Math.log10(Math.max(p, 1e-12) / (this.L * this.L) * 4);
          row[b] = Math.max(0, Math.min(1, (db + 80) / 70));
        }
        rows.push(row); this.n = 0;
      }
    }
    return rows;
  }
}
const fall = (() => {
  const cv = $('fall'), g = cv.getContext('2d'), W = cv.width, H = cv.height;
  g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
  const col = g.createImageData(1, 48);
  return {
    push(row) {
      g.drawImage(cv, -2, 0);                              // scroll left
      for (let b = 0; b < 48; b++) {
        const v = row[b], o = (47 - b) * 4;                // low frequencies at the bottom
        col.data[o] = Math.max(0, Math.min(255, (v - 0.65) * 3 * 255)); col.data[o + 1] = Math.min(255, v * 1.5 * 255);
        col.data[o + 2] = Math.max(0, Math.min(255, (v - 0.5) * 2 * 160)); col.data[o + 3] = 255;
      }
      const tmp = fall.tmp || (fall.tmp = Object.assign(document.createElement('canvas'), { width: 1, height: 48 }));
      tmp.getContext('2d').putImageData(col, 0, 0);
      g.imageSmoothingEnabled = true; g.drawImage(tmp, W - 2, 0, 2, H);
      cv.setAttribute('aria-label', listening && $('ledCD').classList.contains('on') ? 'Spectrogram: a note is coming in' : 'Spectrogram of the microphone');
    },
  };
})();

// ---------------------------------------------------------------- help
const help = $('help');
$('helpBtn').onclick = () => { help.showModal(); $('helpClose').focus(); };
$('helpClose').onclick = () => help.close();
help.addEventListener('click', (e) => { if (e.target === help) help.close(); });

// ---------------------------------------------------------------- offline (installable to the home screen)
if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js').catch(() => {});

updateSend();
// test hook (used by the automated tests only)
window.__screech = { onEvent, accept, received, render };
