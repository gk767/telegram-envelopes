# Build and run

## 1. Apply the implementation

Follow the clone, checkout and patch commands in the README. Keep an existing personal Telegram checkout separate. Read the target checkout's AGENTS.md and CLAUDE.md before changing or installing anything.

From the patched Telegram checkout:

```sh
git config submodule.submodules/TgVoipWebrtc/tgcalls.url https://github.com/TelegramMessenger/tgcalls.git
git config submodule.submodules/rlottie/rlottie.url https://github.com/TelegramMessenger/rlottie.git
git submodule update --init --recursive --jobs 2
cp build-system/template_minimal_development_configuration.json "$HOME/envelopes-development.json"
chmod 600 "$HOME/envelopes-development.json"
```

Complete Xcode's initial setup and license acceptance. Obtain your own `api_id` and `api_hash` at https://my.telegram.org/apps. Fill those fields, a unique `bundle_id`, and your Apple Development `team_id` in the private configuration. Keep `is_internal_build` as `"true"` and `is_appstore_build` as `"false"`. Never commit the filled configuration.

## 2. Build the complete application

Generate the project with the version pinned in `versions.json`:

```sh
python3 build-system/Make/Make.py \
  --cacheDir="$HOME/telegram-bazel-cache" generateProject \
  --buildNumber=10016 --configurationPath="$HOME/envelopes-development.json" \
  --xcodeManagedCodesigning --disableProvisioningProfiles --disableExtensions
```

Select **Telegram**, **Debug**, and an installed **iPhone Simulator**, then Cmd-R. This is a full Telegram build. Do not use an iPhone device destination for this unsigned Simulator setup. Xcode 27.2 was tested with `--overrideXcodeVersion` before `--cacheDir`; other mismatches are unverified.

For a lower-load CLI build, close Xcode first and use the supplied one-job Bazel wrapper from the Telegram checkout:

```sh
chmod +x ../telegram-envelopes/Scripts/bazel-low-load.py
nice -n 15 python3 build-system/Make/Make.py \
  --bazel="$PWD/../telegram-envelopes/Scripts/bazel-low-load.py" \
  --cacheDir="$HOME/telegram-bazel-cache" build \
  --buildNumber=10016 --configuration=debug_sim_arm64 \
  --configurationPath="$HOME/envelopes-development.json" --xcodeManagedCodesigning
```

The wrapper limits Bazel to one action and Swift to one compiler job and disables extensions/profiles for this build. The first full build can still consume substantial memory and disk. Leave at least 15 GiB free. Do not run a second build concurrently. Build results are under `bazel-bin/Telegram/`; install the fresh Simulator app in a dedicated Simulator. Do not uninstall an existing app to update it, because that deletes account data. Follow the checkout's whole-app update guidance and verify the installed TelegramUI framework hash if an old interface persists.

## 3. Connect two accounts on one Mac

Use two dedicated Simulators with the same modified client and two Telegram accounts. Log in normally. In each, open the private chat with the other account, open Envelope once, then close it. This writes the local setup context. No sender/recipient role switch is used.

Get UDIDs with `xcrun simctl list devices booted`. Set `SENDER_SIM`, `RECEIVER_SIM`, and `BUNDLE` to your actual values. Create a private service directory outside either Git checkout:

```sh
ENVELOPE_DATA="$HOME/.local/share/telegram-envelopes"
mkdir -p "$ENVELOPE_DATA"
chmod 700 "$ENVELOPE_DATA"

python3 tools/configure_envelope_simulator.py --simulator "$SENDER_SIM" --bundle "$BUNDLE" \
  --database "$ENVELOPE_DATA/ledger.sqlite" --config "$ENVELOPE_DATA/operator.json"
python3 tools/configure_envelope_simulator.py --simulator "$RECEIVER_SIM" --bundle "$BUNDLE" \
  --database "$ENVELOPE_DATA/ledger.sqlite" --config "$ENVELOPE_DATA/operator.json"

python3 tools/envelope_demo_server.py --database "$ENVELOPE_DATA/ledger.sqlite" serve
```

Run sender provisioning first: a newly provisioned sender gets 1000 units per currency, a new recipient gets zero. Existing balances and tokens are preserved. Both commands must use the same database and operator file. Leave the server Terminal open. Reopen both chats/forms. It binds to loopback on port 8787; there are no production wallet funds.

Send 15 Gram with a message and optionally ✨ / 💙. Keep the sender's card visible and press Open Envelope only on the receiver. The sender polls roughly every five seconds, so its opening can follow with a short delay. Reopening must not credit again. Both clients must reach the same service; two separate databases do not synchronize.

For two Macs, use `tools/pair_envelope_simulator.py`: export only the recipient configuration from the sender operator file, privately transfer it, use an SSH loopback tunnel to port 8787, then install that single-account configuration on the receiver. Its `--help` describes export/install arguments. Never transfer the operator file or expose this test service directly to the Internet.

## Tests

From the patched full checkout:

```sh
swift test --package-path submodules/TelegramEnvelopes --jobs 1
python3 -m unittest discover -s tools -p test_envelope_demo_server.py
python3 tools/check_envelopes.py
```

The Foundation package and Python service tests can also run from this submission's `Source/` directory. The static integration checker requires the full patched checkout. Passing package tests does not replace the full iOS build or manual UI checks.


## Optional touch circles for recording

The core build has no touch overlay. To reproduce filming build 10018, follow [Optional/TouchIndicators](../Optional/TouchIndicators/README.md), then use the low-load CLI command above with `ENVELOPE_TOUCH_INDICATORS=1` before `nice` and `--buildNumber=10018`. This is optional; remove its integration patch to keep the product code alone.
