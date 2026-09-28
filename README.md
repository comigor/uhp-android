# UHP Android

Android-only Flutter client for Unified Harness Protocol servers.

## Features

- Dark-first Material 3 UI opening directly into a unified sessions feed, with no bottom tabs. Chat and Settings are one action away.
- Persistent server profiles and remembered server, per-server harness, and feed filter, restored after restarting the app.
- Required API key authentication, with an optional Pangolin edge-token pair.
- Harness configuration in Settings, backed by `GET /api/harness/v1/harnesses`.
- Task creation backed by `POST /api/harness/v1/responses` with `stream: true` (SSE), live response text, tool activity, turn status, and token usage when reported by the server.
- Saved conversation history, including partial turns, and session continuation via the last assistant message's `previous_response_id`.
- Assistant Markdown with selectable text, language-labelled fenced code, horizontal code scrolling, and **Copy code**; prompts, titles, and feed rows remain literal text.
- Device-local conversation rename, archive/unarchive, and deletion, plus per-server session hiding with restoration in Settings.
- **Stop** cancels the local stream and requests server cancellation with `POST /api/harness/v1/sessions/{encodedSessionId}/cancel` when a session ID is known.
- Server-scoped session browsing, transcript import, and continuation linked to persistent local history.
- Collapsed per-turn tool timelines with selectable arguments, retained in saved transcripts.
- Client-side feed search and loaded-chat search with occurrence highlights and previous/next navigation.
- Per-request model overrides and faithful read-modify-write updates to harness default models.
- Session workspace browsing, changed-file diagnostics, streamed downloads and ZIP exports with native Android open/share actions.
- Native multi-file attachments (25 MiB per file), authenticated uploads, and durable transcript attachment chips.
- Explicit public-link publishing/revocation and confirmed server-session cancellation.
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

Local builds remain debug-signed unless a release keystore is configured through the environment. CI can use a persistent release key from GitHub secrets; see **Release signing** below.

## Server setup

### API key and optional Pangolin edge authentication

1. Create an API key in the server's **Settings → Keys**.
2. On first launch the server editor opens automatically. For additional profiles, open **Settings → Servers → Add server** and enter a display name, server **Base URL**, and **API key (required)**.
3. If Pangolin protects the server, fill both `P-Access-Token-Id` and `P-Access-Token` in **Pangolin edge authentication (optional)**. Otherwise leave both empty.
4. Return to the feed. Each edit is saved immediately; there is no Save button. **Test connection** is optional and saves its result, but is never required to open the feed. The last-used server is selected automatically, falling back to the first saved profile.

Every API request requires the API key and sends it as `Authorization: Bearer <apiKey>`. The optional Pangolin pair opens the edge proxy and does not replace the API key. Both edge headers are sent only when both fields are nonempty. Connection tests, harness loading, streamed turns, and cancellation use the same authentication pipeline, without authentication retries.

A profile without a nonblank API key shows **API key required**, even if it has an older successful connection result. Tapping that profile opens the editor instead of selecting it.

### Authentication errors

- **Missing API key:** `API key required`. Add the key before connecting.
- **HTTP 302, 303, 307, or 308:** `Edge sign-in required: add the Pangolin token pair for this server.` The app does not follow redirects; check the edge pair and server URL.
- **HTTP 401 with `error.type: authentication_error`:** `Server rejected the API key.` Check or replace the key in server Settings → Keys.
- **Other HTTP 401 responses:** the HTTP error includes a bounded response-body excerpt so an edge failure is not mislabeled as an invalid API key.

Errors appear in the snackbar and connection-test result. Authentication failures do not trigger the legacy non-streaming fallback.

**Add demo profile** creates a `HarnessRouter demo` template with `https://your-uhp-server.example`. Replace the placeholder, add an API key, and fill the optional Pangolin pair if needed before connecting. Startup remains empty on a fresh install.

### Existing profiles and conversations

