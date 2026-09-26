# UHP Android

Android-only Flutter client for Unified Harness Protocol servers.

## Features

- Dark-first Material 3 UI with separate screens for servers, harnesses, and tasks.
- In-memory server profiles for the current app run only.
- Pangolin machine-token auth via `P-Access-Token-Id` and `P-Access-Token` headers.
- Console login auth via `POST /api/selfhost/login`, cookie capture from `Set-Cookie`, and cookie reuse on later requests.
- Harness browser backed by `GET /api/harness/v1/harnesses`.
- Task creation backed by `POST /api/harness/v1/responses` with `stream: false`.
- Session continuation via `previous_response_id`, preserving an in-memory thread view.
- Error snackbars showing HTTP status and parsed `error` or `detail` text where available.
- 300 second timeout on every network call.

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

1. Open **Servers**.
2. Choose **Pangolin machine token**.
3. Enter a display name and server base URL.
4. Fill `P-Access-Token-Id` and `P-Access-Token`.
5. Save the server.
6. Select it and tap **Test connection**.

### Console login

1. Open **Servers**.
2. Choose **Console login cookie**.
3. Enter a display name, base URL, username, and password.
4. Save the server.
5. Select it and tap **Test connection**.
6. The app posts credentials to `/api/selfhost/login`, captures `Set-Cookie`, then reuses that cookie for later API calls.

## Usage flow

1. Save and select a server.
2. Test the connection from the **Servers** screen.
3. Load harnesses from the **Harnesses** screen.
4. Tap a harness to open **Tasks**.
5. Enter a prompt and run the task.
6. Enter another prompt and use **Continue** or **Continue latest** to send `previous_response_id` against the same thread.

## Known v1 limits

- History is memory-only and disappears on process death.
- Server profiles are not persisted.
- Model override is intentionally omitted; the server default model is used.
- No background services, polling timers, wakelocks, or push.

## CI

`.github/workflows/android.yml` runs analyze and tests on pull requests, pushes to `main`, and tag pushes matching `v*`. Pushes to `main` also build a release APK artifact. Tag pushes build the APK and attach it to a GitHub Release.

## Roadmap

- Persist server profiles.
- Persist conversation history.
- Optional per-request model selection.
- Proper release signing via GitHub secrets.
- Richer response rendering for non-text output blocks.

## License

MIT.
