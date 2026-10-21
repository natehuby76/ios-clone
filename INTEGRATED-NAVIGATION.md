# Integrated navigation test build

This branch adds native iPhone navigation to the existing StarPilot BT app. Galaxy, Navigation and Settings share AppModel's Bluetooth/automatic-LAN connection, pairing and opt-in phone GPS uploader. No comma update is required. No comma files, driving code, bridge protocol, credentials, signing identity, official artwork or privacy manifest were changed. Existing CarPlay behavior is unchanged; native navigation is iPhone-only in this build.

The top tabs float in purple-tinted Liquid Glass with a violet gradient selection and a material fallback on older iOS. There is no bottom app tab bar. On Galaxy and Navigation the tabs collapse after five seconds into an expandable glass pill; Settings stays expanded. VoiceOver keeps the tabs expanded and Reduce Motion disables the transition. Settings follows light/dark appearance with lavender surfaces in light mode. Navigation retains Apple map appearance, route previews, favorites, recents, alternative routes, phone-only navigation and optional destination handoff. One-tap End, a reset action and diagnostic report copying are available in Navigation. Galaxy web polling pauses while another tab is active. Navigation results are invalidated on reset without tearing down the shared Bluetooth transport.

Use Navigation inside this BT app during testing; do not keep the separate StarPilotNav app connected at the same time. This does not change the bridge's behavior for two separate apps.

Validation: simulator build and shared-settings/tab UI regression; existing pairing, reconnect, read policy, GPS uploader, LAN identity, read cache, assets and local server regressions; route revision/session barriers, freshness, schema and no-write-replay checks; JavaScript search regression. Physical Bluetooth, background location and real-route testing remain required.

Distribution: development branch only, existing TestFlight app identity. No merge into the release branch or App Review submission. Tester group assignment remains manual.
