# Validation

Baseline: `fb0e62ba8a147f0821da6aa63c09da7d79a10111`, build 10016, 3 November 2026.

- Full `Telegram/Telegram` Simulator build succeeded with Xcode 27.2 and the explicit version override (54.411 seconds for the incremental build; not a clean-build timing).
- Installed on two dedicated iOS 26.5 Simulators; installed TelegramUI framework hashes matched the fresh application. Existing account data was preserved.
- Re-ran the packaged source before upload: 46 Swift model/service tests and 11 Python ledger/HTTP tests passed. Previous full-checkout checks: 64 static integration checks and 13 Swift files parsed.
- Verified the patch against the exact base in an isolated index, then compared all 39 applied files byte-for-byte with the overlay. Scanned the upload for the local API keys, account IDs and operator tokens; none were present.
- Two real Telegram test accounts were provisioned on one ledger. An actual envelope reached opened; its test recording was reviewed locally and is not included in this repository.
- The user confirmed the current integrated emoji selector and light-blue circular outlines. Its final selection interaction was not captured in the retained recording.
- Shared opening component frames were reviewed separately: 109 frames, median interval 16.7 ms, no heuristic gap/jump flags in that preview. This is not a physical-device frame-rate guarantee.

## Reproduce before submission

1. Send Gram and USDT, including fractional amounts and trailing whitespace input.
2. Receive with the addressed second account; confirm one credit and no duplicate opening credit.
3. Verify sender cannot claim and a third account cannot access the envelope.
4. Cancel, expire, lose connectivity, retry and restart the app; confirm no extra debit/credit.
5. Select None, one emoji and three emoji; verify Reduce Motion and keyboard transitions.
6. Record the current full composer → send → recipient claim → sender opening flow. Only a component animation preview is included. Add an approved full-app recording from build 10016 for the public submission.

## Known limits

Balances are test balances, not on-chain funds. Both users need this modified client and the same service. Sender opening follows polling rather than push. A crash in the narrow create/enqueue recovery window can leave two chat references to one UUID; service reserve/credit remains idempotent. There has been no signed physical-iPhone build or production wallet integration verification.


## Optional filming build 10018

The optional touch module was added separately in Optional/TouchIndicators; the original core patch and its 39-file manifest are unchanged. Full Telegram build 10018 succeeded in 51.312s and was installed on both dedicated Simulators, preserving account data. The installed main executable was compared against the fresh IPA, since this module links into the application rather than TelegramUI. SDK compilation checked the Application hook both with and without the module. The low-load wrapper was checked in default-off and explicit opt-in modes.

The user selected the soft translucent circle, then requested a slightly darker fill and a release wave starting closer to the center with unchanged maximum size. The final version was accepted on the running Simulator. A private local recording was inspected for the held drag, touch release and return to an interactive chat; that recording is not included or uploaded. Physical-device and production wallet claims are unchanged.
