# UHP Android

Android-only Flutter client for Unified Harness Protocol servers.

## Features

- Dark-first Material 3 UI with separate screens for servers, harnesses, tasks, and history.
- Persistent server profiles, restored after restarting the app.
- Pangolin machine-token auth via `P-Access-Token-Id` and `P-Access-Token` headers.
- Console login auth via `POST /api/selfhost/login`, cookie capture from `Set-Cookie`, and cookie reuse on later requests.
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

### Pangolin machine token

1. Open **Servers → Add server**.
2. Choose **Pangolin machine token**.
3. Enter a display name and server base URL.
4. Fill `P-Access-Token-Id` and `P-Access-Token`. Each edit is saved immediately; there is no Save button.
5. Tap **Test connection** in the profile editor, then return to the list and select the server.

**Add demo profile** creates a `HarnessRouter demo` template with `https://your-uhp-server.example` and Pangolin auth. Replace the placeholder before connecting. Startup remains empty on a fresh install; existing saved profiles are not rewritten.

### Console login

1. Open **Servers → Add server**.
2. Choose **Console login cookie**.
3. Enter a display name, base URL, username, and password. Edits are saved automatically.
4. Tap **Test connection**, then return to the list and select the server.
5. The app posts credentials to `/api/selfhost/login`, captures `Set-Cookie`, and persists the cookie and test result for later API calls.

## Usage flow

1. Add and select a server. Use its edit icon to change it or delete it.
2. Test the connection from the profile editor.
3. Load harnesses from the **Harnesses** screen.
4. Tap a harness to open **Tasks**.
5. Enter a prompt and run the task. Response text and tool activity update live; turn status and available token counts are shown. Use **Stop** to cancel a turn and retain its partial response. Moving the app to the background interrupts the active turn and saves its partial response rather than continuing work in the background.
6. Enter another prompt and use **Continue** to send the last assistant message's `previous_response_id` against the same thread. If that assistant message has no response ID, the next request starts a fresh turn in the same thread; it never reuses an earlier assistant's ID. **New task**, or choosing a harness, starts a separate thread.
7. Open **History** to view saved conversations. Tap one to restore it; long-press and confirm to delete it. If its server profile was deleted, the transcript remains readable but continuation shows an error.

If the server rejects streaming with a non-200 response or an error before any other SSE event, the app retries once with `stream: false` for legacy servers. After an accepted event, it never retries the turn as a non-streaming request. A successful non-SSE JSON response containing a response ID or output is treated as a completed legacy response, not retried. Completed SSE turns finish immediately without waiting for the server to close the connection.

Before `response.created` supplies a session ID, **Stop** can only close the local request. Once known, cancellation accepts any 2xx, 404, or 409 as sent. Background interruption closes the connection without sending server cancellation, so the server may continue computing. There is no background service; saving partial output on a lifecycle notification is best-effort if the OS kills the process immediately.

## Local persistence and security

Server profiles are stored on the device with `shared_preferences` under the key `servers_v1`. Conversations are saved as JSON files in the app's documents directory at `threads/<id>.json`. A lightweight `threads/index.json` lists saved conversations; full thread files are loaded lazily when opened rather than loading every conversation at startup.

Completed, cancelled, interrupted, and failed streamed turns are saved automatically, including partial response text, turn status, response and session IDs, and token usage when available. Only the last assistant message's response ID is used for the next continuation; a missing ID is not replaced by one from an earlier turn. Older saved messages without turn metadata load as completed. Opening a saved conversation restores its server and harness snapshot so it can be continued after restarting the app. Deleting a conversation removes both its thread file and its index entry.

Thread files and the index are written using temporary files and atomic renames. A small pending-entry journal repairs an interrupted file/index update on the next index load or mutation. If saving a turn fails, it stays visible with **Retry storage write**; retrying storage never repeats the HTTP turn.

**Security warning:** tokens, passwords, and cookies are stored in plaintext in device-local server profiles and conversation snapshots. This is not encrypted credential storage. Anyone who can access the app's local data may be able to recover these secrets. Deleting a server profile does not erase credentials captured in saved conversations; delete those conversations too, or reset all app data.

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