Older profiles and conversation snapshots still load, but legacy authentication fields are ignored and never converted to API keys. Previously enabled Pangolin pairs are preserved; hidden pairs from other legacy modes are dropped. Add an API key to each migrated server profile before use. Local-only conversations retain their original server snapshot; start a new task to use an updated profile. Linked server sessions can refresh credentials from the saved profile when its ID and URL still match. Migration does not proactively rewrite every stored conversation file. Delete old conversations or clear app data to remove their old on-disk secrets.

## Usage flow

1. Launch into **Sessions** on your last-used server (or the first saved profile). If none exists, the app opens the server editor. Use the Settings gear to add, select, edit, or delete profiles.
2. Browse **All** server sessions, newest-first, or choose a harness chip. **On-device** shows locally saved conversations without requesting the server session list. The selected filter persists across restarts.
3. Tap **New chat**. A server with one harness opens the composer directly; multiple harnesses open a chooser with each name, base label, and default model. The last-used harness is highlighted (or the first available one). Tap a row or confirm **Start chat** to save that choice for the server and create a local thread with **Harness default** selected for the model. Cancel leaves the thread and preference unchanged. Catalog failures in the chooser have an inline **Retry**; an unavailable server or empty harness list leaves the feed visible with an inline error and a Settings action.
4. Enter a prompt and send it. Response text and tool activity update live; turn status and available token counts are shown. Use **Stop** to cancel a turn and retain its partial response. Moving the app to the background closes the local stream without cancelling server work. A turn with a known response ID is saved with its partial output as **Server still working…**, then checked when the app resumes.
5. Enter another prompt and use **Continue** to send the last assistant message's `previous_response_id` against the same local thread. For local-only threads, if that assistant message has no response ID, the next request starts a fresh turn in the same thread; it never reuses an earlier assistant's ID. Linked server sessions instead require the server's latest continuation ID, as described below. **New task** starts a separate thread using the current harness.
6. Back returns to the feed; its **Current chat** action reopens the active thread without interrupting a turn. Open **On-device** to restore a saved conversation. Its overflow menu offers rename, archive/unarchive, and delete; long-press starts multi-selection instead. If its server profile was deleted, the transcript remains readable but continuation shows an error.
7. **Settings** is one scrollable page containing **Servers**, **Harnesses**, **Updater**, and **About**. Harness default-model editing and the existing updater are available there.

If the server rejects streaming with a non-200 response or an error before any other SSE event, the app retries once with `stream: false` for legacy servers. Authentication failures are handled first and never trigger this fallback. After an accepted event, it never retries the turn as a non-streaming request. A successful non-SSE JSON response containing a response ID or output is treated as a completed legacy response, not retried. Completed SSE turns finish immediately without waiting for the server to close the connection.

## Background continuation

For a new local task, before `response.created` supplies a session ID, **Stop** can only close the local request. A linked server session already has an ID, so Stop can request cancellation once its response request has started. Cancellation accepts any 2xx, 404, or 409 as sent. Backgrounding is different from Stop: it never sends server cancellation. If no response ID has arrived before backgrounding, the saved turn is marked failed with a recovery error because the app cannot look up that response, even though the server may still be working. There is no background service; saving partial output on a lifecycle notification is best-effort if the OS kills the process immediately.

On resume, including a cold restart, the app finds saved unresolved turns and checks each known response ID with `GET /api/harness/v1/responses/{responseId}`. While the app remains resumed, it checks again five seconds after an unresolved checking cycle finishes; it does not poll in the background. Polling is limited to these saved unresolved turns, not all server sessions or another client's work. The pending thread shows **Waiting for previous turn to finish on server**, disables its prompt, model control, and Continue button, and offers **Check now** for an immediate check. You can still browse other threads or start a new task. Partial text remains visible until completion. A completed response replaces the partial with its final output, even if empty; failed or cancelled responses retain the partial and show any reported error. Incomplete responses are marked failed with an explanation. Older saved interrupted turns remain interrupted and are not automatically polled.

## Sessions

