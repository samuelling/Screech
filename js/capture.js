// Microphone capture: hands the main thread 2048-sample blocks to decode.
class Capture extends AudioWorkletProcessor {
  constructor() { super(); this.buf = new Float32Array(2048); this.i = 0; this.alive = true; this.port.onmessage = (e) => { if (e.data === 'stop') this.alive = false; }; }
  process(inputs) {
    if (!this.alive) return false;
    const ch = inputs[0] && inputs[0][0];
    if (ch) for (let k = 0; k < ch.length; k++) { this.buf[this.i++] = ch[k]; if (this.i === this.buf.length) { this.port.postMessage(this.buf, [this.buf.buffer]); this.buf = new Float32Array(2048); this.i = 0; } }
    return true;
  }
}
registerProcessor('screech-capture', Capture);
