# Spotify setup

This fork uses Spotify Authorization Code with PKCE. It does **not** contain a
Spotify client secret. Tokens are kept in platform secure storage.

## Dashboard configuration

1. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), create an app, and copy its **Client ID**.
2. In the app settings, add this exact Redirect URI:

   ```text
   musify://spotify/callback
   ```

   It must match exactly (including case and no trailing slash). Android's deep
   link handler is declared in `android/app/src/main/AndroidManifest.xml`.
3. Do not put a client secret in this project. Build/run with the Client ID:

   ```powershell
   flutter run --flavor github --dart-define=SPOTIFY_CLIENT_ID=YOUR_CLIENT_ID
   ```

   For a release APK:

   ```powershell
   flutter build apk --release --flavor github --dart-define=SPOTIFY_CLIENT_ID=YOUR_CLIENT_ID
   ```

## Permissions

- `user-read-private` obtains the connected account identity.
- `playlist-read-private` finds a prior private `lieblingsmusik` playlist and
  reads its current items for deduplication.
- `playlist-modify-private` creates and updates the private playlist.

No password is requested or stored. Disconnect removes local tokens and the
local playlist association; it never deletes the Spotify playlist.

## Development-mode limitation

Spotify apps begin in Development Mode. At the time of writing, the app owner
must have Premium; only five allowlisted Spotify accounts can use the app, and
non-allowlisted users can receive 403 responses. Add test users from the
Dashboard's **Users Management** settings. Spotify rate-limits development
apps; the UI reports rate-limit failures so the sync can be safely run again.

## Local verification

```powershell
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
flutter build apk --release --flavor github --dart-define=SPOTIFY_CLIENT_ID=YOUR_CLIENT_ID
```

The sync collects the actual Musify liked songs plus songs in custom playlists,
requires a title and artist, searches Spotify with both fields, accepts only an
exact normalized title plus compatible artist match, then adds canonical track
URIs in batches of at most 100. Existing playlist content is preserved.
