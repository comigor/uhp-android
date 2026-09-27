# UHP Android

Android-only Flutter client for Unified Harness Protocol servers.

## Features

- Dark-first Material 3 UI with separate screens for servers, harnesses, tasks, history, and server sessions.
- Persistent server profiles, restored after restarting the app.
- Required API key authentication, with an optional Pangolin edge-token pair.
- Harness browser backed by `GET /api/harness/v1/harnesses`.
- Task creation backed by `POST /api/harness/v1/responses` with `stream: true` (SSE), live response text, tool activity, turn status, and token usage when reported by the server.
- Saved conversation history, including partial turns, and session continuation via the last assistant message's `previous_response_id`.
- **Stop** cancels the local stream and requests server cancellation with `POST /v1/sessions/{encodedSessionId}/cancel` when a session ID is known.
- Server-scoped session browsing, transcript import, and continuation linked to persistent local history.
- Per-request model overrides and faithful read-modify-write updates to harness default models.
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

### API key and optional Pangolin edge authentication

1. Create an API key in the server's **Settings → Keys**.
2. Open **Servers → Add server** and enter a display name, server **Base URL**, and **API key (required)**.
3. If Pangolin protects the server, fill both `P-Access-Token-Id` and `P-Access-Token` in **Pangolin edge authentication (optional)**. Otherwise leave both empty.
4. Tap **Test connection**, then return to the list and select the server. Each edit is saved immediately; there is no Save button. Connection tests save the result.

Every API request requires the API key and sends it as `Authorization: Bearer <apiKey>`. The optional Pangolin pair opens the edge proxy and does not replace the API key. Both edge headers are sent only when both fields are nonempty. Connection tests, harness loading, streamed turns, and cancellation use the same authentication pipeline, without authentication retries.

A profile without a nonblank API key shows **API key required**, even if it has an older successful connection result. Tapping that profile opens the editor instead of selecting it.

### Authentication errors

- **Missing API key:** `API key required`. Add the key before connecting.
- **HTTP 302 or 303:** `Edge sign-in required: add the Pangolin token pair for this server.` The app does not follow redirects; check the edge pair and server URL.
- **HTTP 401 with `error.type: authentication_error`:** `Server rejected the API key.` Check or replace the key in server Settings → Keys.
- **Other HTTP 401 responses:** the HTTP error includes a bounded response-body excerpt so an edge failure is not mislabeled as an invalid API key.

Errors appear in the snackbar and connection-test result. Authentication failures do not trigger the legacy non-streaming fallback.

**Add demo profile** creates a `HarnessRouter demo` template with `https://your-uhp-server.example`. Replace the placeholder, add an API key, and fill the optional Pangolin pair if needed before connecting. Startup remains empty on a fresh install.

### Existing profiles and conversations

Older profiles and conversation snapshots still load, but legacy authentication fields are ignored and never converted to API keys. Previously enabled Pangolin pairs are preserved; hidden pairs from other legacy modes are dropped. Add an API key to each migrated server profile before use. Local-only conversations retain their original server snapshot; start a new task to use an updated profile. Linked server sessions can refresh credentials from the saved profile when its ID and URL still match. Migration does not proactively rewrite every stored conversation file. Delete old conversations or clear app data to remove their old on-disk secrets.

## Usage flow

1. Add and select a server. Use its edit icon to change it or delete it.
2. Test the connection from the profile editor.
3. Load harnesses from the **Harnesses** screen.
4. Tap a harness to open **Tasks**.
5. Enter a prompt and run the task. Response text and tool activity update live; turn status and available token counts are shown. Use **Stop** to cancel a turn and retain its partial response. Moving the app to the background interrupts the active turn and saves its partial response rather than continuing work in the background.
6. Enter another prompt and use **Continue** to send the last assistant message's `previous_response_id` against the same local thread. For local-only threads, if that assistant message has no response ID, the next request starts a fresh turn in the same thread; it never reuses an earlier assistant's ID. Linked server sessions instead require the server's latest continuation ID, as described below. **New task**, or choosing a harness, starts a separate thread.
7. Open **History** to view saved conversations. Tap one to restore it; long-press and confirm to delete it. If its server profile was deleted, the transcript remains readable but continuation shows an error.

If the server rejects streaming with a non-200 response or an error before any other SSE event, the app retries once with `stream: false` for legacy servers. Authentication failures are handled first and never trigger this fallback. After an accepted event, it never retries the turn as a non-streaming request. A successful non-SSE JSON response containing a response ID or output is treated as a completed legacy response, not retried. Completed SSE turns finish immediately without waiting for the server to close the connection.

For a new local task, before `response.created` supplies a session ID, **Stop** can only close the local request. A linked server session already has an ID, so Stop can request cancellation once its response request has started. Cancellation accepts any 2xx, 404, or 409 as sent. Background interruption closes the connection without sending server cancellation, so the server may continue computing. There is no background service; saving partial output on a lifecycle notification is best-effort if the OS kills the process immediately.

## Sessions

