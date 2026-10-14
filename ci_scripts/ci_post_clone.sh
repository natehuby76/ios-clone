#!/bin/sh
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -parse-as-library GalaxyBluetooth/LiveStream.swift tests/LiveStreamRegression.swift -o "$test_dir/live-stream-tests"
"$test_dir/live-stream-tests"
