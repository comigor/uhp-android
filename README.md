# UHP Android

Android-only Flutter client for Unified Harness Protocol servers.

## Features

- Dark-first Material 3 UI with separate screens for servers, harnesses, tasks, and history.
- Persistent server profiles, restored after restarting the app.
- Optional Pangolin edge-token and console-credential layers, usable separately or together.
- Automatic console login via `POST /api/selfhost/login`, in-memory session reuse, and re-login when the session expires. Session cookies are not saved to profiles or conversations.
- Harness browser backed by `GET /api/harness/v1/harnesses`.
- Task creation backed by `POST /api/harness/v1/responses` with `stream: true` (SSE), live response text, tool activity, turn status, and token usage when reported by the server.
- Saved conversation history, including partial turns, and session continuation via the last assistant message's `previous_response_id`.
- **Stop** cancels the local stream and requests server cancellation with `POST /v1/sessions/{encodedSessionId}/cancel` when a session ID is known.
- Error snackbars showing HTTP status and parsed `error` or `detail` text where available.
- Streaming turns have a 300-second connection timeout and a 120-second idle timeout, with no total stream-duration timeout. Other network calls retain a 300-second timeout.

## Requirements

- Flutter stable 3.47.5
- Android SDK / platform tools for local builds
- Java 17 for Gradle

## Local build

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

The release APK is debug-signed in v1 for sideloading. Proper signing through repository secrets is still TODO.

## Server setup

### Two optional authentication layers

1. Open **Servers → Add server** and enter a display name and server base URL.
2. If Pangolin protects the server, fill both `P-Access-Token-Id` and `P-Access-Token` in **Pangolin edge authentication (optional)**.
3. If the UHP console requires login, fill both **Username** and **Password** in **Console authentication (optional)**. Both sections remain editable together; there is no exclusive auth mode.
4. Tap **Test connection**, then return to the list and select the server. Each edit is saved immediately; there is no Save button. Connection tests save only the result.

Each layer is enabled only by a complete, nonempty pair. Leave both fields in a layer empty when it is not needed. A partial pair does not enable that layer.

**A UHP console behind Pangolin may require BOTH layers.** The Pangolin token opens the edge proxy; it does not authenticate a console session. Console credentials log in to the application behind that proxy; they do not replace the edge token. Requests carry the Pangolin headers whenever that pair is complete, including console login requests.

When console credentials are present and no session is cached, the app logs in before making the API request. Sessions are held only in memory, isolated by server profile, URL, and credentials, and are lost when the app restarts. A 401 with a session cookie discards that session, re-logs in once, and retries the API call once; a second 401 fails with an actionable error. Connection tests, harness loading, streamed turns, and cancellation share this behavior.

### Authentication errors

- **HTTP 302:** the edge rejected or redirected the request. Check the Pangolin token pair and the server URL. The app does not follow redirects to an HTML login page.
- **HTTP 401 without a complete console credential pair:** add the console username and password, even if the Pangolin token pair is already filled.
- **HTTP 401 after login and retry:** check the console credentials and server authentication settings. The app reports the authentication error rather than retrying the turn as a legacy non-streaming request.

Errors appear in the existing snackbar and connection-test result. **Stop** also closes an in-flight login request when starting a turn.

**Add demo profile** creates a `HarnessRouter demo` template with `https://your-uhp-server.example`. Replace the placeholder and fill the required authentication layers before connecting. Startup remains empty on a fresh install.

### Existing profiles and conversations

Old profiles and conversation snapshots using `authMode` (or `mode`) still load: `pangolin` keeps only the token fields, while `console` keeps only the username and password. Legacy cookies are discarded when loaded. Profiles without an old mode can contain both layers; new writes contain neither a mode nor a cookie. For a console behind Pangolin, edit the migrated profile to add the missing layer. Existing conversations retain their original credential snapshot; start a new task to use an updated profile. Migration does not proactively rewrite every stored conversation file; deleting old conversations or clearing app data removes their old on-disk secrets.

## Usage flow

