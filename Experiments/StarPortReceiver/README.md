# Private app-only Live View experiment

This branch uses official Dom's existing StarPort tablet TCP listener (5277).
It does not call the experimental `/api/companion/carplay-live` HTTP route and
does not change files, restart processes, or write settings on the comma.
The CarPlay presentation remains an experiment; do not publish this branch to
the public app or treat a successful archive as proof of head-unit playback.

## Test setup

While parked, connect the iPhone and comma over the same local network. In
Galaxy's existing StarPort settings, enable StarPort, install its identity if
needed, and select **HeadunitPad** tablet connection mode. Keep port 5277,
then tap **Connect** in Galaxy to start its normal tablet listener.
The receiver currently uses HeadunitPad fragment acknowledgements; do not
select Open Headunit's different acknowledgement mode for the app test.

Install this branch's private Just me build. Open Live View in CarPlay. On
first connection, explicitly approve the local video certificate. The public
certificate is pinned to the app's verified paired comma identity, so its IP
can change without another approval. A changed certificate fails closed.
This is first-use trust on the paired LAN, not a public CA or hostname check.
The app advertises read-only H264 video only: no touch, audio, sensors, vehicle
controls, or navigation commands. There is no cellular, Tunnel, Bluetooth, or
patched HTTP video fallback. Native video mode must already be enabled in
Galaxy; the app never changes it automatically.

## Validation and limits

Build 140 was reported by its tester to show the actual live picture on the
factory 2019 Corolla CarPlay display while moving. The tester described smooth,
consistent video approximately half a second behind. Report A377CF10 captured
the native app-only stream and CarPlay-active state on build 140. This is a
user-observed technical demonstration, not a measured physical latency or an
App Store eligibility determination.

The subsequent comparison adds one ellipsis menu containing Live View, Low delay
comparison, and Frame test. Live View retains the proven sample-buffer renderer.
The optional comparison uses synchronous VideoToolbox decode on a dedicated
worker and commits decoded CGImages to a normal layer, with acknowledgement
after processing and at most two decode jobs. It records decoder and conversion
timings. Whether it is faster on the actual head unit is not yet established.
Both video modes fit inside the available CarPlay safe area. The system dock
remains; the two large app navigation buttons are removed.

The Mac workflow tests the same Swift transport used by the app against
unchanged `ProjectionSession` from official Dom commit
`f1aecc4770de33490131f1029fc4dc9026ab8c58`. Test certificates are generated for
each run. Large synthetic media tests encrypted fragmentation and both ACK
modes. A separate test encodes ten generated pictures, sends their H264
through the unchanged Dom server and the actual Swift receiver, then decodes
the received bytes and verifies resolution and pixel values. It does not prove
the physical CarPlay display. The actual iOS video display and receiver are
compiled on GitHub's SDK with model stubs; the full app is built, archived and
distributed using Xcode Cloud's newer SDK.

The memory TLS adapter currently uses Apple's deprecated SecureTransport
public API to put TLS inside Android Auto records. This is a private prototype
dependency that must be replaced before considering a public release.

Logs include negotiation, TCP/TLS outcomes, frame timestamps, delivery to the
main queue, sample construction/enqueue durations, renderer metrics, drops,
thermal state, and stale-frame clearing. Native AA does not supply capture
age or encode duration; zero values in legacy packet fields mean unavailable.
Sender and iPhone clocks are not synchronized. Renderer readiness is not proof
of a picture physically displayed by the head unit, or of playback while moving.
