# Discord report relay

The iOS diagnostics screen signs in with Discord using OAuth identify and PKCE, previews the report, and sends it to this Worker. The forum webhook and Discord client secret stay in Worker secrets. No bot or domain migration is required.

## Deployment

Use `wrangler deploy` in this directory. Required secrets:

- DISCORD_CLIENT_ID
- DISCORD_CLIENT_SECRET
- DISCORD_WEBHOOK_URL (a webhook for the destination forum)
- DISCORD_PRIVATE_WEBHOOK_URL (a webhook for a separate private forum or text channel)

Register `https://starpilot-log-relay.nathan-g-hubbard.workers.dev/auth/discord/callback` as the Discord OAuth redirect. Optional `FORUM_TAG_IDS` is a comma-separated list of existing forum tag IDs (up to five). Without it, reports have no automatic tags; required forum tags must be configured before use.

`GET /` reports the deployed version. `POST /v1/logs` requires an OAuth access token issued to this Discord application. The test-token endpoint is removed.

## Delivery and privacy

Diagnostics are attached only to the private webhook message. The public forum receives the title, description, reporter mention, and a link to that private message; it receives no diagnostics attachment. Both destinations must be configured and distinct, with no public fallback. The reporter can review them and explicitly submits the report. Access to diagnostics is controlled by the private channel permissions; the public link does not grant access. A thread link is returned to the phone; this does not automatically join the reporter to the server or thread.

A Durable Object per Discord user records report references and delivery results for seven days, with a five-report hourly limit. It does not store diagnostics or OAuth credentials. An ambiguous send at either destination is not automatically repeated. Definite Discord rejections (4xx except request timeout) can be retried with the same unchanged report. A confirmed private upload is retained by message link so a rejected public post resumes without uploading diagnostics again. Network failures, timeouts, malformed confirmations and server errors remain unconfirmed to prevent duplicates. Successful delivery and its dropdown thread entry are saved atomically. The dropdown returns the newest 100 saved threads. The phone saves the pending report with file protection, excluded from backups, and only permits retry under the same Discord account for six days. The user can discard it after checking Discord. Tokens use the iOS Keychain.

Worker request logging is disabled to avoid retaining OAuth callback query strings. Do not add tokens, webhook URLs, or diagnostics to console logs.

## Checks

Run `node --test worker.test.mjs`. These use mocked Discord responses; verify real sign-in, posting, attachment, and opening the forum on a device before announcing end-to-end success.

Reports accept up to 16 MiB of encoded JSON; other endpoints remain limited to 1 MiB. Updated iOS clients fit oversized captures before preview/submission, removing older routine events before failures and marking omissions. Pending retries retain their original capture.

Private diagnostics destination is a forum: `DISCORD_PRIVATE_FORUM=true` creates a private thread for each report and links to its confirmed message. Set it to `false` for a normal private text channel. Public report follow-ups still use the existing public thread.

## Targeted build-ready notifications

Tell the release operator which report(s) a build addresses. The operator registers
an explicit selection in the Cloudflare `BUILD_NOTIFICATIONS` JSON text binding:

```json
[{"userID":"DISCORD_USER_ID","reference":"REPORT_UUID","version":"1.0.3","build":"79","ready":false,"message":"Includes updated Bluetooth connection diagnostics."}]
```

Use actual IDs; placeholders fail validation. This is server configuration, not
personalization embedded in the iOS app. Every entry selects one reporter's saved
report reference, which resolves to that account's existing public thread. The
same build may select several reports, or none. Never enumerate open reports to
choose recipients. The authenticated Cloudflare administration interface is the
way to register scheduled selections. Version 14 also provides the separately
authenticated Android release endpoint described below.

Write each entry's `message` specifically for the selected report. Include only
changes that address that reported issue, and relevant diagnostic improvements.
Notifications are informational only: never ask the recipient to retest, reply,
submit a report, or take any action. Never copy the full build changelog or include
unrelated features, fixes, or other requests from the maintainer. When one build
addresses several reports, write a separate relevant message for each thread.
Check the message against the original report before setting `ready:true`; if a
change's relevance is unclear, omit it. Describe unverified fixes as changes to
test, not a guarantee that the reporter's problem is resolved. The notifier uses
only this per-report message and does not append general release notes.