The launch feed shows title, model, status, harness name, and relative time when provided. **All** requests sessions without a harness filter and displays newest-first; harness chips add a single-harness filter. Pull to refresh or use the refresh action; **Load more** passes the server cursor back unchanged. If loading fails, the feed and filters remain accessible with **Retry** and **Edit server** actions. The session list is not polled; refresh manually to observe work completed elsewhere. A saved server-continuing turn does not block browsing other sessions; only a live local turn or an unsaved turn blocks opening another session.

Opening a session fetches its detail and turns from `/api/harness/v1/sessions/{sid}` and `/api/harness/v1/sessions/{sid}/turns`. Transcript rendering tolerates missing and additional fields. It creates or reuses a local thread linked by server profile, server URL, and session ID. Opening the same session does not create duplicate local history. A linked thread with an unresolved local server-continuing turn keeps its saved transcript until response polling settles that turn, so a session refresh cannot overwrite pending output or status. Otherwise, fresh remote transcript rows are shown alongside unmatched locally saved turn pairs, including partials. Exact text/role matches retain local metadata; without stable server turn IDs, differing partial and final replies are retained separately rather than guessed to be identical. An empty transcript does not erase saved messages.

The linked conversation opens in **Chat**. Continuation uses the server's `last_response_id` and `harness_id`, not the currently selected task harness. A fresh detail check before sending prevents continuation into a session already marked running or in progress; a missing continuation ID blocks sending rather than silently starting a different session. This check cannot prevent another client starting work immediately afterward; server-side concurrency checks remain authoritative. Completed replies update the linked continuation pointer and are saved through the same atomic thread/index write path as local tasks. Stop, background continuation, partial-output persistence, and storage retries work as for ordinary tasks.

Open a linked thread from **On-device**, then use its server-session action to refresh the server transcript and status. This refresh action is disabled while a locally saved turn is server-continuing; use **Check now** instead. Other running sessions show a live note and disable sending until refreshed. Browsing does not subscribe to another client's live output.

## v0.9.0: conversational behavior

### Live response feedback and scrolling

Before the first assistant text arrives, the active turn shows **Agent is working…**. Once text arrives, a static caret is painted at its tail without modifying Markdown, copied text, or code fences. Both indicators disappear when the local stream ends; neither adds a blinking timer or background work.

New turns follow the live response tail, including when it grows beyond the viewport or the keyboard changes the available height. Scrolling manually in either direction, or navigating a chat-search match, detaches follow so incoming text does not move the scroll position. A floating down-arrow appears only while a live turn is detached; tap it to return to the tail and resume following. Saved history keeps its existing newest-first order and lazy rendering.

### Per-conversation drafts

Unsent prompt text is saved locally after a 275 ms typing debounce and flushed on chat changes, leaving the composer, and app lifecycle transitions. Reopening a conversation restores its own draft, including after restarting the app. A new task receives its own local identity before its first send. Attachment selections are not restored after leaving the composer or restarting.

Drafts use separate atomic records, so transcript refreshes and late completed turns cannot overwrite them. Validation and attachment-upload failures retain the text. A send clears its submitted draft before response dispatch, not after the stream ends; cancellation before dispatch restores it without overwriting newer typing. Like transcripts, drafts are plaintext in private app storage and are removed with the local conversation. An immediate process kill before the debounce or lifecycle flush completes can lose the latest keystrokes.

### Message actions

Long-press a user or assistant message for **Copy full text**, **Share**, or **Select text**, in local and linked chats and chat-search results. Copy and Android text sharing use the complete original message source, preserving whitespace and Markdown markers. **Select text** returns to native partial selection; long-pressing a card's non-text area offers a selectable source dialog. Existing code-copy controls, Markdown links, and attachment chips remain available. Text sharing does not publish a server-side share link.

## v0.8.0: tool timeline and search

### Tool timeline

Fetched assistant turns with tools show a collapsed **Tools (N)** chip. Expand it to see calls in server order, each with its name and a compact argument summary. Full arguments are selectable monospace text: valid JSON is pretty-printed, while invalid JSON remains literal. Arguments are decoded and their widgets built only after expansion. Each turn expands independently, including when navigating search matches.

