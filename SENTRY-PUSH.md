# Sentry phone alerts

This app registers its Apple push token with comma. The relay converts it to a Firebase token and Firebase delivers the alert through Apple, so the app needs no Firebase SDK. It uses the existing Galaxy phone-subscription API and reports the new per-comma relay enrollment status. Hosted v2 delivery requires the companion StarPilot and Worker PRs; old private v1 pilots remain compatible. Nate can use his existing Apple developer membership.

## Maintainer setup

1. Enable Push Notifications for `link.galaxy.bluetooth.natehuby76` in your Apple developer account and regenerate provisioning profiles.
2. Upload an APNs auth key (`.p8`, Key ID and Team ID) to the `starpilot-sentry` Firebase project under Project settings → Cloud Messaging → Apple app configuration, for the Apple app `link.galaxy.bluetooth.natehuby76`. Never include the key in the app, comma, Git, or a PR.
3. Build with the app's existing bundle ID. Debug has `APS_ENVIRONMENT=development`, Release has `APS_ENVIRONMENT=production`. The same setting supplies the entitlement and `SentryAPNsEnvironment` in Info.plist. Use Release for TestFlight/App Store. Verify the final signed entitlement and Info.plist agree when customizing archive/export settings.

## User setup

Install the StarPilot enrollment PR. In Galaxy → Sentry → Galaxy app phones, tap Enable alerts. The relay address comes from the StarPilot release configuration; there is no URL or code to enter. The app requests notification permission, registers this phone and enrolls comma automatically. Never enter the operator admin key or an Apple signing key. Then enable Sentry phone alerts in the app's Settings or Galaxy's Sentry page, allow notifications, connect to comma, and send a test. Configure the relay once per comma; each phone registers separately.

Comma needs internet while parked, and the iPhone needs internet to receive alerts. A push contains event metadata, not camera images. Tapping it opens the Sentry events page after the app connects to comma. This implementation does not attach photos or poll in the background. Apple controls delivery timing; acceptance by the relay is not a display receipt.

Disabling unregisters from APNs and removes the comma subscription when connected. If disconnected, removal is retried on reconnect. Token rotation removes the old subscription before registering the new one. Subscriptions are tracked per comma identity; after reinstalling the app, remove obsolete phones from Galaxy if they remain listed. iOS may display duplicates if comma retries after an interrupted response; APNs collapses pending copies by event ID.

## Relay contract

The app registers through the existing authenticated transport:

```json
{"action":"appSubscribe","token":"apns.production.<hex-device-token>","appId":"link.galaxy.bluetooth.natehuby76","label":"iPhone"}
```

Development builds use `apns.sandbox.<hex-device-token>`. Comma treats this as an opaque subscription token and registers its destination under the comma credential and forwards the six-field event body to `<base-url>/v2/sentry`. Legacy private pilots use `/v1/sentry`. The phone never stores the comma credential. The Worker converts the Apple token with Firebase (sandbox for development tokens) and sends a visible alert with `type=sentry` and the event ID. Only Firebase reporting the token as unregistered or invalid returns 410; configuration failures return 502 and keep the subscription.

## Validation

Run `python3 tests/check_sentry_push.py` from this directory for registration, token rotation, retry, disable/reconnect and test-request regressions. The harness compiles the production registration model with a fake comma transport and application lifecycle.

Build in Xcode and test on physical iPhones with development and TestFlight signatures. Verify background/locked-screen receipt, tapping while disconnected, notification permission denial, relay outage, token rotation and disable/re-enable. No Apple credentials or live push delivery are included in the automated tests.

Provider setup and launch checklist: https://github.com/dirwin31/StarPilotAndroid/blob/sentry-cloudflare/push-relay/SETUP.md

StarPilot enrollment: https://github.com/dirwin31/openpilot/pull/18

The hosted relay is configured in the clean `natehuby76/StarPilotBT` `work/dom-sentry` branch. Apple push capability, provisioning and Firebase APNs credentials must still be configured and verified with real-phone delivery before release.

The relay currently uses Firebase's Instance ID APNs token import API. Google lists retirement on September 29, 2027; migrate to direct FCM SDK registration or another supported APNs delivery path before then: https://developers.google.com/instance-id/reference/server.
