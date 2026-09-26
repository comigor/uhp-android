# UHP Android

Flutter Android client for the Unified Harness Protocol (UHP).

## What it does

- Stores a small in-memory list of UHP servers for the current app session.
- Supports two auth modes:
  - Pangolin machine token via `P-Access-Token-Id` and `P-Access-Token` headers.
  - Console login via `POST /api/selfhost/login` and cookie reuse on later calls.
- Loads harnesses from `GET /api/harness/v1/harnesses`.
- Sends task prompts to `POST /api/harness/v1/responses`.
- Supports continuation with `previous_response_id`.
- Shows HTTP failures as snackbars with status and body excerpt.

History is in memory for v1 only. No database.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

## Server setup

1. Open **Servers**.
2. Add a server name and base URL.
3. Pick auth mode:
   - **Pangolin machine token**: fill token id and token.
   - **Console login cookie**: fill username and password, then log in against your server side flow.
4. Select the server and use **Test connection**.

## Notes

- The release APK is debug-signed in v1 for sideloading.
- Proper release signing via repository secrets is a later task.
- App history is session-local and is lost on process death.
- Impeller stays on; nothing here disables it.

## Roadmap

- Persist server profiles.
- Persist session history.
- Add better auth UX for console login.
- Add release signing secrets and uploaded signed artifacts.