First leave `ready:false`. Verify `/release-status` shows `pending`, then verify
the selected milestone: `stage:"archived"` requires a successful Apple archive;
omitting stage (or `stage:"testflight"`) requires availability to the recipient's TestFlight group. Notices use a short “Build N archived” or “Build N ready” heading.
Keep the body to a brief description of the relevant change; omit requests and TestFlight boilerplate.
Only then set `ready:true` in the binding. This readiness step is performed by the
release operator; Apple webhooks are not configured. A five-minute Cron Trigger
sends selected ready notifications. New schedules can take time to propagate.
`GET /release-status` only reads status, without revealing reporter IDs or thread
links. Confirm `sent` before announcing delivery. Remove completed selections
from the binding when preparing later builds; stored deduplication survives.
Preserve this binding on deployments (inherit it through the Cloudflare API).

Every notification mentions the reporter **and REPORT_MAINTAINER_ID**, with all
other mention parsing disabled. It posts only in the selected public thread,
never in private diagnostics or the forum generally. Followers' ordinary Discord
notifications still depend on their settings. A build/version/thread key prevents
duplicate posts, including concurrent scheduled invocations and restarts. A 429
waits before retry; all uncertain deliveries stop for manual investigation.
Do not delete the deduplication record to retry an uncertain send.

Report-to-thread references and notification receipts persist without diagnostic
contents or tokens. The original seven-day retry receipt expiry is unchanged.
Older reports can resolve from their unexpired receipt; missing older mappings
must be investigated rather than guessing the destination.


## Android and iOS integration (Worker version 13)

Use the same Worker base URL and Discord application on both platforms. Webhook
URLs, the Discord client secret, and release administration credentials stay on
the server. Deploy version 13 before enabling Android submissions: older Workers
ignore the platform field and would label Android reports as iOS.

### Sign-in

1. Generate independent cryptographically random state and PKCE verifier values
   (base64url without padding, 43–128 characters). Keep them for this attempt.
2. Compute code_challenge = base64url(SHA256(verifier)), without padding.
3. Open GET /auth/discord/start?state=STATE&code_challenge=CHALLENGE in the
   platform's authentication browser. Do not embed the Discord client secret.
4. Register starpilot-discord://callback in Android. The Worker forwards code,
   state, error and iss to that address. Validate the callback scheme/host,
   match state to the outstanding attempt, and require iss=https://discord.com.
   Handle cancellation/errors without exchanging a code. Consume an attempt once.
5. POST /auth/discord/exchange with JSON {"code":"...","verifier":"..."}.
   Save the returned access_token, refresh_token, expires_in and user_id using
   Android's secure credential storage. Never include them in diagnostic logs.
6. POST /auth/discord/refresh with {"refresh_token":"..."} before expiry and
   replace stored tokens with the response. Disconnect via /auth/discord/revoke
   with {"token":"REFRESH_TOKEN"}.

Discord's registered OAuth redirect remains the Worker's HTTPS
/auth/discord/callback URL, not the app's custom scheme. Both platforms use PKCE;
the callback scheme itself does not authenticate an app.

### Submit and list reports

POST /v1/logs with Content-Type: application/json and Authorization: Bearer TOKEN:

```json
{
  "platform": "android",
  "reference": "12345678-1234-1234-1234-123456789abc",
  "description": "Bluetooth connects but Tunnel cannot reach comma.",
  "logs": "StarPilot Android diagnostics\nApp version: ...\nRecent events:\n..."
}
```

Generate a fresh UUID per new report; preserve it and the original payload for
retries. Description is required, at most 1000 characters. Logs are required
nonempty text; no particular header or event format is parsed. The full encoded
JSON body must fit within 16 MiB (leave headroom for JSON escaping). Redact secrets
on-device and let users review before sending. Logs go only to private diagnostics.

Success returns {sent:true,reference,threadURL}. Only show success after this
confirmation. A 409 may mean delivery is uncertain: do not silently resubmit under
a new UUID. A retryable rejection can be retried with the original unchanged
payload; never recreate diagnostics during that retry. Honor rate limiting.

