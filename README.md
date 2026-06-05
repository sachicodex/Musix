# Musix

<p align="center">
  <img src="assets/icons/Musix%20-%20Windows.png" alt="Musix Logo" width="140" />
</p>

<p align="center">
  A modern music app for Gen Z and Gen Alpha — ad-free listening, smart recommendations, local + online playback, and a polished mobile & desktop experience.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-blue?logo=flutter" alt="Flutter Badge" />
  <img src="https://img.shields.io/badge/Dart-3.10+-0175C2?logo=dart" alt="Dart Badge" />
  <img src="https://img.shields.io/badge/Platform-Android%20%7C%20Windows%20%7C%20Desktop-2ea44f" alt="Platform Badge" />
  <img src="https://img.shields.io/badge/Auth-Firebase-FFCA28?logo=firebase" alt="Firebase Badge" />
</p>

## Download

| Platform | Package | Link | Notes |
|---|---|---|---|
| Android | APK | [Latest Release](https://github.com/sachicodex/Musix/releases/latest) | Install from release assets on your device. |
| Windows | EXE installer | [Latest Release](https://github.com/sachicodex/Musix/releases/latest) | Recommended install; includes custom window chrome and system media controls. |
| Linux / macOS / iOS | Build from source | [Run From Source](#run-from-source) | Use Flutter build commands for your target platform. |

## About

Musix helps you listen your way:
- Sign in with email/password and sync likes, dislikes, and taste profile to the cloud.
- Stream Music with smart bitrate selection and playback caching.
- Scan and play local audio (MP3, FLAC, WAV, and more).
- Get personalized home sections, search, playlists, and a full queue.
- Control playback from the mini player, full player, Android notifications, or Windows media keys.
- Tune preload, region, sleep timer, and data usage from Profile.

## Preview

<p align="center">
  <img src="assets/icons/Musix%20-%20Full.png" alt="Musix Brand Preview" width="560" />
</p>

> Add `assets/img/preview-desktop.png` and `assets/img/preview-mobile.png` for full UI screenshots in this section.

## Features

| Icon | Feature | What you get |
|---|---|---|
| &#127925; | Stream & discover | Search, trending, and online playback |
| &#128193; | Local library | Scan folders and play common audio formats from device storage. |
| &#128100; | Account + cloud sync | Firebase Auth with Firestore-backed likes, dislikes, and preference profile. |
| &#127911; | Personalized home | Sections like May You Like, Top Artists, Jump Back In, and context-based rails. |
| &#128218; | Library & playlists | Cached songs, downloads, and user playlists in one place. |
| &#128266; | Queue & preload | Build a queue, swipe-to-add from search, and preload upcoming tracks. |
| &#128276; | Media controls | Android playback notification and Windows system media integration. |
| &#128187; | Desktop layout | Sidebar navigation, content panels, and optional now-playing rail. |

## Mobile Gestures

| Gesture | Action |
|---|---|
| Swipe left/right on main shell | Switch tab (left = next, right = previous): Home → Search → Library → Profile. |
| Swipe left on search result | Add song to queue. |
| Swipe left/right on player (fast horizontal flick) | Next / previous track. |
| Swipe up on player (fast vertical flick) | Open queue sheet. |
| Swipe down on player (fast vertical flick) | Close player and return to previous screen. |
| Pull to refresh on Library | Rescan / refresh library content. |

## Desktop Keyboard Shortcuts

| Key | Action |
|---|---|
| `Space` | Play / pause (when not typing in a text field). |
| `Ctrl`/`Cmd` + `1` | Go to Home |
| `Ctrl`/`Cmd` + `2` | Go to Search |
| `Ctrl`/`Cmd` + `3` | Go to Library |
| `Ctrl`/`Cmd` + `4` | Go to Profile |
| `S` | Focus search |
| `L` | Like current song |
| `D` | Dislike current song |
| `Arrow Up` | Open full player (when a song is playing) |
| `Arrow Left` / `Arrow Right` | Previous / next track (in player) |
| `Q` | Open queue (in player) |
| `Arrow Down` | Close player (in player) |

## How to Use

1. Open the app and sign in (or create an account).
2. Browse **Home** for recommendations and quick picks.
3. Use **Search** to find songs, artists, or trending tracks.
4. Open **Library** to scan local music, manage playlists, or play cached/offline songs.
5. Tap a track to play; use the mini player to expand the full player.
6. Swipe a search result right-to-left (or use queue actions) to add songs to the queue.
7. Open **Profile** to adjust region, preload count, sleep timer, and sign out.
8. Like (`L`) or dislike (`D`) tracks to improve future recommendations.

## Run From Source

### Prerequisites

- Flutter SDK (Dart 3.10+)
- Firebase project with Email/Password auth and Cloud Firestore
- Android: `google-services.json` in `android/app/`
- Optional: Windows dev tools for desktop builds

### Setup

```bash
git clone https://github.com/sachicodex/Musix.git
cd Musix
flutter pub get
flutter run
```

### Common run targets

```bash
flutter run -d android
flutter run -d windows
flutter run -d linux
flutter run -d macos
```

### Build release packages

```bash
# Android APK
flutter build apk --release

# Windows installer
flutter build windows --release
```

### Windows Installer (Inno Setup)

Musix uses a normal Inno Setup EXE installer instead of MSIX.

Prerequisites:
- Install **Inno Setup 6**.
- Build the Windows release first: `flutter build windows --release`.

The installer script is saved at:

```text
installer\Musix.iss
```

To compile from VS Code:

1. Press `Ctrl + Shift + B`.
2. Choose `Release: Build Windows Installer`.
3. VS Code runs the Flutter Windows release build, then compiles `installer\Musix.iss`.
4. The setup EXE is created at `installer\Output\Musix-Setup.exe`.

To compile from Inno Setup:

1. Open `installer\Musix.iss` in Inno Setup Compiler.
2. Click **Compile**.
3. The setup EXE is created at `installer\Output\Musix-Setup.exe`.

Script Wizard settings used for Musix:

| Wizard page | Value |
|---|---|
| Application name | `Musix` |
| Application version | `4.3.17` |
| Publisher | `Sachicodex` |
| Destination base folder | `(Custom)` |
| Custom destination folder | `{localappdata}\Programs` |
| Application folder name | `Musix` |
| Install mode | Non administrative install mode, current user only |
| Main executable | `build\windows\x64\runner\Release\Musix.exe` |
| Other application files | Add the full `build\windows\x64\runner\Release` folder |
| File association | Disabled |
| Start Menu shortcut | Enabled |
| Desktop shortcut option | Enabled |
| Documentation files | Blank |
| Registry import file | Blank |
| Output base file name | `Musix-Setup` |
| Setup password | Blank |
| Preprocessor directives | Enabled |

This installs to:

```text
%LOCALAPPDATA%\Programs\Musix
```

That keeps installation user-friendly and avoids requiring admin rights.

## Setup A-Z (Firebase Auth + Firestore)

### 1. Create a Firebase project

In [Firebase Console](https://console.firebase.google.com/):
1. Create a new project (or reuse an existing one).
2. Enable **Authentication** → **Email/Password** sign-in method.
3. Create a **Cloud Firestore** database (production or test mode for development).

### 2. Register app platforms

Add apps for each platform you target:
- **Android** — package name: `com.sachicodex.Musix`
- **Windows** — as needed for desktop Firebase options
- **Web / iOS / macOS** — if you plan to ship those targets

### 3. Configure FlutterFire

From the project root:

```bash
dart pub global activate flutterfire_cli
flutterfire configure
```

This generates `lib/firebase_options.dart` and platform config files.

### 4. Add Android Firebase files

1. Download `google-services.json` from Firebase Console.
2. Place it at `android/app/google-services.json`.
3. Confirm the Google Services Gradle plugin is applied (already wired in this project).

Build/run Android:

```bash
flutter run -d android
```

### 5. Firestore data model (overview)

User documents store:
- Liked / disliked song IDs
- Preference profile (artists, genres, moods, languages, listening signals)
- Profile metadata (`email`, `displayName`, `schemaVersion`, `updatedAt`)

Cloud sync runs after sign-in and keeps local playback preferences aligned with your account.

### 6. Login flow test (end-to-end)

1. Run the app (`flutter run -d android` or `flutter run -d windows`).
2. Create an account on the sign-up screen or sign in on login.
3. After auth, the app loads personalized home content and begins cloud preference sync.
4. Play a few tracks and like/dislike songs to update your taste profile.
5. Sign out from Profile to verify session cleanup.

If Firebase is not configured, the app shows a **Firebase Setup Required** screen with setup steps instead of the auth flow.

## Playback & Notifications

- **Streaming**: Resolves playback URLs with ranked fallbacks; optional local proxy caching reduces re-buffering.
- **Android**: Media-style playback notification with transport controls when a track is active.
- **Windows**: System media controls integration for play/pause/skip from the OS shell.
- **Permissions**: Notification permission may be requested on Android when playback starts.
- **Windows note**: the Inno Setup installer (`installer\Musix.iss`) is the recommended distribution format.

## Supported Local Audio Formats

`mp3`, `flac`, `ogg`, `wav`, `m4a`, `aac`, `opus`, `wma`, `aiff`, `alac`

WhatsApp/Telegram media folders are excluded from automatic library scans.

## Project Structure

```text
lib/
  main.dart              App bootstrap, Firebase init, window setup
  core/                  Controller, models, playback, library scan, theme
  services/              Firebase Auth and Firestore user data
  screens/               Auth gate, login/signup, Firebase setup
  ui/
    shell/               App shell, navigation, shortcuts
    features/            Home, search, library, player, profile
    features/desktop/    Desktop shell, sidebar, screens, widgets
assets/
  icons/                 App logos (Android, Windows, full)
  images/                Genre artwork
  fonts/                 General Sans, SF Pro Display
```

## Tech Stack

| Area | Tech |
|---|---|
| App | Flutter |
| State management | Provider (`ChangeNotifier`) |
| Playback | `media_kit`, `media_kit_libs_*` |
| Streaming | `youtube_explode_dart`, `ytmusicapi_dart` |
| Local tags | `audiotags` |
| Auth & cloud | Firebase Auth, Cloud Firestore |
| Desktop window | `window_manager` |
| Windows packaging | Inno Setup |
| Connectivity | `connectivity_plus` |

## Publisher

| Field | Value |
|---|---|
| Display name | Musix |
| Publisher | Sachicodex |
| Package ID | `com.sachicodex.Musix` |
| Version | 4.3.17 |

## Support

- Issues: [GitHub Issues](https://github.com/sachicodex/Musix/issues)
- Repository: [github.com/sachicodex/Musix](https://github.com/sachicodex/Musix)
