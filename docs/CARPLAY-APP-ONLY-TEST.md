# App-only CarPlay Live View test

This guide applies to the private `research/carplay-app-only` experiment,
starting with StarPilot BT **1.0.7 (140)**. That build was verified as
**Testing** in the **Just me** group on November 15, 2026.

The older instructions to install `Nate/galaxy-bluetooth`, create capture flags,
or restart a Galaxy service do not apply. This receiver uses the existing
official Dom StarPort tablet protocol. It does not write comma files, restart
Galaxy, change navigation, or change connection settings automatically.
Leave the currently installed prototype alone during this test; this app
does not use its `/api/companion/carplay-live` endpoint.

## Setup while parked

1. Install build **140** from the **Just me** TestFlight group.
2. Connect the iPhone and comma to the same local network. An iPhone hotspot
   is also a local network; a changed comma IP does not require re-pairing.
3. In Galaxy's existing **StarPort** settings, enable StarPort and complete its
   existing identity setup if needed. Select **HeadunitPad**, keep port **5277**,
   and tap **Connect** to start the normal tablet listener. Despite its name,
   this selection is the protocol mode used by the iPhone receiver; a separate
   HeadunitPad app or iPad is not required.
4. Open StarPilot in CarPlay and select **Live View**. On the first connection,
   approve **Trust local comma**. Approval pins the video certificate to the
   verified comma identity, rather than to its current IP address. A changed
   certificate is rejected rather than replaced automatically.
5. Verify a changing picture on the actual head-unit display. A green connection
   indicator or a successful frame enqueue in logs does not establish this.

There is no Tunnel, Bluetooth, cellular, or patched HTTP video fallback.
Do not switch to Open Headunit mode for this test: build 140 uses HeadunitPad's
fragment acknowledgement mode.

## Device evidence still needed

| Check | What to observe | What it establishes |
| --- | --- | --- |
| Parked playback | A changing comma picture remains visible for two minutes | Actual factory-head-unit playback, beyond receiver/decoder tests |
| Phone background | With CarPlay open, the picture continues after the phone leaves the app or locks | CarPlay presentation and stream lifetime survive phone state changes |
| Freshness | Disconnect the local network while parked; the old picture clears, then reconnect | Stale imagery is removed and the stream recovers |
| Address change | On a later parked test, reconnect through another local network | The same paired comma can recover at another IP without re-pairing |
| Car state transition | A passenger observes whether the existing picture continues during an ordinary drive; report observations after parking | Whether the factory receiver continues presenting this experiment while moving |
| Normal comma state | Record any comma warning and whether normal operation differs with Live View open versus closed | Detects a device interaction; absence of a warning alone does not prove all driving functions |

Do not operate the app or collect recordings as the driver while moving.
Video testing does not require engaging driving assistance. A parked-only result
must be recorded as parked-only, rather than proof of the moving-car objective.

After the test, use **Logs & support** to submit a fresh report. Include whether
the picture appeared, whether the car was parked or moving, the approximate
delay, whether it grew over time, and any comma warning. Note the time of a
failure so it can be matched to the retained events.

For a latency measurement, record both screens together while parked and compare
a visible change shared by both pictures. The recording's frame rate limits
measurement precision. If there is no shared visual event, report the subjective
delay without claiming a measured capture-to-head-unit value. Sender and iPhone
clocks are not synchronized, and iOS renderer metrics exclude the physical
head-unit presentation delay.

## Verified evidence and remaining limits

- The same Swift receiver implementation shipped in build 140 passed **nine**
  Mac tests, including encrypted large-message fragmentation, both acknowledgement
  modes, first-use certificate approval, and changed-certificate rejection.
- Ten generated H264 pictures passed through unchanged official Dom's native
  session and the Swift receiver, then decoded at **1280 × 720** with expected
  pixel values. This tests received media integrity; it uses a desktop decoder.
- The iOS receiver/display code compiled, and Apple's full build, archive, and
  private distribution succeeded. None proves pixels on the factory head unit.
- Earlier visible-video and latency reports came from the patched-comma HTTP
  prototype. They are not evidence that build 140 works on the device.
- The private memory-TLS adapter uses deprecated SecureTransport APIs. A maintained
  replacement is required before considering a public release.

The implementation and test details are in
[Experiments/StarPortReceiver](../Experiments/StarPortReceiver/README.md).
The real-media test run is
[GitHub Actions 43750999921](https://github.com/natehuby76/ios-clone/actions/runs/43750999921).

## Public distribution constraints

Apple documents the navigation app's `CPWindow` base view for maps, with
templates used for other UI. This prototype's custom video presentation does
not establish a supported public CarPlay category.
[Apple CPWindow documentation](https://developer.apple.com/documentation/carplay/cpwindow)

Apple's CarPlay video category applies to supported vehicles while parked, and
the vehicle controls playback availability. It does not establish moving-car
video support on this factory 2019 receiver. A successful private device test
would demonstrate technical behavior, not App Store eligibility.
[Apple: Rev up your CarPlay app](https://developer.apple.com/videos/play/wwdc2026/212/)
