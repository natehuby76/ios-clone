# connection testing

start with a powered, Offroad comma and the matching SecretGood phone build. first connect to comma over Wi-Fi in the app, then start Bluetooth setup. The app opens comma’s pairing window automatically.

## wi-fi and Bluetooth

1. Select **Automatic**. Under **Set order**, put Local Wi-Fi first, Bluetooth second, and Tunnel third for this test. Connect both devices to the same local network and confirm Galaxy loads over Wi-Fi.
2. open a display preference. turn Wi-Fi off in iPhone Settings, leaving Bluetooth on.
3. Confirm the app switches to Bluetooth and settings still load. Change the display preference, reopen it and check that it saved.
4. restore Wi-Fi and check that Automatic returns to it.
5. repeat with **Bluetooth only** and **Wi-Fi only** selected.

if a setting change loses its response, reload the setting before trying again. the app does not repeat writes automatically after a connection failure.

## hotspots

comma can use a hotspot, Wi-Fi or its SIM for internet. that is separate from the phone's connection to comma. bluetooth settings access needs no internet; model and software downloads still need internet on comma.

some hotspots isolate clients. if direct Wi-Fi access fails, use Bluetooth or another reachable local network. the app does not enable Personal Hotspot or configure comma's Wi-Fi password.

## reconnects

check closing and reopening the app, switching Developer Mode, turning phone Bluetooth off and on, and restarting comma while Offroad. confirm it reconnects without manual setup.

turn comma Bluetooth off and confirm the bridge leaves it off. turn it back on using the normal comma control, then reconnect.

## galaxy UI updates

the app has no bundled Galaxy pages. whenever it connects to comma over Wi-Fi/LAN (or you choose **Check** on the Galaxy screens row) it downloads comma's own web UI, verifies every file against comma's manifest and saves it. a comma without that manifest is too old to share its screens.

an update does not replace an open page. it takes effect when Galaxy next opens. failed or incomplete updates keep the previous copy. a fresh install cannot open Galaxy over Bluetooth until it has downloaded the screens once over Wi-Fi. if comma updated since, Bluetooth still opens the saved copy and says it is from an older comma build.

download the screens over comma's Wi-Fi first, then reopen with phone Wi-Fi and cellular off and Bluetooth on. Galaxy should still load its saved screens. swift changes require a new app build.

## phone notifications

needs comma software with phone notifications (Galaxy shows Toggles → Phone), the car parked or off, and the app connected over Bluetooth. Wi-Fi or Tunnel will not work for setup. starting setup while driving should say to park the car.

1. in Settings, tap **Set up** on **Phone notifications**, then **Set up** in the sheet.
2. when iOS asks, tap **Pair**, then allow **Share System Notifications**. note the exact wording iOS showed and whether it asked at all (it may skip the pairing request if music is already paired).
3. confirm the sheet says notifications are shared. send yourself a message and check it appears on the car screen for a few seconds, then disappears. repeat with the app closed. tap **Send test notification** in the sheet and confirm "StarPilot test notification" appears at the top of the comma and car screens.
4. in Galaxy → Toggles → Phone, turn off an app and confirm its notifications stop.
5. tap **Cancel** on the iOS pairing request once and confirm the app explains it and lets you try again. try again while comma's own pairing window is open and confirm it says comma is busy.

to revoke, open iPhone **Settings → Bluetooth**, tap ⓘ next to comma and switch off **Share System Notifications**. forgetting comma there removes the pairing too, including music.

## feedback

After a failure, open **Logs & support** in app Settings. Include the connection mode, device versions, what you tried, and the error you saw. Keep pairing codes and passwords out of screenshots.
