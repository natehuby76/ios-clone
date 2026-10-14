#!/bin/sh
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -parse-as-library GalaxyBluetooth/LiveStream.swift tests/LiveStreamRegression.swift -o "$test_dir/live-stream-tests"
"$test_dir/live-stream-tests"

python3 tests/extract_carplay_settings.py "$test_dir/SettingsProbe.swift"
swiftc -swift-version 5 -parse-as-library "$test_dir/SettingsProbe.swift" tests/CarPlaySettingsRegression.swift -o "$test_dir/carplay-settings-tests"
"$test_dir/carplay-settings-tests" GalaxyBluetooth/Resources/Web/assets/components/tools/device_settings_layout.json

python3 tests/extract_carplay_navigation.py "$test_dir/NavigationProbe.swift"
swiftc -swift-version 5 -parse-as-library "$test_dir/NavigationProbe.swift" -o "$test_dir/carplay-navigation-tests"
"$test_dir/carplay-navigation-tests"

python3 tests/extract_bluetooth_reads.py "$test_dir/BluetoothReadProbe.swift"
swiftc -swift-version 5 -parse-as-library "$test_dir/BluetoothReadProbe.swift" -o "$test_dir/bluetooth-read-tests"
"$test_dir/bluetooth-read-tests"

swiftc -swift-version 5 -parse-as-library GalaxyBluetooth/GalaxyRequestTransport.swift tests/GalaxyReadCacheRegression.swift -o "$test_dir/read-cache-tests"
"$test_dir/read-cache-tests"
