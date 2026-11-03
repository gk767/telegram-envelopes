# Envelopes for Telegram iOS

Send money as a native envelope in a private chat. The recipient opens it to reveal the amount; the sender sees the envelope open too.

A working Telegram-iOS feature prototype, implemented in Swift and UIKit with a small Python/SQLite test service. This is an unofficial proposal for Telegram Designers, not an official Telegram release.

## Demo

[▶ Watch the opening animation and emoji](Media/opening-effect.mp4)

<img src="Media/opening-preview.png" width="440" alt="Shared envelope artwork and opening animation preview">

This clip is an isolated preview of the shared rendering component from build 10013, with no private chat content. Core source is build 10016; the optional filming build is 10018. The integrated picker now uses light-blue circular selection outlines. A final full-app send/open video will be added separately before submitting to Telegram Designers. The current animation preview does not show the entire two-account workflow.

## What it does

- Open a private chat → attachment menu → Envelope.
- Choose Gram or USDT, enter an amount and an optional message.
- Choose up to three opening emoji, or None for a simple opening.
- Send a compact, centered card with Telegram's translucent gift-style background.
- Only the addressed recipient can open it. Opening credits the test balance once.
- Both participants see the letter emerge and any chosen emoji spread from the envelope over the chat.
- The sender can cancel an unopened envelope. Expired envelopes refund the reserve.
- Keyboard-aware composition, localized English/Russian labels, and Reduce Motion support.

## Code

`Source/` mirrors the relevant paths in the target Telegram checkout. It contains **39 source, resource, test and build files**, including the complete changed integration files. `changes.patch` applies the same implementation to the pinned base; use the patch or the source overlay, not both.

- [Foundation models, service adapter and tests](Source/submodules/TelegramEnvelopes)
- [Native composer](Source/submodules/TelegramUI/Components/Envelopes/EnvelopeDemoScreen)
- [Shared artwork and animation](Source/submodules/TelegramUI/Components/Envelopes/EnvelopeRendering)
- [Chat card and emoji burst](Source/submodules/TelegramUI/Components/Chat/ChatMessageEnvelopeBubbleContentNode)
- [Test ledger, provisioning and pairing tools](Source/tools)
- [Integration architecture](Documentation/INTEGRATION.md)
- [Build and two-account setup](Documentation/BUILD-AND-RUN.md)
- [Validation and remaining limits](Documentation/VALIDATION.md)

## Optional filming overlay

[Optional/TouchIndicators](Optional/TouchIndicators) contains the removable soft touch circle and light release wave. It has its own source, Bazel target and integration/reversal patch. It is disabled by default and can link only into Debug Simulator builds. The core `changes.patch` and `Source/` stay independent of this filming aid. See the folder README to enable or remove it.

## Try it

Use macOS, Xcode and an Apple Silicon iPhone Simulator. The target checkout pins **Xcode 27.1 / macOS 27**; the full application was also built with Xcode 27.2 using an explicit version override, on an iOS 26.5 Simulator.

```sh
git clone https://github.com/gk767/telegram-envelopes.git
git clone https://github.com/developer6758/Telegram-iOS.git Telegram-Envelopes
cd Telegram-Envelopes
git switch -c feature/envelopes fb0e62ba8a147f0821da6aa63c09da7d79a10111
git apply --check ../telegram-envelopes/changes.patch
git apply --index ../telegram-envelopes/changes.patch
```

Continue with [BUILD-AND-RUN.md](Documentation/BUILD-AND-RUN.md) for dependencies, your own API configuration, building and connecting both accounts to one ledger. This repository is an integration package, not a standalone Xcode app.

## Implementation status

The native UI and cross-account test flow are implemented. **Balances are simulated; no cryptocurrency is transferred.** Gram is the requested display label; `TON` remains the first currency's legacy wire identifier. This does not claim that Gram is an available production asset.

Both participants need the modified client and access to the same test service. Ordinary Telegram clients show the text transport reference instead of the native card. Production adoption requires an official message/media type, Telegram authentication and a real wallet settlement API. These boundaries are documented explicitly rather than presented as completed infrastructure.

## Co-authors

- [gk767](https://github.com/gk767) · [@ofthalot](https://t.me/ofthalot)
- [developer6758](https://github.com/developer6758) · [@vivapot](https://t.me/vivapot)

## License and attribution

GPL-2.0-or-later; see [LICENSE](LICENSE) and [NOTICE](NOTICE). Telegram integration code retains its upstream ownership. The original gift-card reference was [imogendes/make-an-offer](https://github.com/imogendes/make-an-offer). This repository does not include Telegram API credentials, wallet tokens, account databases or application binaries.
