# StarPilot BT

The combined testing app builds from `natehuby76/ios-clone`, branch `codex/integrated-navigation`. The public Bluetooth-only branch remains `codex/secretgood-galaxy`.

The app starts with the regular StarPilot BT interface. Under Developer mode, Navigation alpha testing enables the native navigation interface and CarPlay map. Regular CarPlay keeps its existing toggles and stats. Turning alpha off clears phone navigation without sending a route-clear command to comma.

DI’s comma-served Galaxy and pairing changes are imported from `dirwin31/openpilot` commit `434a65cdb73d81f69b134386773d23c4c7ee825a` (StarPilotBT PR #3).

Keep signing, app identity, official artwork and the privacy manifest here. Open `GalaxyBluetooth.xcodeproj`, select the `GalaxyBluetooth` scheme, and run `sh ci_scripts/ci_post_clone.sh` for regression checks. Simulator builds do not validate physical Bluetooth or CarPlay behavior.

Navigation uses the existing companion destination API; this repository does not change vehicle controls or models. CarPlay requires both the Driving Task and Navigation capabilities in the signing profile. Alpha access is controlled in the app; signed capabilities cannot be toggled at runtime.

See [Quick start](QUICK-START.md) and [Tester guide](TESTER-GUIDE.md).

## Galaxy screens

The app does not bundle Galaxy's web pages. It downloads them from your comma over Wi-Fi/LAN (`GET /api/companion/web-manifest`
lists the files and their SHA-256), verifies them and saves a copy that Bluetooth uses. Connect over Wi-Fi once before using
Bluetooth Galaxy. Custom and unpushed branches work because nothing comes from GitHub. A comma build without that route cannot share its screens: over Wi-Fi the app then reads the pages live from comma, and Bluetooth stays unavailable until the screens have been downloaded.
