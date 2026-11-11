import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            Phosphor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("HOW TO SCREECH").font(Phosphor.mono(.title3, weight: .black)).phosphor().accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("CLOSE") { dismiss() }.buttonStyle(TermButtonStyle())
                    }
                    section("1. AGREE ON A PASSPHRASE", "Pick one together, in person. Both phones type it into KEY>. It never travels over the sound; only the scrambled note does.")
                    section("2. LISTEN", "The receiver opens LISTEN and taps LISTEN. The phone hears through its microphone. Nothing is recorded or saved.")
                    section("3. SEND", "The sender types a note (up to 280 characters), holds the phone a few inches from the receiver, volume up, and taps SEND. The receiver's lights go CD (carrier) then RD (receiving), and the note appears.")
                    section("PHOTOS", "SEND › PHOTO, choose a picture, pick a size and detail. Photos travel tiny (64–128 pixels) and take from about half a minute to a few minutes. On the other phone the picture paints in from the top, one 16-pixel stripe at a time, like a download on an old modem. A stripe that gets garbled shows as a smear and the rest keeps coming. With a passphrase, every stripe is encrypted.")
                    section("SPEEDS", "STURDY: slow chiming tones, the most reliable.\nQUICK: half the time, wants a quieter room.\nCLASSIC: the real 300-baud modem screech.\nThe receiver hears all three automatically.")
                    section("IS IT REALLY SECRET?", "Yes, with a passphrase. The note is encrypted with AES-256 before it becomes sound, using a key made from your passphrase (PBKDF2, 200,000 rounds). Anyone can record the screech, but without the passphrase it's noise, and a tampered note won't open.\nWithout a passphrase it's an OPEN NOTE: anyone with a decoder can read it.\nPick a passphrase that's hard to guess; a few unrelated words work well.")
                    section("NOTES AS SOUND FILES", "SAVE AS SOUND makes an audio file of the note that you can text or email. The other person opens it in Screech (Share › Screech, or DECODE A SOUND FILE). Notes survive most voice-memo compression.")
                    section("IF A NOTE DOESN'T ARRIVE", "Move closer, turn the volume up, cut background noise, or switch to STURDY, then send again. The receiver keeps listening. Across a room, echoes can garble a note.")
                    section("FRIENDS WITHOUT AN IPHONE", "Screech also runs in any browser at samuelling.github.io/Screech, and it talks to the Modem in RetroSynths. All of them understand each other.")
                    section("THE LIGHTS", "MR: microphone listening · CD: carrier detected · RD: receiving data · SD: sending data. Named after the lights on old external modems.")
                }
                .padding(20)
            }
            Scanlines().ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }
    func section(_ t: String, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(Phosphor.mono(.callout, weight: .bold)).phosphor().accessibilityAddTraits(.isHeader)
            Text(b).font(Phosphor.mono(.callout)).phosphor(Phosphor.green.opacity(0.85))
        }
    }
}
