# Optional touch indicators for filming

This isolated UIKit module is a filming aid, not part of the envelope product UI. It draws a 44pt translucent neutral-gray circle with a thin white rim, follows a held touch, and emits one light release wave from near the center. The circle fades out over 0.28s; the wave fades out over 0.42s. Reduce Motion uses a short fade without expansion. Cancellation and app deactivation clean up layers.

It observes real UIApplication touch events after `super.sendEvent`. It adds only CALayers to the originating window: no overlay views, hit-test changes, recognizers, method swizzling, event injection, logging or network access. There is no persistent rendering timer. System keyboard interactions delivered outside this application's windows are not guaranteed to appear.

## Install after the core envelope patch

From the patched Telegram checkout, with this submission next to it:

```sh
cp -R ../telegram-envelopes/Optional/TouchIndicators Telegram/DemoTouchIndicators
git apply --check ../telegram-envelopes/Optional/TouchIndicators/integration.patch
git apply ../telegram-envelopes/Optional/TouchIndicators/integration.patch
```

The integration patch adds one optional dependency and the Application.sendEvent observer. A Bazel flag defaults to false and selects the module only for **Debug Simulator** builds. Device and release builds do not link it, even if the flag is requested.

To build using the supplied low-load wrapper, prefix the documented Make.py build command with `ENVELOPE_TOUCH_INDICATORS=1` and use build number 10018. The wrapper then passes `--//Telegram:enableDemoTouchIndicators`. Without that environment variable the optional module remains disabled. The rest of the envelope feature does not depend on this folder.

## Disable without rebuilding

Terminate the dedicated app, then launch with the argument:

```sh
xcrun simctl terminate "$SIM" "$BUNDLE"
xcrun simctl launch "$SIM" "$BUNDLE" -DisableDemoTouches
```

The argument is read at process startup. Terminate and relaunch without it to restore indicators in an enabled filming build. No preference or account data is changed.

## Remove completely

Apply `integration.patch` in reverse from the Telegram checkout, then delete only `Telegram/DemoTouchIndicators`. The reverse patch removes the flag, dependency and Application hook together. Do not remove the main envelope modules or reapply the core changes.patch.

```sh
git apply --reverse --check ../telegram-envelopes/Optional/TouchIndicators/integration.patch
git apply --reverse ../telegram-envelopes/Optional/TouchIndicators/integration.patch
```

## Validate

In a dedicated Simulator, hold and drag in a chat, release, open and close the composer. Verify that the disk follows the actual touch with no persistent trail, the wave clears within 0.42s, and controls remain interactive. Check Reduce Motion, cancellation and app deactivation. Record real Simulator frames; package/model tests do not prove touch delivery or visual smoothness.

GPL-2.0-or-later, like the submission. No chat recordings or credentials are included in this folder.
