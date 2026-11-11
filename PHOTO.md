# Screech photo format

Photos travel as a train of ordinary modem frames (same preamble, sync, FEC and CRC as text notes), with the
frame-header **version = 2**. Version-1 receivers ignore them. Order on air:

```
header · stripe 0 · stripe 1 · … · stripe N-1 · header (again)        0.15 s of silence between frames
```

All frames of a photo use one speed. The header is repeated at the end so a receiver that missed the first one
can still decode the stripes it buffered.

## Frame payloads

Frame-header flags: bit 0 = encrypted (bit 1 unused, 0).

**Header** (kind 0), 11 bytes, + 24 when encrypted:

| byte | field |
|---|---|
| 0 | kind = 0 |
| 1–2 | photo id (u16 BE, random per photo) |
| 3 | codec version = 1 |
| 4–5 | width (u16 BE) |
| 6–7 | height (u16 BE) |
| 8 | quality 1–100 |
| 9 | stripe count = ceil(height / 16) |
| 10 | 0 = colour (4:2:0), 1 = greyscale |
| 11–26 | *(encrypted)* PBKDF2 salt (16) |
| 27–34 | *(encrypted)* nonce prefix (8) |

**Stripe** (kind 1): `[1, id hi, id lo, stripe index] + body`.
Plain: body = the stripe's bitstream. Encrypted: body = AES-256-GCM(key, nonce = prefix ‖ u32 BE(index),
additional data = the whole header payload ‖ [index]) = ciphertext ‖ 16-byte tag.
Key = PBKDF2-HMAC-SHA256(NFC passphrase, salt, 200 000 iterations), as for text notes.

## Stripe bitstream (codec version 1)

Baseline-JPEG-like. The image is padded to multiples of 16 by repeating the last column/row. Colour: JFIF YCbCr,
chroma averaged 2×2 (4:2:0). Each stripe is one row of 16×16 macroblocks; each macroblock is
`Y(0,0) Y(8,0) Y(0,8) Y(8,8) Cb Cr` (greyscale: the four Y blocks only).

Per 8×8 block: level-shift by −128, 2-D DCT-II (orthonormal), divide by the quantiser and round, zigzag order.
Quantisers: the JPEG Annex K luminance / chrominance tables scaled by libjpeg's rule
(`s = q < 50 ? floor(5000/q) : 200 − 2q`, `t = clamp(floor((base·s + 50)/100), 1, 255)`).

Bits, MSB first, Exp-Golomb order 0 (`ue`), signed `se(v) = ue(v > 0 ? 2v−1 : −2v)`:

```
se(DC − previous DC of the same component in this stripe)      (predictors start at 0 each stripe)
bit: 1 if any AC coefficient is non-zero
for each non-zero AC coefficient in zigzag order:
    ue(zeros since the previous one) · ue(|level| − 1) · sign bit (1 = negative) · last bit (1 = last one)
```

The stripe's last byte is zero-padded. A stripe that fails its CRC or doesn't parse is shown as a smear of the row
above it with a little static.