POST /v1/reports with {"platform":"android"} and the same bearer token returns
{reports:[{id,title,platform,created}]}. Older iOS records may omit platform.
Pass the selected id as optional threadID on /v1/logs to follow up. Lists are
account-scoped and platform-filtered; cross-platform follow-ups are rejected.
Missing platform defaults to ios; explicit values other than ios/android fail.
Existing iOS clients need no update. The five-report hourly limit remains shared
per Discord user across devices/platforms.

### Platform tags

Set IOS_FORUM_TAG_IDS and ANDROID_FORUM_TAG_IDS to comma-separated existing tag
IDs from the public forum (up to five per platform). Missing IOS_FORUM_TAG_IDS
falls back to the existing FORUM_TAG_IDS for backward compatibility. Android
never inherits the legacy iOS tag list. With no Android IDs configured it sends
without tags; if the forum requires a tag, configure IDs before live testing.
These settings affect new public threads, not existing threads or private tags.

### Android build updates

Add an explicitly selected release entry to BUILD_NOTIFICATIONS:

```json
[{"platform":"android","userID":"DISCORD_USER_ID","reference":"REPORT_UUID","version":"2.0-beta1","build":"123","stage":"available","ready":false,"message":"Updated Tunnel connection recovery."}]
```

Replace placeholders with real IDs. Android version is the versionName (1–64
ASCII letters/digits/dots/underscores/pluses/hyphens, starting alphanumeric);
build is the positive decimal versionCode as a string (up to ten digits).
Android requires stage=available. The operator verifies that this recipient can
actually download the intended release before changing ready to true. There is
no automatic Google Play/GitHub release detection. Release credentials must never
be included in a distributed app.
The existing five-minute scheduler and delivery rules apply.

Notifications must resolve to a report on the same platform. New dedup keys
include platform/version/build/thread. Existing iOS notification receipts are
still honored, including uncertain deliveries; do not delete or reset them.
Report retry receipts and reference mappings also separate Android from iOS.
/release-status includes platform, without exposing report identities or links.
Keep existing BUILD_NOTIFICATIONS entries and all secrets/bindings when deploying.

Suggested first diagnostics: report UUID, timestamp/timezone, app version/build,
phone/OS, selected and active connection, last error, comma version if known,
Galaxy pairing state, and timestamped recent events. Unknown is acceptable.
Never include session cookies, passwords, OAuth tokens or private tunnel URLs.

### Configured public forum tags

Public forum: `1565235002734809168`. New threads receive Open plus their platform.
Follow-ups preserve existing tags; the relay does not reopen closed threads.
New threads also receive matching topic tags from the written description.

| Tag | ID |
| --- | --- |
| Open | 1565236988913913887 |
| In Progress | 1565237023265263657 |
| CLOSED | 1565237052524466207 |
| Navigation | 1565237084447445122 |
| CarPlay | 1565237111391527112 |
| iOS | 1567744790856990730 |
| Android | 1567744808926322811 |

| Galaxy | 1567747425047941200 |

Automatic topic matching uses only the user-written description, not diagnostics
or AI-generated titles. CarPlay (including Car Play/Car-Play) adds CarPlay;
navigation/nav, routing/routes, maps, directions or destination adds Navigation;
Galaxy or tunnel adds Galaxy. Matching is case-insensitive and whole-word based.
Mentions identify topics, not which subsystem caused the fault; for example,
“Bluetooth works but Tunnel fails” adds Galaxy. Missing/invalid topic tag bindings
are ignored. Duplicate IDs are removed and Discord’s five-tag limit is respected.
Open and platform tags take precedence. In Progress and CLOSED remain manual.

## Android developer release command (Worker version 14)

