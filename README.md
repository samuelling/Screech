# Screech

Secret notes by sound. Type a note, and your phone plays it as a modem screech; another phone listening nearby decodes it. With a shared passphrase, the note is encrypted before it ever becomes sound.

- **iPhone app:** native Swift (this Xcode project).
- **Web version:** for everyone else, at **https://samuelling.github.io/Screech/** (the `docs/` folder). It installs to a phone's home screen and works offline.
- **Same protocol** as the Modem's Secret Notes in [RetroSynths](https://samuelling.github.io/RetroSynths/#oldschool). All three understand each other, and CI checks that on every push.

## How it works

| | |
|---|---|
| **Sound** | Tones between 0.9 and 3.6 kHz, where phone speakers and mics are comfortable. **Sturdy**: MFSK-8 at 75 baud, alternating between two interleaved tone banks so a symbol's echo lands in the other bank. **Quick**: the same at 150 baud. **Classic**: 300-baud FSK whose tone pair hops across four pairs, the real modem sound. |
| **Frame** | Preamble, sync word, header (version, speed, flags, length, CRC-8), payload + CRC-32. |
| **Error correction** | Rate-½ convolutional code (K=7) with a soft-decision Viterbi decoder, whitening, interleaving. A clap or a cough mid-note gets corrected. |
| **Secrecy** | Text is compressed (raw deflate), then sealed with AES-256-GCM. The key is PBKDF2-HMAC-SHA256 of the passphrase (NFC, random 16-byte salt, 200,000 rounds). Packet: version · salt · IV · ciphertext · tag (45 bytes of overhead). The GCM tag proves the note wasn't changed and came from someone with the passphrase. Without a passphrase it's an **open note**, readable by anyone with a decoder. |
| **Receiver** | Listens for all three speeds at once. The iPhone app uses the audio session's *measurement* mode, which switches off echo cancelling, noise suppression and automatic gain. |

A 100-character secret note takes about 12 s at Sturdy and 6 s at Quick. Hold the devices within a foot or two; across a room, strong echoes can garble a note, and the receiver just keeps listening for a resend.

## Layout

```
Screech/Core/      the modem, crypto and deflate, in plain Swift (shared with the Swift package)
Screech/App/       the iPhone app: audio engine, SwiftUI screens
docs/              the web version (GitHub Pages); js/notes-core.js and js/notes-crypto.js are the shared protocol
Tests/             Swift tests, with fixtures made by the web code (tools/make-fixtures.mjs)
tools/             screech-cli (encode/decode WAVs) and the Swift ↔ web compatibility check
```

## Building

- **iPhone:** open `Screech.xcodeproj`, choose your iPhone, press ▶. The team is already set; bundle ID `com.samuelling.screech`.
- **Tests (macOS or Linux):** `swift test`. On Linux it uses swift-crypto in place of CryptoKit.
- **Compatibility:** `swift build -c release --product screech-cli && node tools/web-decode.mjs --self-test`.

The web protocol files are copies of `apps/oldschool/modem/notes-core.js` and `notes-crypto.js` from RetroSynths. Keep them identical; the Swift tests' fixtures come from them.