1. Add and select a server. Use its edit icon to change it or delete it.
2. Test the connection from the profile editor.
3. Load harnesses from the **Harnesses** screen.
4. Tap a harness to open **Tasks**.
5. Enter a prompt and run the task. Response text and tool activity update live; turn status and available token counts are shown. Use **Stop** to cancel a turn and retain its partial response. Moving the app to the background interrupts the active turn and saves its partial response rather than continuing work in the background.
6. Enter another prompt and use **Continue** to send the last assistant message's `previous_response_id` against the same thread. If that assistant message has no response ID, the next request starts a fresh turn in the same thread; it never reuses an earlier assistant's ID. **New task**, or choosing a harness, starts a separate thread.
7. Open **History** to view saved conversations. Tap one to restore it; long-press and confirm to delete it. If its server profile was deleted, the transcript remains readable but continuation shows an error.

If the server rejects streaming with a non-200 response or an error before any other SSE event, the app retries once with `stream: false` for legacy servers. Authentication failures are handled first and never trigger this fallback. After an accepted event, it never retries the turn as a non-streaming request. A successful non-SSE JSON response containing a response ID or output is treated as a completed legacy response, not retried. Completed SSE turns finish immediately without waiting for the server to close the connection.

Before `response.created` supplies a session ID, **Stop** can only close the local request. Once known, cancellation accepts any 2xx, 404, or 409 as sent. Background interruption closes the connection without sending server cancellation, so the server may continue computing. There is no background service; saving partial output on a lifecycle notification is best-effort if the OS kills the process immediately.

## Local persistence and security

Server profiles are stored on the device with `shared_preferences` under the key `servers_v1`. Conversations are saved as JSON files in the app's documents directory at `threads/<id>.json`. A lightweight `threads/index.json` lists saved conversations; full thread files are loaded lazily when opened rather than loading every conversation at startup.

Completed, cancelled, interrupted, and failed streamed turns are saved automatically, including partial response text, turn status, response and session IDs, and token usage when available. Only the last assistant message's response ID is used for the next continuation; a missing ID is not replaced by one from an earlier turn. Older saved messages without turn metadata load as completed. Opening a saved conversation restores its server and harness snapshot so it can be continued after restarting the app. Deleting a conversation removes both its thread file and its index entry.

Thread files and the index are written using temporary files and atomic renames. A small pending-entry journal repairs an interrupted file/index update on the next index load or mutation. If saving a turn fails, it stays visible with **Retry storage write**; retrying storage never repeats the HTTP turn.

**Security warning:** tokens and passwords are stored in plaintext in device-local server profiles and conversation snapshots. Session cookies are kept only in memory and are not included in new writes. This is not encrypted credential storage. Anyone who can access the app's local data may be able to recover saved credentials, including cookies in older files that have not been rewritten or deleted. Deleting a server profile does not erase credentials captured in saved conversations; delete those conversations too, or reset all app data.

Android cloud backup and device-transfer rules exclude app storage, keeping these local copies device-local. Malformed or obsolete profile JSON is logged without credentials, discarded, and loaded as an empty list. Malformed history index JSON yields an empty list; a malformed thread yields an unavailable-conversation error rather than a crash.

To reset saved profiles and history, use Android **Settings → Apps → UHP Android → Storage → Clear storage / Clear app data** (labels vary by device). This removes locally stored data; it does not revoke credentials or delete data on the server.

Persistence uses preferences and files, not a database. There are no background services, polling, or background save timers.

## Known v1 limits

- Saved credentials and conversation snapshots are not encrypted.
- Model override is intentionally omitted; the server default model is used.
- No background services, polling timers, wakelocks, or push.

## CI

`.github/workflows/android.yml` runs analyze and tests on pull requests, pushes to `main`, and tag pushes matching `v*`. Pushes to `main` also build a release APK artifact. Tag pushes build the APK and attach it to a GitHub Release.

## Roadmap

- Optional per-request model selection.
- Proper release signing via GitHub secrets.
- Richer response rendering for non-text output blocks.

## License

MIT.
