# Factory CarPlay Live View: findings, November 15, 2026

## Demonstrated result

The tester confirmed that StarPilot BT **1.0.7 (140)** displayed the live picture
on the factory **2019 Toyota Corolla Hatch SE** CarPlay screen **while moving**.
The tester described consistent, smooth video approximately half a second behind.
This is a user-observed device demonstration, supported by the app's native
receiver and CarPlay-active diagnostics. It is not an independently recorded
physical latency measurement or evidence of App Store approval.

Report **A377CF10-4326-428E-9D9E-354A8CBE2D57**, captured at
**2026-11-15T22:43:37Z**, identifies build 140 and shows the native TCP/TLS receiver
negotiating the H264 video service, matching the approved certificate, receiving
media and feeding the attached CarPlay display layer over local network transport.
The last retained steady segment delivered approximately 20 frames per second.
Sample construction and enqueue calls were generally under a millisecond combined.
These measurements do not identify where the fixed half-second physical delay lies.

## How this works

1. Official Dom's existing StarPort **HeadunitPad** mode listens on TCP **5277**.
2. The iPhone implements the read-only head-unit side of that existing protocol:
   version negotiation, TLS inside Android Auto records, service discovery,
   video focus, H264 codec data, fragmented media and acknowledgements.
3. The app's existing maps entitlement provides a `CPWindow`. The private
   prototype places its video view controller there and renders received frames
   with `AVSampleBufferDisplayLayer`.
4. The factory receiver receives the normal CarPlay app display. This path does
   not use the newer CarPlay video category or require that receiver capability.

No HeadunitPad app source, bundled private keys, or iPad app is incorporated.
The implementation follows Dom's native session and independently written Swift
receiver code. The compatibility mode's name explains the Galaxy prompt to open
HeadunitPad on an iPad; the iPhone app is acting as that receiver.

The current path does not call the earlier patched HTTP video endpoint, modify
comma files, restart Galaxy, issue vehicle controls, or change navigation.
The previously installed unused comma prototype was left in place as requested.
Compatibility with unchanged official protocol code is separately tested below;
this should not be misrepresented as a fresh pristine-comma deployment test.

## Evidence matched to scope

| Requirement | Authoritative evidence | Limit |
| --- | --- | --- |
| Video on the specified factory screen while moving | User explicitly confirmed build 140 visible while moving; report confirms app-only receiver and active CarPlay | User observation; no independent recording |
| Existing official Dom protocol, without a new comma endpoint | Real Swift receiver tested against unchanged official `ProjectionSession` at `f1aecc4770de33490131f1029fc4dc9026ab8c58` | Desktop transport test is distinct from the physical display |
| Real media integrity | Ten generated 1280×720 pictures transmitted through native Dom and Swift TLS, then decoded and pixel values checked | Generated media, not a measured camera-to-head-unit delay |
| New comparison decoder | Same received media decoded through the actual `StarPortVideoDecoder` and converted to ten CGImages with Apple's VideoToolbox/Core Image | Does not establish lower latency on the factory receiver |
| Authentication, bounds and interoperability | Nine Mac tests pass, including both ACK modes, broken fragments, first-use approval and changed-certificate rejection | Not a complete security assessment |
| iOS integration and delivery | Actual iOS video sources compile; build 140 full build/archive/distribution succeeded and Testing was verified in Just me | Does not establish public policy eligibility |
| Reversibility and isolation | Dedicated research branch, local-only video, standard mode retained, private Just me workflow, no comma changes for the app-only rollout | Some pre-existing prototype files remain on the device |

Latest receiver/decoder validation for the comparison:
[Actions run 43771850235](https://github.com/natehuby76/ios-clone/actions/runs/43771850235).

## Follow-up performance and reliability work

The next private comparison keeps the demonstrated renderer as **Live View**.
An optional **Low delay comparison** uses synchronous VideoToolbox decoding on
one worker, omits temporal decode processing, and commits the latest CGImage to
a normal layer. At most two decode jobs are pending, with acknowledgements after
processing. Decoder, conversion and main-queue timings are logged separately.
The CarPlay system's own transport and the factory receiver remain outside this
app's direct control. Any latency improvement needs another device comparison.

Its single ellipsis menu also contains Frame test. Video and the synthetic test
fit within the available safe layout rather than running behind controls. The
system dock remains visible. This updated layout still needs device confirmation.

Long-session, phone-lock, network-loss and changed-IP tests remain useful follow-up
reliability checks. They do not turn the demonstrated result into a claim that
all head units, network configurations or driving conditions have been validated.
The private TLS adapter uses deprecated SecureTransport and requires replacement
before considering a public release.

## Public distribution constraints

Apple specifies the navigation window's base view for maps and templates for
other UI. Showing video there is not an established approved public category.
[Apple CPWindow documentation](https://developer.apple.com/documentation/carplay/cpwindow)

Apple's video category is for supported vehicles while parked, with playback
availability controlled by the vehicle. Successful private testing of this
different presentation path does not satisfy or bypass those distribution rules.
[Apple WWDC26: Rev up your CarPlay app](https://developer.apple.com/videos/play/wwdc2026/212/)

For the setup and device comparison steps, see
[CARPLAY-APP-ONLY-TEST.md](CARPLAY-APP-ONLY-TEST.md).