This feature is disabled unless the Cloudflare **secret** `ANDROID_RELEASE_KEY`
is configured. Use a cryptographically random 32-byte value encoded as base64url
without padding (43 characters). Configure and share it through a secure channel,
not Git, chat, a URL, or the Android app. Replacing/removing this secret revokes
the previous key. Keep existing secrets, bindings and BUILD_NOTIFICATIONS intact.
The key grants notification access to existing Android reports only. It grants
no Cloudflare administration, diagnostic downloads, report listing or iOS notices.
It can target any Android report whose reporter ID and UUID the holder knows;
it is not restricted to a single reporter.

Give the developer `notify-android.mjs` and Node.js 20 or newer. Load the key into
`ANDROID_RELEASE_KEY` from their local secret manager or protected CI environment.
The script does not accept the key in arguments. No dependencies are needed.

First run a read-only check (replace the example identifiers):

```sh
node notify-android.mjs --user 123456789 --report 12345678-1234-1234-1234-123456789abc --version 1.2.0 --build 123 --message "Updated Bluetooth reconnect handling."
```

Then run the identical command with `--send --available` only after confirming
the reporter can download that build. Both the reporter's Discord ID and report
UUID are necessary because storage is partitioned by reporter. These appear in
the original Discord report; do not substitute the developer's own ID.

The command calls `POST /v1/android/build-notice/status` by default, or
`POST /v1/android/build-notice` to send. Both require `Authorization: Bearer KEY`
and `Content-Type: application/json`, with a maximum 8 KiB JSON body:

```json
{"userID":"123456789","reference":"12345678-1234-1234-1234-123456789abc","version":"1.2.0","build":"123","message":"Updated Bluetooth reconnect handling.","available":true}
```

The endpoint fixes platform to Android and stage to available. Unknown fields,
including platform, threadID, stage and webhook URLs, are rejected. The stored
report determines the destination; iOS records cannot be used. A successful HTTP
response is not necessarily delivery: inspect `state`. Only `sent` confirms it.
`pending` on the status endpoint means no delivery receipt exists for that valid
report/build. Status checks never send. Missing reports return 404.

This sends immediately rather than adding a Cron entry. It shares deduplication
with scheduled Android notices. A repeat for the same platform/version/build/thread
does not post again. An uncertain delivery stays blocked; do not change identifiers
to evade it. A rate-limited result may be retried with identical arguments after
waiting. There is no automatic client retry. Keep each message relevant to that
report and follow the same notification-writing rules above.

Before giving access to the developer, test with an explicitly designated Android
test report. Local tests mock Discord; they do not send real notifications.

## iOS release command and Mac/Windows setup (Worker version 15)

Both `notify-ios.mjs` and `notify-android.mjs` run on macOS, Windows and Linux
with Node.js 20 or newer. They have no external dependencies. The script's
platform is the app being announced, not the computer running the command.

Configure a separate Cloudflare secret `IOS_RELEASE_KEY` for the iOS operator.
Use a different random key from `ANDROID_RELEASE_KEY`; never reuse either key.
The iOS route is `/v1/ios/build-notice` (or `/status`), with the same JSON fields
and safeguards as Android. It fixes stage to `testflight`. `available:true`
means the recipient can access this build in their TestFlight group, not merely
that Xcode Cloud archived successfully. Existing administrator-managed archive
notifications remain supported through BUILD_NOTIFICATIONS.

Load the key into the process environment from a password manager/CI secret, or
use a hidden prompt. Do not paste a literal key into a command saved in history.
For iOS on Windows PowerShell:

```powershell
$releaseSecret = Read-Host 'iOS release key' -AsSecureString
$env:IOS_RELEASE_KEY = [System.Net.NetworkCredential]::new('', $releaseSecret).Password
```

For iOS in macOS's default zsh Terminal:

```zsh
read -rs 'IOS_RELEASE_KEY?iOS release key: '; echo
export IOS_RELEASE_KEY
```

For Android use `ANDROID_RELEASE_KEY` in place of `IOS_RELEASE_KEY` in those
commands. These values last for that terminal session. After use, clear them with
`Remove-Item Env:IOS_RELEASE_KEY` (PowerShell) or `unset IOS_RELEASE_KEY` (zsh),
using the Android variable name when appropriate.

From the folder containing the script, the same command works on either OS:

