# Music — a local hi-res player for iOS 26 (SideStore)

A SwiftUI music player styled after Apple Music, for playing your own local
files (**FLAC, ALAC, MP3, AAC, WAV, AIFF, M4A**). No iTunes, no cloud, no
subscription. Built to be installed with **SideStore** — the 7-day cert refresh
happens automatically on-device, so you never plug into a computer.

You **do not need a Mac.** A free GitHub account compiles the app in the cloud.

---

## What you get

- Apple-Music-style Library (Songs / Albums / Artists), Search, and a
  swipe-up Now Playing screen with artwork, scrubber, shuffle/repeat, queue,
  AirPlay + volume.
- Lock-screen & Control Center playback controls, background audio.
- Glassmorphism throughout — on iOS 26 the system bars pick up **Liquid Glass**
  automatically (it *is* the native look now), so it blends in.
- Custom white/purple iOS-7-style icon.

---

## Step 1 — Put the code on GitHub

1. Create a **free** account at github.com if you don't have one.
2. Make a **new repository** (Private is fine), e.g. `glass-music`.
3. Upload this whole folder. Easiest without git:
   - On the new repo page click **uploading an existing file**, then drag in
     everything here (keep the folder structure — including the `.github`
     folder; if the web uploader hides it, use GitHub Desktop instead).
   - Or with git:
     ```
     git init
     git add .
     git commit -m "Music app"
     git branch -M main
     git remote add origin https://github.com/<you>/glass-music.git
     git push -u origin main
     ```

## Step 2 — Let GitHub build the IPA

- Pushing to `main` triggers the **Build IPA** workflow automatically.
  (Or go to the **Actions** tab → *Build IPA* → **Run workflow**.)
- Wait ~3–6 min for the green check.
- Open the finished run → scroll to **Artifacts** → download
  **`Music-unsigned-ipa`**. Inside is `Music.ipa`.
- Download it **on your iPhone** (Safari can download it), or AirDrop it over.

> The IPA is intentionally **unsigned**. SideStore signs it with *your* Apple ID
> at install time — that's what makes the free 7-day sideload work.

## Step 3 — Install SideStore (one-time)

If you don't already have SideStore on the iPhone 12 mini:
1. Follow the official guide at **https://sidestore.io** (it walks you through
   the pairing + install using your free Apple ID).
2. Once SideStore is set up and shows your apps, it will **auto-refresh**
   sideloaded apps in the background over Wi-Fi — this is what kills the
   "re-sign every 7 days by hand" problem.

## Step 4 — Sideload the app

1. Open **SideStore** → **My Apps** → the **+** button.
2. Pick the `Music.ipa` you downloaded.
3. Sign in with your Apple ID if asked; let it install.
4. The purple-note **Music** icon appears on your home screen.

## Step 5 — Add your music

Three ways, all without a computer:
- **In-app:** tap **+** (top-right of Library) → pick files from Files/iCloud.
- **Files app:** *On My iPhone → Music* → drop `.flac`/`.alac`/`.mp3` in there
  (AirDrop into it, or paste from another folder). Then **pull down to refresh**
  in the app.
- **AirDrop** an audio file → *Save to Files* → the Music folder.

Metadata (title, artist, album, artwork) is read automatically from the file
tags.

---

## Customizing

- **Rename the app / bundle id:** edit `project.yml`
  (`PRODUCT_BUNDLE_IDENTIFIER`, `PRODUCT_NAME`) and `Support/Info.plist`
  (`CFBundleDisplayName`). Keep the bundle id unique to you.
- **New icon:** replace
  `Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png` (1024×1024, no
  transparency).
- **Accent color:** edit `Resources/Assets.xcassets/AccentColor.colorset/Contents.json`.

## Features (Apple Music look, Spotify function)

- **Library** (Apple Music layout): Playlists / Artists / Albums / Songs rows + a
  Recently Added grid. Songs & Albums have **Sort** (Recently Added / Title /
  Artist) and **Find in…** search.
- **Playlists**: create, rename-by-recreate, delete, **pin to top** (max 4,
  swipe or long-press), sort (Recently Added / Title), search.
- **Liked Songs** + **Podcasts** as default library items. **Love** any track
  from its context menu or the heart on the Now Playing screen.
- **Playlist screen**: Play / Shuffle, **Find in Playlist** search, **Sort By**
  (Playlist Order / Title / Artist / Album / Recently Added), **reorder** in
  Playlist Order, **Add Songs** (searchable), and **Suggested Songs** drawn from
  your library by shared artist/album.
- **Add to a Playlist…** from any track's context menu.

## Notes & limits (v1)

- Free Apple ID sideloads expire every 7 days — SideStore refreshes them for
  you. A paid ($99/yr) Apple Developer account bumps that to once a year.
- Podcasts is a manual collection (no RSS/feed subscriptions — that's a whole
  separate feature); add any audio to it like a playlist.
- FLAC/ALAC/hi-res PCM decode via the system codecs. Exotic formats (DSD, MQA)
  are out of scope.
- If the mini-player ever overlaps the tab bar on your iOS build, it's a
  one-line tweak in `Sources/Views/RootView.swift` (the `.safeAreaInset`).

## How it's structured

```
project.yml                 XcodeGen spec (defines the Xcode project as text)
Support/Info.plist          Background audio, file sharing, orientations
Resources/Assets.xcassets   App icon + accent color
Sources/
  App/MusicApp.swift        @main entry
  Models/Track.swift        Track / Album / ArtistGroup
  Library/LibraryStore.swift  Folder scan + metadata + artwork thumbnails
  Player/PlayerEngine.swift   AVPlayer engine, queue, remote/lock-screen controls
  Views/                    Library, Search, Now Playing, mini-player, queue
.github/workflows/build.yml GitHub Actions: builds the unsigned IPA
```