Tool names and exact argument strings from the turns endpoint are saved with the local transcript and survive reopen, refresh, and continuation. Older transcripts and turns without tools remain readable and show no chip. Only tool arguments are displayed; the client does not invent results or execute tool content. Tool arguments may contain sensitive data and have the same plaintext local-storage exposure as the conversation. Live SSE activity is unchanged; fetched transcript tools provide the stored timeline.

### Feed search

Tap **Search sessions** in the feed app bar. A case-insensitive substring query matches session titles or the first line of the first user message, combined with **All**, the chosen harness, or **On-device**. Typing is debounced by 250 ms; clearing restores the current unsearched list immediately. **X**, Escape, or Android Back closes and clears search. Changing server or leaving the feed also clears it.

Search uses only already-loaded session cards or local summaries: it never fetches transcripts or pages to find matches. Server cards use `user_prompt`; a card without it remains searchable by title. **Load more** remains explicit. With a nonempty query, **Select all filtered** selects only matching loaded rows, respecting hidden/archived/running restrictions. Local summaries retain a first-user-line preview; old indexes are backfilled once from their local thread files, preserving unavailable rows and unrelated metadata.

### Chat search

Choose **Chat options → Search in chat** for either a linked server chat or an On-device thread. The pinned search bar searches loaded saved message text, literally and case-insensitively, and shows the current occurrence and total. Up/down arrows navigate with wraparound in newest-first display order; Enter advances. Each occurrence is highlighted and the active occurrence has a distinct color. Indexed lazy slivers jump directly to distant variable-height messages without constructing the intervening history.

While a query is nonempty, saved messages use selectable plain-text highlights rather than Markdown. **X** or Escape clears matches and restores normal rendering. Changing thread or leaving Chat closes search; queries are not persisted. Search never requests older server turns and does not search live stream activity, tool arguments, or attachment contents. No dependencies, background workers, or polling were added for these features.

## Session files and attachments

In a linked server chat, **Files** opens the workspace browser. **New this turn** requests `GET /api/harness/v1/sessions/{sid}/files?changed=true`; turn cards also offer **View files**, including failed and cancelled turns, so diagnostic artifacts remain accessible. Pull to refresh the list. A server response explicitly saying the session has no workspace is shown as an empty state; other failures remain errors.

Tap a file to stream its authenticated `/api/harness/v1/containers/{sid}/files/{fileId}/content` response into private cache, then open it with Android. **Download all (.zip)** streams the session archive, respecting the changed-files filter. Progress and cancellation are available; failed/cancelled transfers remove partial files. **Share file** uses Android's share sheet, including when no viewer supports the downloaded type. Only a temporary read grant for the selected cached file is exposed; API credentials and server-provided download URLs are never handed to external apps. Completed downloads remain cache files and may be reclaimed by Android.

The paperclip uses Android's document picker with multiple selection. Local-only chats show **attachments need a server session**; open the corresponding session from the server feed to use these tools. Each selected file is copied into private cache off the UI thread, capped at 25 MiB, and represented by a removable chip. Sending uploads each file to `/api/harness/v1/files` with `purpose=user_data`, then appends `<attachment id=file_… filename=…>` note lines to the outgoing prompt. An attachment-only prompt is allowed. Upload failures retain the draft for retry; once a turn is recorded, the draft copies are discarded. Removing a chip or leaving the composer also discards its private copy. Process termination can leave cache files until Android reclaims them; no persistent document URI permission is retained.

Saved user messages retain the original prompt and attachment IDs, names, byte sizes, and MIME types, not the augmented transport input or cached paths. Chips survive reopening and transcript reconciliation. Older messages without attachment metadata remain readable. This note-line transport requires server support for that convention; the client does not silently substitute structured `input_file` requests.

## Public sharing and session cancellation

In a linked chat, open **Session actions → Share…**. Opening the dialog only fetches the current share state. **Publish link** explicitly enables access after a warning that anyone with the link can read the conversation and its files. **Copy link** and **Share link** use the saved server origin and `/share/{token}`, never the API path, response-provided URL, or credentials. **Revoke link** disables public sharing; reopening fetches the server state again. Revocation cannot retract copies already downloaded by others.

