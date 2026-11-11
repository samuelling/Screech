# Screech

Secret notes by sound. Type a note, and your phone plays it as a modem screech; another phone listening nearby decodes it. With a shared passphrase, the note is encrypted before it ever becomes sound.

- **iPhone app:** native Swift (this Xcode project).
- **Web version:** for everyone else, at **https://samuelling.github.io/Screech/** (index.html, css/, js/ and icons/ at the top of the repo). It installs to a phone's home screen and works offline.
- **Same protocol** as the Modem's Secret Notes in [RetroSynths](https://samuelling.github.io/RetroSynths/#oldschool). All three understand each other, and CI checks that on every push.

## How it works

| | |
|---|---|
| **Sound** | Tones between 0.9 and 3.6 kHz, where phone speakers and mics are comfortable. **Sturdy**: MFSK-8 at 75 baud, alternating between two interleaved tone banks so a symbol's echo lands in the other bank. **Quick**: the same at 150 baud. **Classic**: 300-baud FSK whose tone pair hops across four pairs, the real modem sound. |
| **Frame** | Preamble, sync word, header (version, speed, flags, length, CRC-8), payload + CRC-32. |
| **Error correction** | Rate-½ convolutional code (K=7) with a soft-decision Viterbi decoder, whitening, interleaving. A clap or a cough mid-note gets corrected. |
| **Secrecy** | Text is compressed (raw deflate), then sealed with AES-256-GCM. The key is PBKDF2-HMAC-SHA256 of the passphrase (NFC, random 16-byte salt, 200,000 rounds). Packet: version · salt · IV · ciphertext · tag (45 bytes of overhead). The GCM tag proves the note wasn't changed and came from someone with the passphrase. Without a passphrase it's an **open note**, readable by anyone with a decoder. |
| **Receiver** | Listens for all three speeds at once. The iPhone app uses the audio session's *measurement* mode, which switches off echo cancelling, noise suppression and automatic gain. |

**Photos** travel too: tiny (64, 96 or 128 pixels on the long side) and slow, about half a minute to a few minutes. Each 16-pixel stripe is its own frame, so the picture paints in from the top as it arrives, and a stripe that gets garbled shows as a smear while the rest keeps coming. With a passphrase every stripe is encrypted. The format is in [PHOTO.md](PHOTO.md).

A 100-character secret note takes about 12 s at Sturdy and 6 s at Quick. Hold the devices within a foot or two; across a room, strong echoes can garble a note, and the receiver just keeps listening for a resend.

## Layout

```
Screech/Core/      the modem, crypto and deflate, in plain Swift (shared with the Swift package)
Screech/App/       the iPhone app: audio engine, SwiftUI screens
index.html, css/, js/, icons/   the web version (GitHub Pages); js/notes-core.js, notes-crypto.js and notes-photo.js are the shared protocol
Tests/             Swift tests, with fixtures made by the web code (tools/make-fixtures.mjs)
tools/             screech-cli (encode/decode WAVs) and the Swift ↔ web compatibility check
```

## Building

- **iPhone:** open `Screech.xcodeproj`, choose your iPhone, press ▶. The team is already set; bundle ID `com.samuelling.screech`.
- **Tests (macOS or Linux):** `swift test`. On Linux it uses swift-crypto in place of CryptoKit.
- **Compatibility:** `swift build -c release --product screech-cli && node tools/web-decode.mjs --self-test`.

The web protocol files are copies of `apps/oldschool/modem/notes-core.js`, `notes-crypto.js` and `notes-photo.js` from RetroSynths. Keep them identical; the Swift tests' fixtures come from them.

## TestFlight

`.github/workflows/testflight.yml` archives the app and uploads it to App Store Connect. Run it from
Actions → TestFlight → Run workflow, or push a tag like `v1.0.1`. It needs three repository secrets:
`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the text of an App Store Connect API key with the Admin role),
and an app record for `com.samuelling.screech` in App Store Connect.
