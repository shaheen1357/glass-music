# Music — Unified Spec & Build Roadmap

**Design principle:** Apple Music's *exact* UI/UX shell (tab bar → Library sub-sections + Search + swipe-up Now Playing sheet + mini-player + long-press/⋯ menus), with the **full feature sets of both Apple Music and Spotify** folded in, plus **owned-library superpowers** — all bolted on as optional sections/settings.
**Guardrail (from research):** never turn this into a dense foobar2000/Neutron technical UI. Keep the flow; deepen the substance.

**Honest constraints:**
- I (the assistant) can't compile/run iOS or hear audio. Between-phase testing = CI compile + XCTest (CI simulator) + adversarial review agents. Real UI/audio testing is the user's, after the final build.
- **True bit-perfect output isn't possible** through AVAudioEngine's mixer (always Float32). We target native-rate, minimal-resampling hi-res, not bit-perfect.
- The AVAudioEngine rewrite is the one high-risk phase (I can't verify audio) — it's scheduled late, done as an isolated swap, with the working AVPlayer path kept as a fallback.

---

## Phase 0 — DONE (built, review-clean, awaiting push)
Library (AM layout) · Songs/Albums/Artists sort+search · Playlists (create/delete/**pin**/sort/search/**edit name+description+custom cover**/reorder/remove/**suggested songs**) · **Liked Songs + Podcasts** · **Love** · **per-row ⋯ menu** (Play/Play Next/Play Last/Add to Playlist/Love/Sleep Timer) · Now Playing (scrubber/transport/shuffle/repeat/volume/AirPlay/heart/**close+swipe-down**) · **Queue** (add/next/reorder/remove/clear) · **Sleep Timer** · **Settings** · **song count + total time** · Apple-Music icon · background audio + lock-screen · FLAC/ALAC/hi-res via AVPlayer.

## Phase 1 — Library & Playlist power  *(no playback risk)*
- Sort/group by **Date Added / Year / Genre / Composer** across views; **per-filter sort memory**
- **Pin up to 20**; **playlist folders** (create/nest/move)
- **Play counts + Recently Played + Most Played + resume last track/position**
- **Smart Playlists** (rules: filter + sort + limit, auto-updating; render as normal playlists)
- **M3U/M3U8 import + export**; **Favorites** view
- **Folder browsing** as one optional Library row (respects on-disk structure)

## Phase 2 — Queue & Now Playing depth  *(low risk)*
- Two-section queue: **Next in queue** (manual) vs **Next from [source]**
- **Album shuffle**; up-next **history** back-stack
- **Embedded + .lrc synced lyrics** in Now Playing (import/edit .lrc)
- **Go to Album / Go to Artist** from ⋯ and Now Playing; full Now Playing ⋯ menu
- **Artist detail** screen (top songs, albums, singles)

## Phase 3 — File import & large-library performance  *(medium)*
- Import: **Files/iCloud · AirDrop/"Open in" · Wi-Fi web-upload**; folder import; auto-import of new files
- **Background metadata indexing**; SQLite/Core Data store; smooth scroll at 10k+ tracks
- **On-device tag editing** (write-back via a tagging lib); **missing-artwork fetch** (opt-in)

## Phase 4 — Audio engine (AVAudioEngine)  *(HIGH RISK — isolated swap + AVPlayer fallback)*
- Rewrite PlayerEngine internals to an AVAudioEngine graph, **same public API** (UI unchanged)
- **Gapless** (schedule-ahead, `.dataPlayedBack` callback) · **accurate seek** (frame math) · lock-screen elapsed-time contract · interruption/route/config-change handling
- **10-band Equalizer** (+ presets) · **Crossfade** (equal-power, dual player nodes) · **ReplayGain/Sound Check normalization** (tag-read) · **Mono**
- Turn the Settings "Audio" section from stubs into real controls
- Native-rate hi-res where hardware allows (setPreferredSampleRate + rebuild); documented non-bit-perfect

## Phase 5 — System integration & polish
- **CarPlay** (Apple audio template) · **WidgetKit** widgets (Recently Added/Most Played/Favorites/resume)
- **AirPlay 2** polish · sleep-timer **fade-out** · Dynamic Island/StandBy now-playing
- Nice-to-have: Apple Watch playback · Last.fm scrobbling · cloud/NAS (Dropbox/Drive/SMB) · lyric widgets

---

## Per-phase process
`build → CI compile → XCTest (CI simulator) → adversarial use-case review → fix → next`
The user pushes at each phase boundary to trigger the CI compile/Appetize build (a 30-sec action, not testing). Final human/device testing happens after Phase 5.

## Feature applicability notes (from research)
- **Skip (no local equivalent):** Smart/Automix/DJ/Autoplay recommendations, song/artist radio, collaborative playlists, Spotify Connect, saves/likes counts, Canvas, streaming-quality tiers, data saver.
- **Adapt (partial):** lyrics (embedded/.lrc only), share (file/card), device picker (AirPlay/BT), quality shown as file bitrate/lossless badge.
