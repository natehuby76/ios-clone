# StarPilot BT

builds come from `natehuby76/ios-clone`, branch `codex/secretgood-galaxy`.

upstream iOS changes currently come from `dirwin31/openpilot:companion-ios-phone-music`. the imported revision is in `upstream-ios.json`. Galaxy screen updates use that same developer branch until the changes land in the official repo.

keep signing, the app name, official artwork, privacy manifest and release settings here. test fixes in this repo, then send them to `dirwin31/openpilot:companion-ios-phone-music` under `openpilot/starpilot/companion/ios/`.

open `GalaxyBluetooth.xcodeproj` and choose the `GalaxyBluetooth` scheme. run `sh ci_scripts/ci_post_clone.sh` for the Swift checks. device and TestFlight builds need the Apple signing profile. Bluetooth music and pairing still need a real phone and comma.