```sh
node notify-ios.mjs --user 123456789 --report 12345678-1234-1234-1234-123456789abc --version 1.0.5 --build 123 --message "Updated tunnel sign-in."
```

This only checks status. Add `--send --available` to send after verifying
TestFlight access. Use `notify-android.mjs` for Android, with its separate key.
Both require the original reporter's Discord user ID and report UUID. Both use
the existing stored destination and shared duplicate protection, including old
iOS receipts. Neither starts a build or changes tester groups.

## Platform maintainer mentions (Worker version 16)

`ANDROID_REPORT_MAINTAINER_ID` selects the Android developer mentioned on new
Android reports, follow-ups, and Android build notices. Production uses
`420178305073938433`. iOS keeps `REPORT_MAINTAINER_ID` (`524762496373096459`).
The reporter is still mentioned on both platforms. An absent Android setting
falls back to the existing maintainer for backward compatibility. Private
diagnostic uploads do not send mentions; existing posts are not edited.

A live Android integration test must use a Discord OAuth access token issued
through this Worker's sign-in flow, not a release-notification key. Submit
`platform:android`, a fresh UUID, a clearly labeled test description and synthetic
diagnostic text to `/v1/logs`. Check Android/Open tags, developer mention, private
attachment and returned thread URL. No real device diagnostics are needed.

## Simplified iOS workflow

Keep `notify-ios.mjs` and `notify-support.mjs` together (or use the repository).
Run `node notify-ios.mjs --setup` once to generate a local key in
`~/.config/starpilot-notify/ios.json`. It refuses to overwrite an existing key.
Set that key once as the Cloudflare `IOS_RELEASE_KEY` secret. The script then
loads it automatically; `IOS_RELEASE_KEY` in the environment takes precedence.
The key file is local plaintext (mode 0600 on macOS/Linux); keep it outside Git
and use a private Windows user folder. It is not an OS credential-vault entry.
An optional `--key-file PATH` overrides the path.

In the maintainer workspace, an existing
`private-handoff/release-keys/ios.json` next to the repository is detected instead.
The default private registry is `private-handoff/contacts.json` next to the repo;
use `--registry PATH` on another machine. Neither file is included in Git.

Run `node notify-ios.mjs` without arguments for guided prompts. Enter a report
reference, app version, build number and short message. The reporter ID is
resolved from the private registry. Enter SEND to confirm TestFlight availability
and send, or Enter to check only. No build readiness is inferred automatically.

You can also use `--report UUID` without `--user`, or `--report-file PATH` for a
text file containing the original Discord report. Its `Report from <@ID>` mention
and Reference UUID are extracted. Human display names alone are not enough.
Conflicting or missing identities stop the command; it never guesses or sends
to every thread. Older flags, including explicit `--user`, remain supported.

Run `node --test worker.test.mjs notify-support.test.mjs` for backend and helper
checks. No real Discord notification is sent by these tests.

## Online release desk (Worker version 17)

Open `/dashboard` on the Worker. The shell is public but contains no report data;
all report requests and Worker GitHub API requests require the selected platform's release key.
The key is held only in page memory, never URLs, localStorage or sessionStorage.
Lock/reload clears it. This is key-based developer access, not Discord OAuth SSO.
Each key now authorizes listing its platform's report metadata as well as sending
release notices. Share it only with that platform's authorized release operator.

New confirmed reports and follow-ups automatically enqueue a metadata-only index
update. The per-reporter Durable Object commits the outbox together with the
confirmed report, then flushes to a separate per-platform index object in the
existing REPORTS namespace. Failures do not turn successful delivery into failure:
the alarm retries pending entries. No diagnostics, passwords, or OAuth tokens are
indexed. Stored fields are reporter name/ID, title, reference, date and public
thread URL. Metadata persists like the existing report-reference mappings.

The desk lists 100 reports at a time, supports load-more and searches loaded
reports by name/title/reference/thread link. Older reports can be imported by
pasting an original report; the server checks the actual per-user mapping and
platform rather than trusting a supplied destination. An authenticated one-time
backfill can POST `{userID,syncHistory:true,reporter,cursor}` to the same import
endpoint to recover that known reporter's stored references in pages of 50.
The optional reporter label only names legacy records without a stored name;
it never changes their ownership or destination.

