# StarPilot BT privacy policy

Updated October 24, 2026. Changes for version 1.0.2.

This policy covers the StarPilot BT iPhone companion. The publisher responsible for this release is the seller identified on its App Store listing. Public support and privacy requests use the [StarPilot support ticket process](https://wiki.firestar.link/ticketsystem/). Ask for your request to be directed to the StarPilot BT app publisher. Do not post private information in a public channel.

## Connecting your devices

StarPilot BT displays Galaxy from a compatible StarPilot installation and sends your requests to the comma you connect. Local Bluetooth access does not require an internet account or a shared network. Some functions require local Wi-Fi or internet access on comma.

Connection preferences, a remembered Bluetooth identifier and local address are stored on your iPhone. Pairing credentials and the pairing ID supplied by comma are stored in the iOS Keychain. On an encrypted Bluetooth connection, the app sends the iOS-provided phone name to comma so it can label that phone in its pairing list. When replacing a pairing, it also sends the previous pairing ID so comma can remove the old entry. It does not add another device identifier. Galaxy interface files are cached on your iPhone. Bluetooth messages use authenticated encryption. Local Wi-Fi communication currently uses HTTP; use a trusted network.

## Permissions

Bluetooth permission is used to find and connect to comma. Local Network permission is used for local Wi-Fi discovery and requests. Bluetooth pairing uses the pairing window on comma. Optional camera access scans the Galaxy tunnel QR code on comma. Camera frames are processed on the iPhone; the app does not save or upload them. You can paste the link instead.

The native app does not request access to the iPhone's contacts, microphone or photo library. Optional phone GPS sharing requests location permission only when you enable it. While enabled and connected, it sends recent location fixes, accuracy, timestamps and available altitude, speed and bearing to your comma, about once a second. Sharing may continue in the background with the iOS location indicator. You can turn sharing off in the app or revoke permission in iPhone Settings. This native feature does not upload GPS fixes to the app publisher; comma's navigation features and any providers configured there handle received location under their own settings and policies.

Navigation alpha testing is optional and available under Developer mode. Its map, place search and phone route previews use Apple MapKit services. Search queries, route endpoints and the map area may be processed by Apple under its privacy policy. Sending a selected destination to comma uses the existing companion navigation API. CarPlay displays the same navigation state when alpha testing is enabled; regular mode displays companion controls and status.

## Network services

The app downloads Galaxy's interface files from your own comma over your local network (or its Wi-Fi hotspot), or through your authenticated Galaxy tunnel and saves them on the iPhone so Bluetooth can show them. It does not download these files from GitHub. Tunnel traffic passes through the Galaxy remote service.

The native companion does not include advertising or an advertising-tracking SDK. Its diagnostics screen does not automatically upload reports to the publisher.

Optional Tunnel access uses HTTPS through galaxy.firestar.link. You sign in on the Galaxy website inside the app; the app saves the resulting session cookie, private link and verified comma identity in the iOS Keychain. It does not save your password. Requests, responses and optional GPS sharing sent over Tunnel pass through the Galaxy remote service; its operator’s handling and retention apply. We do not claim that service keeps no logs.

Opening the legacy Galaxy link opens your device-specific remote website in your browser. That website handles its own login and service requests. Optional services configured through Galaxy, such as maps or a cloud provider, may send information from comma to the selected provider. Their policies apply to their services. This policy does not promise that those separately operated services keep no logs or collect no information.

## Diagnostics and support

The app keeps connection and page events for troubleshooting. Reports can contain app and operating-system versions, connection state, request-path categories, timings and errors. You choose whether to copy, save as a text file, or share a report. Review it before sharing, and keep pairing keys, passwords, private device links and location information out of public reports.

If you submit a StarPilot support ticket, the support team and the ticket-service provider can access the information you provide. Ticket history may remain with that service until removed by its operator. To request access to or deletion of a submitted report, use the same support ticket process and identify the ticket without posting additional private information publicly. A fixed deletion deadline is not promised by this policy.

## Removing stored information

Use Forget saved tunnel in Galaxy tunnel to remove its saved session from this iPhone. This does not revoke other sessions at the remote service.

Use Forget Bluetooth pairing in the app to remove its saved pairing credential. Revoke app links on comma separately if you want to invalidate the device's pairing key. Deleting the app removes its local app container; iOS Keychain entries may persist until removed through the app. Changes and information stored on comma, in remote Galaxy or with another provider must be managed with that device or service.

## Changes and questions

This policy will be updated when the app's data handling changes. Contact the app publisher through [StarPilot support](https://wiki.firestar.link/ticketsystem/) with questions or privacy requests. Support is not an emergency service.