**Session actions → Cancel session** requires confirmation and sends `POST /api/harness/v1/sessions/{sid}/cancel`. Success clears the active chat and returns to a refreshed feed; it does not delete the local transcript or server files. Unlike the in-turn **Stop** action, this action requires a successful 2xx response and reports 404/409 as errors. It is disabled during a live local turn or an unsaved turn, and confirmation rechecks those guards. Files, sharing, and cancellation are unavailable for local-only conversations. No new dependency, background task, or polling loop is added for these tools.

## Markdown rendering

Assistant messages render headings, emphasis, lists, links, tables, inline code, and fenced code. An unfinished fence is safe to render while a response streams. Code blocks retain whitespace, use a monospace font, scroll horizontally, show a language label when supplied, and offer **Copy code** without fence markers. Streaming deltas rebuild the active-turn card, not the saved transcript cards. Prompts, conversation titles, session-feed rows, and release notes remain plain text.

Links open a selectable URL dialog with **Copy link**, not an external browser. Image syntax becomes a plain resource description; untrusted output never fetches remote images or reads local image files.

The one new direct dependency is [`flutter_markdown_plus`](https://pub.dev/packages/flutter_markdown_plus) 1.0.12, the maintained community continuation of Flutter's Markdown renderer under the BSD-3-Clause license. It provides native Flutter widgets and established Markdown parsing, including incomplete fences, rather than an HTML/WebView renderer or a handwritten parser. Its only newly resolved transitive package is `markdown` 7.3.1; Flutter, `meta`, and `path` were already present. No syntax-highlighting or URL-launcher dependency is added. Flutter bundles dependency license notices into the app.

## Local conversation management

In **On-device**, tap a conversation's overflow menu:

- **Rename** persists a nonblank local title and updates the open chat header. A linked server session is never renamed; subsequent transcript refreshes and saved turns preserve the local title.
- **Archive** hides the conversation from On-device by default without deleting messages. **Show archived**, at the bottom of the list, reveals muted archived rows with **Unarchive** available in their menu. The visibility toggle resets when leaving the local list; the archive flag persists across restarts.
- **Delete** requires confirmation and removes the local thread file and index entry. Deleting the current chat clears it and leaves the feed visible. A linked session remains on the server and may be imported again.

On a server-session row, **Hide from feed** removes it only from that server profile's feed on this device. Hidden session IDs and display titles persist separately from thread files. They do not delete or archive an imported On-device copy, and do not alter pagination cursors. Restore individual entries under **Settings → Servers → Hidden sessions** for the corresponding profile. These actions never send server rename, archive, hide, or delete requests.

Long-press a feed row to enter multi-selection. The top bar shows the selected count; taps toggle checkboxes, and **X** or Android Back exits selection without leaving the feed. **Select all filtered** adds eligible rows from the current filter (including remaining server pages only when no text query is active, excluding hidden sessions and archived local rows unless **Show archived** is enabled). With a text query, only matching loaded rows are added. Selections survive filter switches, allowing mixed batches, but clear when changing server or leaving the feed. **Archive (N)** and **Delete (N)** apply only to selected On-device conversations; **Hide (N)** applies only to selected server sessions. Each count reflects that action's applicable rows. Delete confirms once for the batch; archive and hide do not confirm. Successful operations clear selection and show a summary. **Undo** restores the entire successful archive/hide batch without reverting unrelated titles, messages, or preferences; delete has no Undo. Storage errors report partial successes and preserve Undo for reversible changes that committed.

Swipe right on an active On-device row to archive, or left on an archived row to unarchive. Swipe right on a server-session row to hide it locally. Each gesture has a snackbar **Undo** and no confirmation. Swipes are disabled during selection and while busy/unsaved guards apply; vertical scrolling and pull-to-refresh remain available. Running rows cannot be selected or swiped, but can still be opened to inspect their progress.

Management actions are disabled with an explanation while a local turn is running or a completed turn still needs a storage retry. Local threads awaiting server completion cannot be renamed, archived, or deleted until settled. Action sheets and confirmation dialogs recheck these guards before applying changes.

## Per-request model override

The composer model chip defaults to **Harness default**: no `model` field is sent. Choose a model to override it for a request, including session continuations. Model choices come from `/api/harness/v1/harnesses/{hid}/models`, falling back to `/api/harness/v1/models` when the per-harness catalogue is unavailable or empty. This override does not change the saved harness configuration.

## Model management

In **Settings → Harnesses**, use the model-edit action for a harness. The editor shows its current default and read-only `maxStep` / `timeoutSeconds` when available. Choose a model and save to change its default for subsequent requests that omit a model override.

Saving first fetches the complete harness from `/api/harness/v1/harnesses/{hid}`, changes only `defaultModel`, then PUTs the full object back. Required `name` and immutable `base`, plus MCP servers, skills, plugins, environment, disabled tools, headers, and unknown fields are preserved. The returned `defaultModel` must match the requested value; otherwise the app reports an error. These other fields are not editable here. Read-modify-write has no cross-client conflict protection unless provided by the server; avoid simultaneous configuration edits.

## Local persistence and security

Server profiles are stored on the device with `shared_preferences` under the key `servers_v1`. Conversations are saved as JSON files in the app's documents directory at `threads/<id>.json`. A lightweight `threads/index.json` lists saved conversations and their first-user-line search previews. Full threads are loaded when opened, scanned for unresolved turns when recovery checks run, and read once to backfill previews for older index entries.

Navigation preferences are stored separately under `app_preferences_v1`: the last server ID, last harness ID per server, feed filter, and hidden-session IDs/titles grouped by server profile. Missing or malformed preferences use defaults without discarding profiles or conversations. A deleted remembered server falls back to the first saved profile; a missing remembered harness highlights the first available harness in the new-chat chooser. Multi-selection and Undo are transient; completed management changes persist.

Completed, cancelled, server-continuing, and failed streamed turns are saved automatically, including partial response text, turn status, errors, response and session IDs, and token usage when available. Older interrupted records are preserved. Local-only threads use the last assistant message's response ID for continuation; a missing ID is not replaced by one from an earlier turn. Linked threads persist `serverSessionId`, `serverHarnessId`, `serverLastResponseId`, and `serverSessionStatus`, and refresh the server pointer before sending. Older saved messages without turn metadata load as completed. Opening a saved conversation restores its server and harness snapshot so it can be continued after restarting the app. Deleting a conversation removes both its thread file and its index entry.

Thread files and the index are written using temporary files and atomic renames. A small pending-entry journal repairs an interrupted file/index update on the next index load or mutation. If saving a turn fails, it stays visible with **Retry storage write**; retrying storage never repeats the HTTP turn.

**Security warning:** API keys and Pangolin tokens are stored in plaintext in device-local server profiles and conversation snapshots. This is not encrypted credential storage. Anyone who can access the app's local data may be able to recover saved credentials, including obsolete secrets in older files that have not been rewritten or deleted. Deleting a server profile does not erase credentials captured in saved conversations; delete those conversations too, or reset all app data.

Android cloud backup and device-transfer rules exclude app storage, keeping these local copies device-local. Malformed or obsolete profile JSON is logged without credentials, discarded, and loaded as an empty list. Malformed history index JSON yields an empty list; a malformed thread yields an unavailable-conversation error rather than a crash.

To reset saved profiles and history, use Android **Settings → Apps → UHP Android → Storage → Clear storage / Clear app data** (labels vary by device). This removes locally stored data; it does not revoke credentials or delete data on the server.

Persistence uses preferences and files, not a database. There are no background services or background save timers. Response polling runs only while the app is resumed and only while saved unresolved turns need checking.

## Known v1 limits

- Saved credentials and conversation snapshots are not encrypted.
- Assistant text supports Markdown; non-text server-specific events are not rendered as rich media.
- No background services, background polling, wakelocks, or push.

## Updates

Open **Settings → Updater**, then choose **Check for updates** from its menu. The app checks the latest non-draft, non-prerelease GitHub release without sending server API keys or Pangolin tokens. An equal or newer local version shows **Up to date**; a newer release shows its tag and scrollable plain-text release notes. Network errors, GitHub rate limits, and releases without a downloadable APK are reported in snackbars.

Choose **Download & install** to stream the APK into the app's private temporary cache. The dialog shows download progress; **Cancel** aborts the request and removes the partial APK. On Android 8 and later, Android may first ask you to enable **Allow from this source** for UHP Android. Return to the app after granting consent and it resumes the pending installation attempt. If you decline permission, start the update again when ready. Android's installer still requires your confirmation; the app never installs silently. Completed APKs remain in the cache so the installer can read them and may be reclaimed by Android.

Checks are manual to avoid startup network traffic, polling, background services, and battery use. The app performs no automatic update checks when opened or resumed; resuming only continues an installation you already requested. Version comparison uses the first three numeric components, treating missing or nonnumeric components as zero. CI embeds `APP_VERSION` from the branch/tag name; local builds default to `v0.0.0-dev` unless built with, for example, `--dart-define=APP_VERSION=v0.8.0`.

Android requires the new APK to have the same signing key as the installed app. CI uses the persistent release key when signing secrets are configured, otherwise it falls back to debug signing, which may differ between runners/builds. Switching from an older debug-signed installation to a different release key cannot update that installation in place. Avoid uninstalling merely to work around a signing mismatch unless you accept losing locally stored app data.

## CI

`.github/workflows/android.yml` runs analyze and tests on pull requests, pushes to `main`, and tag pushes matching `v*`. Pushes to `main` also build a release APK artifact. Tag pushes build the APK and attach it to a GitHub Release.

## Release signing

One-time setup, on a trusted machine with a JDK:

1. In a private directory outside this repository, generate a release keystore (or reuse the original signing key if one already exists):

   ```bash
   keytool -genkeypair -v -keystore uhp-release.jks -storetype JKS -alias uhp-release -keyalg RSA -keysize 2048 -validity 10000
   base64 < uhp-release.jks | tr -d '\n' > uhp-release.jks.base64
   ```

   `keytool` prompts for passwords; keep them out of shell history. If the key password is the same as the keystore password, use that value for both password secrets below.

2. In the repository's **Settings → Secrets and variables → Actions**, add all four repository secrets:

   | Secret | Value |
   | --- | --- |
   | `KEYSTORE_BASE64` | The complete contents of `uhp-release.jks.base64` |
   | `KEYSTORE_PASSWORD` | The keystore password |
   | `KEY_ALIAS` | The signing key alias (`uhp-release` in the example) |
   | `KEY_PASSWORD` | The signing key password |

3. Keep a secure, durable backup of the original keystore, alias, and passwords. Delete the temporary base64 copy after configuring the secret. Never commit either file or upload it as a workflow artifact; base64 is encoding, not encryption.

Both APK build jobs decode the keystore into `$RUNNER_TEMP/keystore.jks` and export `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` through `$GITHUB_ENV`. When `ANDROID_KEYSTORE_PATH` identifies an existing file, Gradle creates and selects the `ci` signing configuration using those values. Supply all four secrets together. Missing or incorrect passwords are not a reason to silently substitute a debug key.

When `KEYSTORE_BASE64` is absent, the preparation step exports nothing and the build retains debug signing. Gradle also selects debug signing when `ANDROID_KEYSTORE_PATH` is unset or does not identify an existing file. Local `flutter run` and `flutter build` behavior is unchanged with these environment variables unset; configuring the same four variables locally enables release-key signing for release builds. Configuration logs report the selected signing mode, never the credentials.

**Rotation warning:** losing the signing key means no more in-place updates for installations signed with that key. Replacing it with a newly generated key also breaks that update path. Keep the original key safe and reuse it across releases; do not regenerate it for each build.

## Roadmap

- Completed: persistent release signing via GitHub secrets, with debug fallback when absent.
- Richer response rendering for non-text output blocks.

## License

MIT.