Select a server, then open **Sessions**. The list shows title, model, status, harness name, and relative time when provided. Pull to refresh or use the refresh action; **Load more** passes the server cursor back unchanged. The harness filter limits the list to one harness. There is no polling; refresh manually to observe work completed elsewhere.

Opening a session fetches its detail and turns from `/v1/sessions/{sid}` and `/v1/sessions/{sid}/turns`. Transcript rendering tolerates missing and additional fields. It creates or reuses a local thread linked by server profile, server URL, and session ID. Opening the same session does not create duplicate local history. Fresh remote transcript rows are shown alongside unmatched locally saved turn pairs, including partials. Exact text/role matches retain local metadata; without stable server turn IDs, differing partial and final replies are retained separately rather than guessed to be identical. An empty transcript does not erase saved messages.

The linked conversation opens in **Tasks**. Continuation uses the server's `last_response_id` and `harness_id`, not the currently selected task harness. A fresh detail check before sending prevents continuation into a session already marked running or in progress; a missing continuation ID blocks sending rather than silently starting a different session. This check cannot prevent another client starting work immediately afterward; server-side concurrency checks remain authoritative. Completed replies update the linked continuation pointer and are saved through the same atomic thread/index write path as local tasks. Stop, background interruption, partial-output persistence, and storage retries work as for ordinary tasks.

Open a linked thread from **History**, then use its server-session action to refresh the server transcript and status. Running sessions show a live note and disable sending until refreshed. Browsing does not subscribe to another client's live output.

## Per-request model override

The composer model chip defaults to **Harness default**: no `model` field is sent. Choose a model to override it for a request, including session continuations. Model choices come from `/v1/harnesses/{hid}/models`, falling back to `/v1/models` when the per-harness catalogue is unavailable or empty. This override does not change the saved harness configuration.

## Model management

In **Harnesses**, use the model-edit action for a harness. The editor shows its current default and read-only `maxStep` / `timeoutSeconds` when available. Choose a model and save to change its default for subsequent requests that omit a model override.

Saving first fetches the complete harness from `/v1/harnesses/{hid}`, changes only `defaultModel`, then PUTs the full object back. Required `name` and immutable `base`, plus MCP servers, skills, plugins, environment, disabled tools, headers, and unknown fields are preserved. The returned `defaultModel` must match the requested value; otherwise the app reports an error. These other fields are not editable here. Read-modify-write has no cross-client conflict protection unless provided by the server; avoid simultaneous configuration edits.

## Local persistence and security

Server profiles are stored on the device with `shared_preferences` under the key `servers_v1`. Conversations are saved as JSON files in the app's documents directory at `threads/<id>.json`. A lightweight `threads/index.json` lists saved conversations; full thread files are loaded lazily when opened rather than loading every conversation at startup.

Completed, cancelled, interrupted, and failed streamed turns are saved automatically, including partial response text, turn status, response and session IDs, and token usage when available. Local-only threads use the last assistant message's response ID for continuation; a missing ID is not replaced by one from an earlier turn. Linked threads persist `serverSessionId`, `serverHarnessId`, `serverLastResponseId`, and `serverSessionStatus`, and refresh the server pointer before sending. Older saved messages without turn metadata load as completed. Opening a saved conversation restores its server and harness snapshot so it can be continued after restarting the app. Deleting a conversation removes both its thread file and its index entry.

Thread files and the index are written using temporary files and atomic renames. A small pending-entry journal repairs an interrupted file/index update on the next index load or mutation. If saving a turn fails, it stays visible with **Retry storage write**; retrying storage never repeats the HTTP turn.

**Security warning:** API keys and Pangolin tokens are stored in plaintext in device-local server profiles and conversation snapshots. This is not encrypted credential storage. Anyone who can access the app's local data may be able to recover saved credentials, including obsolete secrets in older files that have not been rewritten or deleted. Deleting a server profile does not erase credentials captured in saved conversations; delete those conversations too, or reset all app data.

Android cloud backup and device-transfer rules exclude app storage, keeping these local copies device-local. Malformed or obsolete profile JSON is logged without credentials, discarded, and loaded as an empty list. Malformed history index JSON yields an empty list; a malformed thread yields an unavailable-conversation error rather than a crash.

To reset saved profiles and history, use Android **Settings → Apps → UHP Android → Storage → Clear storage / Clear app data** (labels vary by device). This removes locally stored data; it does not revoke credentials or delete data on the server.

Persistence uses preferences and files, not a database. There are no background services, polling, or background save timers.

## Known v1 limits

- Saved credentials and conversation snapshots are not encrypted.
- Server-session transcripts use tolerant text rendering, not rich server-specific event rendering.
- No background services, polling timers, wakelocks, or push.

## CI

`.github/workflows/android.yml` runs analyze and tests on pull requests, pushes to `main`, and tag pushes matching `v*`. Pushes to `main` also build a release APK artifact. Tag pushes build the APK and attach it to a GitHub Release.

## Roadmap

- Proper release signing via GitHub secrets.
- Richer response rendering for non-text output blocks.

## License

MIT.
