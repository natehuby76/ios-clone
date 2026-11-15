# Private app-only Live View experiment

This branch uses official Dom's existing StarPort tablet TCP listener (5277).
It does not call the experimental `/api/companion/carplay-live` HTTP route and
does not change files, restart processes, or write settings on the comma.
The CarPlay presentation remains an experiment; do not publish this branch to
the public app or treat a successful archive as proof of head-unit playback.

## Test setup

While parked, connect the iPhone and comma over the same local network. In
Galaxy's existing StarPort settings, enable StarPort, install its identity if
needed, and select **HeadunitPad** tablet connection mode. Keep port 5277.
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

The Mac workflow tests the same Swift transport used by the app against
unchanged `ProjectionSession` from official Dom commit
`f1aecc4770de33490131f1029fc4dc9026ab8c58`. Test certificates are generated for
each run. Large synthetic media tests encrypted fragmentation and both ACK
modes; it does not establish image decoder correctness. The full iOS app is
also compiled without signing before private Xcode Cloud distribution.

The memory TLS adapter currently uses Apple's deprecated SecureTransport
public API to put TLS inside Android Auto records. This is a private prototype
dependency that must be replaced before considering a public release.

Logs include negotiation, TCP/TLS outcomes, frame timestamps, delivery to the
main queue, sample construction/enqueue durations, renderer metrics, drops,
thermal state, and stale-frame clearing. Native AA does not supply capture
age or encode duration; zero values in legacy packet fields mean unavailable.
Sender and iPhone clocks are not synchronized. Renderer readiness is not proof
of a picture physically displayed by the head unit, or of playback while moving.