POST `/v1/ios/dashboard/reports`, `/commits`, or `/import` (and Android equivalents)
uses the same bearer authentication as build notices. The GitHub sources are
fixed server-side to `natehuby76/starpilot-galaxy-ios` / `ios-companion-dev` and
`dirwin31/StarPilotAndroid` / `Play-Dev`. Only commit SHA, subject, date and canonical
GitHub link are returned. Public GitHub reads require no extra connection; optional
GITHUB_READ_TOKEN can increase rate limits. The browser cannot select arbitrary
repositories. If the Worker is rate limited, the browser falls back to the same public GitHub commit endpoint without sending release credentials or report data. GitHub failure leaves manual drafting available.

Selecting a commit can insert its subject as a starter draft, not an AI assertion
that it fixes the report. The operator edits it for relevance. The desk checks
version/build inputs and existing delivery status, previews the message, and
requires explicit availability confirmation and a final Send click. Existing
notification deduplication and Android/iOS recipient routing are unchanged.
Apple/Google Play build availability is not connected; commits are not treated
as proof a release is downloadable. No build is started by the dashboard.

Run `node --test worker.test.mjs notify-support.test.mjs dashboard.test.mjs`.
`node build-dashboard.mjs` produces an ignored `dist/worker.mjs` single-module
artifact for the dashboard editor. Normal Wrangler deployments use worker.mjs
and bundle its imports. Preserve every existing secret, var, binding and Cron.

## Dashboard passwords (Worker version 18)

The dashboard now shows a password field and a Set password button before setup,
and Sign in afterward. Each platform has a separate password. The owner creates
one-time setup links with POST /v1/ios/dashboard/setup-link and JSON
{"platform":"ios"} or {"platform":"android"}, authenticated by IOS_RELEASE_KEY.
Give each maintainer their platform link; they choose their own password in the UI.
Links expire after seven days and cannot replace an existing password. Generating
a replacement setup link invalidates the previous unused link.

Passwords are salted PBKDF2-SHA256 hashes (100,000 iterations) in the platform
Durable Object, never plaintext. Login issues an eight-hour opaque session kept
in tab memory. Lock dashboard revokes it. Failed setup/login requests are limited
to ten per IP per ten minutes. Existing release keys remain usable by scripts.
No public first-visitor claim is allowed: initial setup requires the platform invite.

The older release-key login instructions above describe version 17; normal browser
users now use their chosen password. API-key instructions still apply to CLI usage.

## Platform setup links (version 19)

Use /dashboard/ios and /dashboard/android for platform-specific sign-in. Setup links
now carry their one-use invite in the query string, removed immediately after page
load. Legacy fragment links are still supported, including same-tab navigation.
The button names the platform and is unavailable until setup state is loaded.
Successful setup explicitly confirms the platform password was created.

## Discord tag controls (prepared for bot setup)

The dashboard's **Thread tags** panel reads current Discord tags and lets each
platform maintainer choose Open, In Progress, or Closed and the Navigation,
CarPlay, and Galaxy topics. The platform tag is automatic. Unknown custom tags
are retained; Discord's five-tag limit is enforced. Changes made since the panel
was loaded require reloading before saving.

Configure the Worker secret `DISCORD_BOT_TOKEN` with a bot installed in the
support server, with View Channel and Manage Threads access to forum
`1565235002734809168`. No bot token is sent to the browser. Existing OAuth login
and webhook secrets do not provide this access.

Once configured, `/v1/reports` reads Discord's active threads on each refresh and
excludes Closed-tagged, locked, and archived threads. Reopened active threads
return on the next refresh. Existing report history remains available in the
dashboard. Archived threads must be unarchived in Discord before editing tags.
New follow-up submissions also verify the thread is available; confirmed delivery
retries retain their existing idempotent behavior. Discord outages return a retry
error, not a misleading empty list. With no bot configured, existing submission
behavior is preserved and tag controls explain the missing setup.

Test: `node --test worker.test.mjs dashboard.test.mjs notify-support.test.mjs thread-tags.test.mjs`
