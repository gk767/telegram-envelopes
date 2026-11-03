# Integration architecture

## Composer → service → chat

`ChatControllerOpenAttachmentMenu.swift` adds Envelope for a normal private peer. `AttachmentUI` provides the attachment item and icon. `EnvelopeSendScreen` is a native UIKit composer presented through Telegram's controller lifecycle. The hierarchy is created in `loadDisplayNode`; constructing it only in `viewDidLoad` caused an invisible intercepting layer during development and was fixed.

The composer uses the actual logged-in sender and current chat peer. It validates the same normalized amount for both button state and submission. Currency precision uses integer units: nine decimals for the legacy TON/Gram wire currency and six for USDT. `EnvelopeSendJournal` preserves an uncertain create/enqueue operation and its selected emoji for retries.

`EnvelopeService` is the Foundation-only HTTP adapter. The test service reserves the sender's balance, then the client enqueues an ordinary Telegram transport reference. The reference carries an envelope UUID, participant identifiers and optional emoji metadata; it contains no amount, wallet key, endpoint or bearer token. A reference is not sufficient to claim funds.

`ChatMessageBubbleItemNode` recognizes the reference and renders `ChatMessageEnvelopeBubbleContentNode`. The card uses Telegram's free wallpaper bubble material, a 220 pt centered layout, a small illustration and native-style text/button treatment. Chat-list text is reduced to an envelope preview.

## State and permissions

The SQLite ledger is authoritative. Bearer tokens are provisioned by a trusted local operator and bound to one test account. Participants are checked server-side. Only the recipient can claim, only the sender can cancel an unopened envelope. Creation is idempotent; transactions serialize credit/refund. Expiry refunds unopened reserves. The model includes draft, sending and failure UI states separately from the settled server state.

Only the claim that performs a credit returns `openedNow`. The receiver uses it to trigger the opening. `EnvelopeSenderOpenings` remembers outgoing envelopes and consumes a newly observed opened state once on the sender. Polling is approximately five seconds. A server state update controls balances; animation completion never does.

## Rendering and motion

`EnvelopeArtworkView` is shared by composer and card. Layer-backed artwork depicts a white envelope, blue wax seal, hinged rear flap, front pocket and neutral pearl-gray letter. The letter moves behind the pocket; the upper border does not cross its amount. Artwork is rasterized at display scale per layout size rather than redrawn per animation frame.

`EnvelopeOpeningBurstView` places chosen emoji above the chat, starting near the envelope and following separated trajectories in two waves. No selection means no particles. The overlay does not intercept interaction and removes itself after completion. Opening, settling and particle effects respect Reduce Motion.

## Patch scope

The patch includes all four feature modules, their Bazel targets, attachment routing, chat dispatch, chat-list preview, English/Russian resources, the vector attachment icon, service/provisioning tools and Simulator provisioning-profile fixes. `SOURCE-MANIFEST.json` pins the source base and every overlay file hash.

Apply to the exact documented base first. A newer official checkout may require adapting chat dispatch, attachment and build-system hooks; this patch does not claim to apply cleanly to every Telegram release.

## Production boundary

To ship officially, replace the text reference with Telegram's server-recognized media/message type and `EnvelopeService` with a trusted wallet/envelope API authenticated through Telegram. Define custody, settlement, refunds and abuse controls in that service. The Python ledger is a reproducible two-account prototype, not a production financial backend.


## Optional filming aid

`Optional/TouchIndicators/` is distributed separately from the core overlay and patch. Its integration patch adds a Debug-Simulator-only Bazel select and an observer after UIApplication.sendEvent. It draws CALayers without intercepting input. Runtime argument `-DisableDemoTouches` disables it immediately on next launch; reversing that small patch and deleting its module removes it entirely.
