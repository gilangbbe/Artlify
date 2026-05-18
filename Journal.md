# Engineering Journal — Artlify

> Chronological log of every non-trivial decision, experiment, and lesson learned.
> Append new entries to the **top**. Never edit past entries; correct them with a follow-up entry.

Entry template:

```
## YYYY-MM-DD — <Short title>
**Decision / change:**
**Reason:**
**Impact:**
**Follow-up:**
```

---

## 2026-05-19 — `particles` branch: SCK removal + no-sound fix + Apple Music (MusicKit) integration — karaoke phase 2 cycle complete

**Decision / change:**
Three changes in one slice that together close out karaoke phase 2 for the installation deployment.

(1) **Removed `ScreenCaptureKit`-backed system-audio capture entirely.** `SystemAudioCapture.swift` deleted; `AudioReactor.InputSource` reduced to `.microphone` + `.audioFile`. The HUD source picker is now two icons (mic ↔ music note) instead of three. Justification from on-hardware testing: the mic, pointed at the installation speakers, already gives a clean and *honest* reactive signal — it picks up exactly what the audience hears, including the room acoustics, which is in fact more interesting visually than a pristine tap from the OS mixer. Plus no TCC prompt, no SCK availability check, no SCStream / display-config gymnastics, no entitlements drift.

(2) **Fixed "no sound" on the local audio-file player.** Two independent root causes, both in `AudioFilePlayer`:

   (a) `engine.mainMixerNode` is lazily constructed on first access and auto-connects itself to `outputNode` at the *first* format it sees. Inside `load(url:)` we were attaching the player node and then accessing the mixer, which let the mixer→output auto-connect land at the player's `processingFormat` instead of the hardware's native format. On some macOS configurations this silently produces no audio. **Fix:** touch `mainMixerNode` *and* `outputVolume` once in `init()` so the mixer→output edge is established at the hardware format before any player attaches.

   (b) `stop()` was calling `engine.stop()` on every transport stop. Stopping and restarting the engine between plays tears down internal connections on macOS 26.x; after the first play, subsequent ones play silently even though the player thinks it's running. **Fix:** `stop()` now only stops the *player node* and removes the tap. The engine stays running idle (no audio flows while no player is scheduled, so the CPU cost is nil) and the next `play()` Just Works.

(3) **Wired Apple Music via MusicKit** as a third (and primary, for the installation) music source. Two new files:

   - `AppShell/MusicKitClient.swift` (~85 lines): thin wrapper around `MusicAuthorization.request()` + `MusicCatalogSearchRequest(term:types:[Song.self])`. `ensureAuthorized()` is idempotent and short-circuits when already authorized; `searchSongs(query:limit:)` clamps to MusicKit's 25-result server max and bubbles up a localised `MusicKitError` enum so the search sheet can render error states cleanly.
   - `AppShell/MusicKitPlayer.swift` (~150 lines): `@Observable @MainActor final class MusicKitPlayer`. Wraps `ApplicationMusicPlayer.shared`. Published `currentTime`, `duration`, `isPlaying`, `isActive`, `currentSongTitle`, `currentSongArtist`, `lastError`. `play(song:)` sets `player.queue = [song]` and awaits `try await player.play()`; `pause` / `resume` / `stop` / `seek` are direct delegations; a 10 Hz internal `Task`-based poll loop mirrors `player.playbackTime` + `state.playbackStatus` onto the published props. The poll cancels on `stop()` and self-cleans via `[weak self]` when the player is dropped (no explicit `deinit` — `@MainActor` deinit + cancel-from-nonisolated would have needed `nonisolated(unsafe)` plumbing for one line of teardown).

`MusicSearchSheet` extension:
- `MusicSearchResult` grew a `kind: MusicResultKind` discriminator (`.demo` / `.lrclib` / `.appleMusic(Song)`). The Apple Music case carries the actual `Song` value, so the caller can re-play it without a second `MusicCatalogResourceRequest` round-trip.
- New `.appleMusic` case in `MusicSearchSource` enum (Demo / LRCLIB / Apple Music). Default source switched from `.demo` → `.appleMusic` because that's what the installation visitor expects to see first.
- New pink `APPLE MUSIC` source badge.
- `runSearch()` gained an `.appleMusic` branch that calls `MusicKitClient.searchSongs(query:)` and maps each `Song` to a `MusicSearchResult` with `lrc: ""` (lyrics are looked up later, per-song, by title+artist via LRCLIB).
- Per-source placeholder copy in the search field, empty-state text, and footer hint.

`ContentView` wiring:
- New `@State private var musicKit = MusicKitPlayer()`.
- Sheet `onSelect` switches on `result.kind`. For `.appleMusic`: stops the local file player, ensures mic source + running (analysis path), sets the now-playing pill, calls `await musicKit.play(song:)`, then concurrently does a best-effort `LRCLibClient.search(track:artist:)` for synced lyrics — if found, drops them through `LRCParser.parse` into `karaoke.track`; if not, the song plays without lyrics but the HUD still works.
- The 60 Hz karaoke timer's source-priority ladder is now: `musicKit.isActive` → `audioFile.fileURL != nil` → wall-clock integrator. The MusicKit branch also mirrors `musicKit.isPlaying` back onto `karaokePlaying` so the HUD play/pause icon tracks whatever the system player decides (e.g. if the OS pauses for a phone call).
- Transport controls (play/pause, stop, scrub slider, timecode/duration labels) all branch on `musicKit.isActive` and forward to `musicKit.resume() / pause() / stop() / seek(to:)` when it owns the timeline. The disable predicate on transport buttons grew from `karaoke.track == nil` to `karaoke.track == nil && !musicKit.isActive` so the controls stay live for songs that have no LRC available.
- File-load and Apple-Music branches both call `.stop()` on the other player to prevent two audio sources fighting.

Infrastructure:
- Added `<key>com.apple.developer.musickit/<true/>` to `Artlify.entitlements`.
- Added `INFOPLIST_KEY_NSAppleMusicUsageDescription = "Artlify lets visitors search Apple Music and play their chosen song as the karaoke source.";` to **both** Debug and Release build configurations in `project.pbxproj`.

**Reason:**
The installation context is the driver: visitors walk up, type the name of *their* song, and expect to hear it within seconds — same flow they have on every phone they own. A static demo catalog (Stage 1) or even a LRCLIB-only catalog (Stage 1.5: lyrics but no audio) breaks that expectation. The MusicKit catalog is what makes "any song they want" literal — Apple's full catalog, ranked by Apple's relevance model, surfaced through the same search sheet that already worked for demo/LRCLIB rows.

Why we kept LRCLIB even after wiring MusicKit:
- Apple Music's lyrics API on macOS isn't accessible without an extra entitlement (Music Lyrics API) that personal Apple Developer teams can't request. LRCLIB has full coverage for popular songs and zero auth. So lyrics fetch is post-pick (`LRCLibClient.search(track: title, artist: artist)`), which costs one HTTP round trip after song selection — much cheaper than searching LRCLIB on every keystroke.

Why analysis stays on the mic for Apple Music:
- `ApplicationMusicPlayer` runs in a separate XPC daemon; it does *not* expose audio buffers to our process. Tapping its node is not a thing. The mic listening to the speakers (the same path that's worked since v1) is the right answer here — same physical sound the audience hears.

Why no-sound on file playback was the priority before shipping MusicKit:
- The file player was the *test path* — if it played silent locally we'd never be able to validate audio I/O independent of MusicKit's signing/permissions stack. Fixing both `mainMixerNode` lazy-init order and the `engine.stop()` between-plays issue means future audio work can trust the pipeline.

Why we deleted SCK instead of just hiding the picker entry:
- The mic-on-speakers path being "good enough" was the real test. Once confirmed, every line of SCK code was technical debt: TCC prompt UX, SCStream's permission revocation handling, the noisy "Dropping frame" log workaround, and the macOS-13 availability check guarding it. Subtract, don't accumulate.

**Impact:**
- Code builds clean (verified `xcodebuild ... CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`).
- Signing & runtime require: paid Apple Developer Program membership, the installation Mac registered as a dev device, the App ID `com.biru.Artlify` provisioned with the MusicKit capability in the Apple Developer portal, *and* a signed-in Apple Music subscription on the installation Mac. These are deployment prerequisites, not code issues.
- Karaoke HUD: source picker shrunk from 3 icons (mic / speaker / file) → 2 icons (mic / file). Search sheet default source = Apple Music. Three search backends coexist behind one row.
- File player no longer goes silent on the second play, on any test file we tried.
- Two new files (~85 + ~150 lines), one deleted file (`SystemAudioCapture.swift`), `AudioReactor` shrunk by ~80 lines (the system-audio branch + capture wiring), `ContentView` grew by ~70 lines (MusicKit state + sheet branch + timer priority + transport mirroring), `MusicSearchSheet` grew by ~60 lines (third source case throughout).

**Follow-up (if any):**
- Recently-played MusicKit songs surfaced in the empty state when the search query is blank — saves the visitor retyping after the previous person.
- Real artwork in result rows via MusicKit `Artwork` URLs + `AsyncImage` (currently we render an SF Symbol `applelogo` placeholder).
- `MusicSubscription.subscriptionUpdates` watch — if the Apple Music subscription lapses or the user signs out, immediately surface a banner in the search sheet instead of failing on play.
- Auto-extract title/artist from local `AVAsset` metadata on file-load to try the LRCLIB lookup for local files too (currently they fall back to the sample LRC).
- Persisted in-process queue: tap several songs into a queue instead of replacing on every pick. Less of a single-visitor feature, more of a between-visitors-keep-playing feature.
- Re-evaluate killing the `.demo` source case now that we have two live sources. It's useful for offline iteration but clutters the picker; could move it behind a debug toggle.

---



**Decision / change:**
Two changes in one slice. (1) Silenced the noisy `_SCStream_RemoteVideoQueueOperationHandlerWithError:1459 stream output NOT found. Dropping frame` log spam by registering a no-op `.screen` output alongside the existing `.audio` one in `SystemAudioCapture` — SCStream produces video frames internally regardless of subscribers and complains if there's no `.screen` sink to drop them into. The existing `didOutputSampleBuffer` already filters to `.audio` type, so the screen frames hit the delegate and get dropped on the floor without further processing.

(2) Built the local-audio-file playback slice: load any mp3/m4a/wav/aac/flac, the player owns the karaoke timeline with sample-accurate precision, and the analysis pipeline sees the file's audio directly (no mic, no SCK, no permissions).

New file `AudioKit/AudioFilePlayer.swift` (~220 lines):
- `@Observable final class AudioFilePlayer: @unchecked Sendable` with `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioFile`.
- Published: `fileURL`, `fileName` (basename without extension, for the HUD pill), `duration`, `currentTime`, `isPlaying`, `lastError`.
- `load(url:)`: `stop()`s any previous file, opens via `AVAudioFile(forReading:)`, disconnects/reconnects the player node to the main mixer at the *new* file's `processingFormat` (avoids "format mismatch" between tracks with different SR / channel counts), resets `seekOffsetSamples = 0`, and installs a fresh tap on the player node at bus 0.
- `play()`: starts engine if needed, schedules `(file, startingFrame: seekOffsetSamples, frameCount: remaining)` to end-of-file with a completion handler that flips `isPlaying = false` and fires `onFinished` (guarded against the case where the user already paused / seeked / loaded a new file in between).
- `pause()`, `stop()` — clean teardown including engine stop.
- `seek(to:)`: clamps to `[0, duration]`, stops the player, updates `seekOffsetSamples`, restarts iff we were playing.
- `handleTap(buffer:time:)`: (a) forwards the buffer to `onAudioBuffer?` for the reactor; (b) converts the player node's `lastRenderTime` → `playerTime(forNodeTime:)` and adds `seekOffsetSamples` to get the absolute file position, then publishes it onto the main actor as `currentTime`.
- `runOpenPanel()` static helper: `@MainActor` `NSOpenPanel` configured for `.mp3 / .mpeg4Audio / .wav / .aiff / .audio` UTTypes.

`AudioReactor` extension:
- Added third `InputSource` case `.audioFile`. Unlike mic / system, this case **owns no engine** — the reactor is purely a consumer for externally-pushed buffers.
- `startAudioFile()` is just `isRunning = true` + log line; the buffer producer (typically `AudioFilePlayer`) is wired separately.
- New `public func ingest(buffer: AVAudioPCMBuffer)`: routes external buffers straight into the existing `handleTap(buffer:)`. **Guarded by `source == .audioFile && isRunning`** so a stale player that's still firing tap callbacks after a source switch can't sneak frames into a different active source.
- `start()` / `stop()` dispatch updated for the new case.

`ContentView` wiring:
- New `@State private var audioFile = AudioFilePlayer()`.
- In `.onAppear`, set `audioFile.onAudioBuffer = { audio.ingest(buffer: $0) }` — always-on hook, safe because `ingest` no-ops when the source isn't `.audioFile`. Also `audioFile.onFinished = { karaokePlaying = false }` so the transport state flips when the file drains.
- In `.onDisappear`, stop the file player before tearing down `audio`.
- Karaoke 60 Hz timer: when `audioFile.fileURL != nil`, `karaoke.currentTime` is set from `audioFile.currentTime` instead of the wall-clock integrator. Net effect: pause / seek / track-end on the player **automatically** propagate to the lyric overlay — no flag-juggling required.
- New `file` button in `karaokeRow` (folder SF Symbol): pops the open panel, loads the file, switches the reactor source to `.audioFile`, ensures `audio.isRunning`, starts playback, sets the now-playing pill to `audioFile.fileName`, and if there's no LRC loaded yet falls back to `karaoke.loadSample()` (so even without lyrics the user gets the karaoke shell + reactive visuals against their file).
- Play / pause / stop / scrub in the karaoke row now mirror onto `audioFile`: pressing play resumes the file, scrubbing seeks the file. The audio and the karaoke wipe stay locked because they're both derived from the *same* `audioFile.currentTime`.
- Source picker grew a third tag (`music.note` SF Symbol) for `.audioFile`, width bumped from 80 pt → 120 pt to fit three icons.

**Reason:**
With LRCLIB + system audio, the user could already type a song, hit play in Spotify, and have lyrics + visuals respond to real music. But:
1. **Drift.** The karaoke time was a wall-clock integrator that started at 0 the moment they hit play. Spotify's actual playhead is somewhere unknown — they have to manually sync at song start and pray. After a few minutes of pause / seek / network hiccups, the lyrics are reliably ahead or behind by a noticeable amount.
2. **Audio source coupling.** System-audio capture needs a TCC permission grant and only sees what's actually playing through the OS mixer — i.e., it's a shared resource with whatever else the user is doing audio-wise.
3. **No offline path.** Without Internet (LRCLIB) *and* without an external player running, there was no way to test or demo the karaoke pipeline end-to-end.

This slice closes all three. Picking a file:
- Locks `karaoke.currentTime` to the player node's sample counter — drift is mathematically impossible because both the audio you hear and the lyric you see derive from the same `playerTime`. Pause, seek, end-of-track all propagate atomically.
- Bypasses TCC entirely — the analysis tap is installed on the in-process `AVAudioPlayerNode`, the reactor receives the same `AVAudioPCMBuffer`s the speakers will play, no system mixer in the picture.
- Works offline. Drop in an mp3 + an LRC (or use the sample LRC for now), boot the app on a plane, get the full karaoke experience.

Why the reactor needed a `.audioFile` source case at all (vs the file player just calling a public `ingest` regardless of source):
- The source enum is the single source of truth for "what's driving the reactor right now". Without a dedicated case, the HUD picker couldn't represent it, and there'd be ambiguity about whether the mic / SCK is *also* running concurrently (it shouldn't be — wasted work + competing FFT outputs into `latest`).
- The `source == .audioFile` guard on `ingest` is the protection against stale buffers: when the user switches from `.audioFile` back to `.systemAudio`, the file player's tap might still fire one or two more callbacks before its scheduled buffer drains. Without the guard, those would briefly contaminate the system-audio FFT path.

Specific design notes:
- `AVAudioFile(forReading:)` works directly on the sandbox-exempt URL `NSOpenPanel` returns — no need for `startAccessingSecurityScopedResource()` for in-session file picks; only matters if we add the recently-used-files menu later.
- `seekOffsetSamples` is the offset between the player node's per-schedule sample counter and the file's absolute position. `scheduleSegment(..., startingFrame: seekOffsetSamples, ...)` then `player.lastRenderTime → playerTime → sampleTime` gives us the sample *within this scheduling*, which we add to `seekOffsetSamples` to recover absolute time. This is the canonical CoreAudio pattern for "where am I in this file" and survives pause / resume cleanly because `lastRenderTime` keeps counting through pause.
- The tap is installed in `load(url:)` rather than `play()` so that even before the first `play()` the buffer format is correct and `removeTap` paths are symmetric. The tap fires *zero* callbacks while the player is paused or stopped (taps only see audio that's flowing), so leaving it installed across pauses is free.
- Engine stop is gated on `engine.isRunning` because stopping an already-stopped engine logs warnings in Console even though it's harmless functionally.
- `pause()` calls `player.pause()` not `player.stop()` — pause preserves the scheduled buffer + sample counter, stop wipes them. This is what lets `play()` after `pause()` Just Work without re-scheduling.
- The slider's `set:` handler now calls `audioFile.seek(to: newVal)` whenever a file is loaded. Without this, dragging the slider would move the lyric playhead but the audio would keep going from wherever it was, immediately giving a desync after a single drag.
- The "if no LRC loaded, fall back to `karaoke.loadSample()`" branch on file-open is deliberate: it means the user can drop in *any* audio file with zero search and immediately get the karaoke shell (mock LRC) + reactive visuals locked to that file. Useful for testing the reactor + overlays against arbitrary music.
- The source picker icon choice (`music.note` for file) intentionally mirrors the `music.note.list` on the sample button — visual rhyme that "this is the local-music path".

**Impact:**
- Build green, no warnings. SCK spam should be silenced; will need real on-hardware confirmation.
- Two new files (~220 + ~5 lines) plus reactor + ContentView wiring (~80 line delta).
- Karaoke is now functionally complete as an *offline* experience: pick file → load LRC (or sample) → everything stays locked.
- The reactor has three sources, all converging on the same FFT pipeline; the architecture has scaled cleanly from one-source to three-source without any pipeline duplication.
- The HUD's now-playing pill now does triple duty: LRCLIB-searched track title, sample loop name, or local file basename.
- Audio file path is fully sandbox-clean (NSOpenPanel + read-only file selection is already in the entitlements).

**Follow-up (if any):**
- MusicKit catalog search + `ApplicationMusicPlayer` slice (still pending) — would be a fourth source case with playback driven the same way as audioFile.
- Auto-pair LRCLIB lyrics with the loaded file by extracting title/artist from `AVAsset` metadata + searching LRCLIB on file-open. Right now picking a file falls back to the sample LRC, which is fine for the demo but disappointing in practice.
- Recently-used files menu — would need `startAccessingSecurityScopedResource()` + bookmark data persisted in `UserDefaults`.
- Waveform scrubber instead of plain slider — `AVAssetReader` extracts peak samples, render in the existing scrub-slider footprint. Would make seeking feel musical instead of timeline-y.
- Loop / A↔B repeat for practice mode — drop the karaoke time back when it crosses `loopEnd`, both `karaoke.currentTime = loopStart` and `audioFile.seek(to: loopStart)`.

---

**Decision / change:**
Made `AudioReactor` source-pluggable and added a ScreenCaptureKit-backed system-audio capture so the reactive layers respond to whatever the Mac is *actually playing* (Spotify, Music.app, YouTube, anything) instead of being limited to mic input. Source is switchable from the HUD with a one-click segmented picker (mic icon ↔ speaker icon).

New file `AudioKit/SystemAudioCapture.swift`:
- `final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate`, `@unchecked Sendable`, `@available(macOS 13.0, *)`.
- `start() async throws`: enumerates `SCShareableContent`, picks `displays.first`, builds an `SCContentFilter`, configures `SCStreamConfiguration` with `capturesAudio = true`, `sampleRate = 48_000`, `channelCount = 2`, `excludesCurrentProcessAudio = true`, and a deliberately tiny `2×2` 1 FPS video config (SCStream requires video dimensions but we never subscribe to the video output, so the compositor skips that work). Adds *only* `.audio` to `addStreamOutput`. Starts via `await s.startCapture()`.
- `stop() async`: awaits `stopCapture()`, clears the stream ref.
- `stream(_:didOutputSampleBuffer:of:)`: filters to `.audio` type, guards `CMSampleBufferDataIsReady`, converts the CMSampleBuffer to an `AVAudioPCMBuffer` via `makePCMBuffer(from:)`, fires `onAudioBuffer` callback.
- `stream(_:didStopWithError:)` delegate: SCStream tells us when capture dies (permission revoked mid-session, display disconnected, sandbox kill); we surface via `onStopped` on the main queue.
- `makePCMBuffer(from:)`: reads the CMSampleBuffer's `CMAudioFormatDescription`, builds an `AVAudioFormat` from the embedded `AudioStreamBasicDescription`, allocates an `AVAudioPCMBuffer` with the matching capacity, and calls `CMSampleBufferCopyPCMDataIntoAudioBufferList` to memcpy the samples in. SCStream gives Float32 non-interleaved by default on Apple Silicon — exactly what the existing FFT path consumes — so no conversion needed.
- `SystemAudioError: LocalizedError` enum (`noDisplay`, `permissionDenied`) for the rare unhappy paths.

`AudioReactor` refactor:
- Added nested `public enum InputSource: String, Sendable { case microphone, systemAudio }` and `public private(set) var source: InputSource = .microphone`.
- Split the old monolithic `start()` / `stop()` into `startMicrophone()` / `startSystemAudio()` / `stopMicrophone()` / `stopSystemAudio()`; public `start()`/`stop()` dispatch on `source`.
- New public `switchSource(_:)`: tears down the current source, swaps `source`, restarts if it was running. Safe to call when off (just stores the choice).
- `systemCapture: SystemAudioCapture?` lazy-constructed on first system-audio start so the ScreenCaptureKit overhead is only paid when the user actually chooses it.
- `startSystemAudio()` wires `capture.onAudioBuffer` into the existing `handleTap(buffer:)` — **the FFT / band / pan / transient pipeline is identical** for both sources, which is the whole point of the refactor. Also wires `capture.onStopped` to auto-fall-back to mic + surface `lastError`, so if the user revokes permission mid-session the visuals don't go dead.
- TCC failure path: optimistically flips `isRunning = true`, then if `await capture.start()` throws, on the main actor reverts `isRunning`, copies the error into `lastError` (using `LocalizedError.errorDescription` for SCStream's nicer messages), flips `source` back to `.microphone`, and starts the mic. Net effect: pick "system audio", get denied → mic just keeps working with the error visible in the HUD.

`ContentView.audioRow` got a segmented `Picker` between the on/off toggle and the strength slider:
- Two tags: `AudioReactor.InputSource.microphone` (mic SF Symbol) and `.systemAudio` (speaker SF Symbol).
- Bound to `audio.source` / `audio.switchSource($0)` so flipping is one click and immediately rewires the analysis pipeline.
- `.help(...)` tooltip explains the TCC requirement.

**Reason:**
LRCLIB landed real lyrics on the screen, but the audio-reactive layers (chromatic split width, head-blob string sag, particle field flow strength, lyric brightness, transient explosion jolts) were still being driven by the *microphone* — which means singing into the Mac to drive visuals that are supposed to feel synced to the music you just searched for. That's backwards. System-audio capture closes the loop: search the song on LRCLIB, hit play in Spotify (or wherever), and *every reactive layer* now pulses on the actual track.

Why ScreenCaptureKit specifically:
- It's the only public, sandbox-friendly, no-driver-install path to the system audio mix on modern macOS. The old aggregate-device / loopback-driver tricks (Soundflower, BlackHole, Loopback.app) all require kext or audio-driver installs the user has to do themselves.
- Permissions piggyback on the existing "Screen & System Audio Recording" TCC bucket — no entitlement plist edits, no developer-program capability changes. The first attempt triggers the system prompt; subsequent runs are silent.
- It hands us standard `CMSampleBuffer`s of PCM, which maps onto `AVAudioPCMBuffer` in ~20 lines of CoreMedia bridging. The reactor's FFT path doesn't need to know anything changed.

Why this slice now, before MusicKit:
- **Independent of music source.** Works with any music app the user has — Spotify Free, YouTube, Bandcamp, anything. MusicKit only handles Apple Music. Doing this first means the karaoke experience is functional for everyone before we add the Apple-Music-subscriber-only path.
- **Independent of subscription / region / auth.** TCC permission is a single yes/no the user gives once. MusicKit needs `MusicAuthorization.request()`, an Apple Music subscription on the signed-in user, and per-region catalogue availability.
- **Closes the most-noticed gap.** Without it, every reactive visual feels disconnected from the lyrics — they're synced to mic noise. With it, hitting play in any app immediately makes the chromatic split / head-blob string / particle swarm pulse with the track. The visual delta is immediate and obvious.

Specific design notes:
- The pluggable-source refactor was deliberately kept small: one enum, four lifecycle methods (start/stop × mic/system), one switch method, one shared `handleTap`. I considered building a `protocol AudioSource` with conforming `MicrophoneSource` / `SystemAudioSource` types, but at two sources that's premature — when the third source lands (e.g. an `AVAudioFile` for offline rendering) it's still a 10-minute refactor.
- `capturesAudio = true` + adding only `.audio` to `addStreamOutput` works, but ScreenCaptureKit still requires the filter to name a display. The 2×2 / 1 FPS video config is the minimum SCStream accepts; with no `.screen` output subscriber, the compositor short-circuits the actual video rendering.
- `excludesCurrentProcessAudio = true` means Artlify's own future playback won't loop back into its own reactor. Currently Artlify makes no sound, but this is the safe default and there's no reason to wait until it bites.
- The auto-fall-back-to-mic on `didStopWithError` is critical UX: the user can revoke Screen Recording permission *while the app is running* and TCC will silently kill the stream. Without the fallback, all the reactive layers would freeze at zero. With it, the user just sees "audio source switched back to mic" implicitly (the picker visually flips) and the error in the HUD explains why.
- The picker is *icon-only* with a tooltip rather than a labelled toggle because the audio row is already busy (toggle + strength slider + gain slider + 4-bar meter + error text). Two SF Symbols in a 80-pt segmented control reads instantly without taking row width.
- Optimistic `isRunning = true` before the async start was chosen over a separate `isStarting` flag because: (a) the UI never has to render a "starting…" state — the prompt modal is the affordance; (b) if the user clicks before SCStream resolves, the second click cleanly hits `guard !isRunning else { return }`; (c) the failure path reverts within tens of ms (TCC denial is fast, content enumeration is fast). The only visible glitch would be if SCStream took multiple seconds to start AND the user denied AND the meter showed activity in between — which it can't, because nothing's writing to `latest` yet.

**Impact:**
- Build green (one transient Swift 6 actor-captured-var warning hit and fixed by binding `guard let strong = self else { return }` *before* the `MainActor.run` closure instead of inside it — Swift 6 won't let you re-capture an inner `let self` for mutation inside an isolated closure).
- One new file (~190 lines) + AudioReactor refactor (~80 line delta). No new entitlements.
- First system-audio toggle in the HUD will trigger the TCC prompt. After grant, subsequent app launches start silently.
- Reactor stays running across source switches — `switchSource(_:)` only restarts the active source, the FFT scratch arrays and EMA state are preserved.
- Every visual that already consumes `audio.latest.{level,low,mid,high,transient,pan}` is now automatically driven by system audio when the picker is on speaker mode — no per-overlay changes needed. The chromatic split width, head-blob string sag, particle flow strength, lyric brightness, transient jolts, the works.

**Follow-up (if any):**
- MusicKit catalog search slice — third `MusicSearchSource` case, `MusicAuthorization.request()` flow, MusicKit capability in the entitlements file.
- `ApplicationMusicPlayer` slice — replaces the wall-clock `currentTime` integrator with `player.playbackTime`, so karaoke stays in lock-step on seek / pause / track-end. Only relevant once MusicKit is in.
- Surface the `lastError` text more visibly when source is `.systemAudio` and the user just denied — currently it's in the existing tiny red text on the audio row, which is easy to miss.
- Consider an "auto" mode that uses system audio when something is playing and falls back to mic when silent — would need `level > threshold` detection over a rolling window and is probably not worth the complexity until someone actually asks for it.

---

**Decision / change:**
Wired the music search sheet to a real lyrics provider: **lrclib.net**, the free no-auth public LRC database. The sheet now has a `Demo / LRCLIB` segmented picker; LRCLIB mode runs an async, debounced (350 ms) HTTP search and renders real time-synced lyrics for whatever song the user types.

New file `AppShell/LRCLibClient.swift`:
- `LRCLibTrack: Decodable, Identifiable, Hashable` — fields named to exactly mirror the upstream JSON (`id`, `trackName`, `artistName`, `albumName?`, `duration?`, `instrumental?`, `plainLyrics?`, `syncedLyrics?`) so `Decodable` synthesis works without `CodingKeys`.
- `LRCLibError: LocalizedError` — narrow enum: `badURL / transport(URLError) / http(Int) / decode(Error) / noResults / noSyncedLyrics`. Each carries a human `errorDescription` so the UI can render it without a switch at the call site.
- `enum LRCLibClient` (stateless, all `static async throws`):
  - `search(query:)` → GET `/api/search?q=...`
  - `search(track:artist:)` → GET `/api/search?track_name=…&artist_name=…` (precise variant for when MusicKit lands and we already know both fields)
  - `getByID(_:)` → GET `/api/get/{id}` (fallback path when a search summary lacks `syncedLyrics` but the full record has it)
  - Sets `User-Agent: "Artlify/1.0 (...)"` because LRCLIB rejects calls without a UA per their TOS.
  - 10 s timeout. `URLSession.shared`.

`MusicSearchSheet` rewrite:
- New `MusicSearchSource` enum (`.demo`, `.lrclib`) backing a `.segmented` Picker between the header and the search field.
- New `@State`: `source`, `results: [MusicSearchResult]` (now state, not derived), `isFetching`, `errorText`, `fetchTask: Task<Void, Never>?`. Removed the synchronous `results` computed property — the unified results array is now written by `runSearch()` on `@MainActor`.
- Debounced query: `.onChange(of: query)` cancels the in-flight task and schedules a 350 ms-delayed re-search, so we don't fire HTTP on every keystroke. `onSubmit` and source-change bypass the debounce via `refresh()`.
- Source badge is now colour-coded — **orange `DEMO CATALOG`** vs **green `LIVE — LRCLIB`** — so a glance at the header is enough to know whether you're looking at fake or live data.
- Three result states now properly distinguished: in-flight (inline `ProgressView` in the search field), empty (existing empty-state UI, with mode-specific copy), and error (orange triangle + the `LRCLibError`'s `errorDescription` + a `Retry` button).
- Footer hint now matches source: demo gets "all entries use the sample LRC", LRCLIB gets "Live results from lrclib.net (no auth, public DB)".
- `mapLRCLib(_:)` filters out hits without `syncedLyrics` — plain text is useless to the karaoke overlay, which needs time stamps to advance lines. Hits with only plain lyrics get silently dropped rather than offered and then breaking.
- LRCLIB mode with an empty query no-ops (clears results, no network call). Demo mode with an empty query returns the full catalog as before.

Selection path unchanged: tapping a row still calls `onSelect(MusicSearchResult)`, which `ContentView` already wires to `karaoke.track = LRCParser.parse(result.lrc)`. So LRCLIB lyrics flow into the existing karaoke engine via the *same* code path as the demo catalog — no overlay changes, no `KaraokeStore` changes.

**Reason:**
Last slice shipped the search UI surface against a mock catalog with the explicit promise that "stage 2 will replace this with MusicKit search + LRCLIB lyrics." This slice cashes in half of that promise — the lyrics half — without taking on MusicKit's entitlement / auth / subscription baggage. LRCLIB needs zero credentials and zero capabilities beyond the `com.apple.security.network.client` we already had for model downloads, so it lands as a strictly additive change.

Why LRCLIB before MusicKit:
- **Independent value.** LRCLIB on its own makes the karaoke engine actually useful — type a real song, get its real lyrics, sing along. MusicKit on its own (search + playback) without LRCLIB just gives us audio with no lyrics, which is what every other music player already does. Lyrics are the differentiator; ship them first.
- **Lower blast radius.** LRCLIB is one URLSession call + one Decodable. MusicKit is an entitlement edit, an `MusicAuthorization.request()` modal, an `ApplicationMusicPlayer` lifecycle, and per-region Apple Music availability. If we'd done MusicKit first and it broke for any subset of those reasons, we'd have nothing demoable.
- **Forces the unified result type to prove itself.** Mapping two different upstream shapes (`MockMusicCatalog` and `LRCLibTrack`) into the same `MusicSearchResult` validates the abstraction the previous slice introduced. When MusicKit `Song` shows up next, it'll be the third mapping into the same target — and the row layout, selection callback, and `KaraokeStore` integration all stay frozen.

Specific design notes:
- 350 ms debounce was chosen over `.searchable`'s built-in submit-only behaviour because the user-facing affordance is a freeform text field, not a search dialog — incremental-as-you-type feels native. 350 ms specifically because shorter (200 ms) fired requests mid-word for fast typers and longer (500 ms) felt like the field had stopped responding.
- Task cancellation on query change is critical: without it, a slow response for query `"weez"` could overwrite a fast response for `"weezer"`. `fetchTask?.cancel()` before scheduling the new one, plus an `if Task.isCancelled` check after the await, plus catching `CancellationError` separately, plugs all three races.
- `mapLRCLib` returning `nil` for instrumental / plain-only tracks means the empty-state UI fires even when LRCLIB returned hits, which is honest — from the user's standpoint, "there's no karaoke for this" and "no such track" are the same outcome. We could surface a distinct message ("found it but no synced lyrics") later if it becomes a complaint.
- User-Agent string is hardcoded with a fake repo URL. LRCLIB's TOS just wants *something* identifying; can swap to the real repo URL when we publish.
- `URLSession.shared` instead of a per-call session — fine at this scale; one user, one query at a time, no need for connection pooling tuning.
- `fetchTask?.cancel()` is also called in `.onDisappear`, so closing the sheet mid-fetch doesn't leak the task or fire a UI update against a now-gone view.

**Impact:**
- Build green. Untested against the live LRCLIB API on hardware.
- One new file (~155 lines) + a sheet rewrite. No new dependencies, no new entitlements.
- The sheet is now functionally complete for lyrics: the user can search for any song LRCLIB has and immediately karaoke to it against the camera feed.
- Audio is still mic-driven; the user has to hum or play the song from a separate device for the audio-reactive layers to respond. The MusicKit + ApplicationMusicPlayer slice will close that loop by driving both `karaoke.currentTime` *and* the audio source from the in-app player.
- The unified `MusicSearchResult` shape has now survived two upstream mappings (mock + LRCLIB), so it's earned its keep as an abstraction rather than premature decoration.

**Follow-up (if any):**
- MusicKit catalog search slice — adds `import MusicKit`, the MusicKit capability in the entitlements, a `MusicAuthorization.request()` flow, and a third `MusicSearchSource.appleMusic` case. After it lands, picking an Apple Music hit should chain into `LRCLibClient.search(track:artist:)` so we get audio (from MusicKit) and lyrics (from LRCLIB) in one tap.
- `ApplicationMusicPlayer` slice — drives `karaoke.currentTime` from `player.playbackTime` instead of the wall-clock integrator, so karaoke stays locked even on seek / pause.
- ScreenCaptureKit slice — taps system audio into `AudioReactor` so the reactive layers respond to whatever's actually playing.
- Real artwork via `MusicKit.Song.artwork.url(width:height:)` → `AsyncImage` in the row's artwork tile slot.
- LRCLIB has a `/api/get` precise endpoint by `track_name + artist_name + album_name + duration` — worth using once MusicKit gives us all four with confidence, since it returns one record instead of a ranked list.

---

**Decision / change:**
Sliced the next phase-2 surface: a music-search sheet (`AppShell/MusicSearchSheet.swift`) plus an expanded karaoke control panel on the main HUD. **Pure UI, no network**: results come from a hardcoded `MockMusicCatalog` (5 tracks, all currently backed by `LRCParser.sample`) so we can iterate on the search/select experience without touching MusicKit, LRCLIB, or permissions.

New file `AppShell/MusicSearchSheet.swift`:
- `MusicSearchResult: Identifiable, Hashable` — `id`, `title`, `artist`, `durationSeconds`, `artworkSystemImage` (SF Symbol stand-in), `lrc` (inline payload). Field shape deliberately matches what MusicKit's `Song` exposes (title, artistName, duration) so the stage-2 swap is a 1-for-1 mapping.
- `MockMusicCatalog.all` — 5 fake tracks ("Artlify Demo Loop", "Still Frame", "Silhouette", "Shockwave", "ASCII Rain") with thematic artist names and SF Symbol artwork. `search(_:)` does case-insensitive substring filter across title + artist.
- `MusicSearchSheet` view:
  - Header bar: title + a bold orange "DEMO CATALOG" badge so it's loud that these aren't real catalog hits — preempts "why is my song missing".
  - Search field with magnifying-glass icon, plain `TextField`, inline clear button.
  - `LazyVStack` of result rows (artwork tile + title/artist stack + duration + play/check icon). Picking a row briefly highlights it (`pickedID` state, 120 ms delay) before calling `onSelect` + `onClose` — long enough for the colour change to register without feeling laggy.
  - Empty state when filter returns nothing.
  - Footer hint: "Stage 2 will replace this with MusicKit search + LRCLIB lyrics."
  - Frame: 460–520 × 420–520 with `.regularMaterial` background.

Wiring in `ContentView`:
- New state: `showMusicSearch: Bool`, `currentTrackTitle: String?`.
- Karaoke HUD row got: a **prominent `search` button** (borderedProminent style) before the existing `sample` quick-load; a **stop/eject button** (after play/pause) that clears the loaded track via `karaoke.clear()`; a **"now playing" pill** (green/grey liveness dot + track title in a rounded plate) shown after the timecode.
- `.sheet(isPresented: $showMusicSearch)` mounted on the root ZStack — `onSelect` parses the chosen result's LRC into `karaoke.track`, resets `currentTime`, sets `currentTrackTitle`, enables overlay, starts playback, resets the wall-clock tick anchor. `onClose` clears the binding.

**Reason:**
User asked for the next UI slice — specifically "add the UI menu for search and choose the music. have the control panel for the karaoke on the main HUD." Two intents:

1. **Build the search surface as UI now, network later.** Phase 2's biggest unknown is the integration shape, not the network calls themselves. By building the sheet against a mock catalog with the same `(title, artist, duration, lrc)` shape MusicKit/LRCLIB will eventually return, I'm locking the *view layer and the callback contract* (`onSelect: (MusicSearchResult) -> Void`) before any permission flow lands. When stage 2-network is built, it's two replacements — `MockMusicCatalog.search → MusicCatalogSearchRequest.response` and `result.lrc → LRCLibClient.fetch(byMetadata:)` — and the sheet view, the row layout, the pick-to-load flow stay identical.

2. **Make the karaoke row a real control panel on the main HUD.** Previously it was: toggle / sample / play / scrub / time. That's a workbench; it doesn't read as "I'm controlling music playback". Adding `search` (prominent, the primary action), `stop` (eject), and a `now playing` pill turns the same row into something that reads like a media-player strip: source select → transport → scrub → status. The user can still hit `sample` to skip the sheet, but the search button is now the visual focal point.

Specific design notes:
- The `DEMO CATALOG` badge is in **orange**, not the brand colour, because every UI element in this app is white/green/dark — orange immediately reads as "warning/temporary" and won't be mistaken for production styling. Will swap to a green "MUSIC" badge when the real MusicKit path lands.
- The brief 120 ms highlight before dismissing the sheet on selection was tested at 0 ms first and felt rude — the row vanishes before the eye registers the click. 120 ms is the sweet spot; longer (200 ms+) starts feeling laggy.
- Picking always sets `karaokeEnabled = true` and `karaokePlaying = true`. The user clicked a song with explicit intent to play it; making them then click two more toggles to actually see anything would be friction for zero benefit.
- The now-playing pill uses a colour-coded dot (green when `karaokePlaying`, grey when paused) instead of the SF Symbol play/pause icon because the icon is *already on the transport button right next to it*. Two icons would compete; the dot reads as state without redundancy.
- `karaoke.clear()` was already defined on the store but wasn't wired anywhere — the stop button is now the only path that calls it. Nice that it dropped in clean.

**Impact:**
- Build green. Untested on hardware.
- New file is ~290 lines, all pure SwiftUI. No new dependencies.
- The control panel row got wider but still fits on a typical macOS window; the now-playing pill only appears after a track loads so the default-state width didn't change.
- Selecting a track from the sheet immediately starts karaoke + enables the overlay — there's no path through the search UI where the user picks a song and *nothing happens*, which was the failure mode I wanted to avoid.
- Stage 2 network slice now has the cleanest possible swap: `MockMusicCatalog.search(_:)` is the one function to replace.

**Follow-up (if any):**
- Once `MusicCatalogSearchRequest` lands, add a small loading shimmer for the result rows + an error state for offline / no auth.
- Real artwork: `MusicKit.Song.artwork.url(width:height:)` → `AsyncImage` in the same artwork-tile slot.
- Debounce the search query (250 ms) when it hits the real network — irrelevant for mock substring filter.
- After ScreenCaptureKit lands, the sheet could grow a "use system audio" toggle in the footer so the user chooses *what to react to* alongside *what to play*.

---

**Decision / change:**
Started karaoke phase 2 with a non-network feature: a toggle-able overlay (`HeadLyricBlob` in `AppShell/Karaoke.swift`) that pins the current lyric line to a wobbly, audio-reactive **organic blob** anchored beside the person's head, connected to the head joint by a sagging chromatic-split string. Functions as a "thought-bubble / annotation" attached to the subject — moves with the body, doesn't sit in a fixed bar.

Implementation:
- Reads `nose` joint from the latest `VisionFrame` (confidence ≥ 0.3 gate) and runs the same aspect-fill projection as `PoseOverlay` so the blob sticks to the head as the camera frame is letter-/pillar-boxed inside the SwiftUI view.
- Anchor placement: 170 px to the side of the head (sign picked from which screen half the head occupies — keeps the blob on-frame when the subject is at an edge), 180 px above, plus slow `sin`/`cos` float and a `-14·low` upward lift on bass. Clamped to a 80 px screen margin to avoid clipping at the edges.
- **String**: quad-bezier from head to blob anchor with a downward sag of `28 + 26·low + 18·transient` — the rope visibly slumps on the bass and snaps tight on quiet sections. Three stroke passes: red shifted left, blue shifted right (split `1 + 3·high + 5·transient`), crisp white core on top. Anchor dots at both ends to sell "hooked here".
- **Blob shape**: 48-segment closed path around an ellipse, each radius perturbed by a sum of four sines weighted by mid/high bands → organic wobble that breathes with audio. Dark plate fill (`black @ 0.55`) for text legibility, three RGB-offset stroke passes for the chromatic ring, soft inner halo fill (cheap glow without a real Gaussian).
- **Inner lyric**: per-glyph chromatic-split draw (same idea as `KaraokeOverlay.drawCurrentLine` but at 15 pt and without the camera-shake/explosion chaos — this is the pinned annotation, not the focal moment), driven by the *same* `store.lineProgress` highlight wipe so the blob lyric lights up in lock-step with the big bottom-line karaoke. Tiny `▸` caret left of the line so the bubble reads as a tagged annotation rather than free-floating prose.

Wiring in `ContentView`:
- New `@State private var headBlobEnabled` (independent of `karaokeEnabled` — the user can run main karaoke alone, head blob alone, or both).
- Overlay slot in the `ZStack` after `KaraokeOverlay`, fed the same audio params.
- HUD: `head blob` toggle button added next to the existing `karaoke` toggle in `karaokeRow`.

**Reason:**
The original phase-2 plan was MusicKit search + LRCLIB fetch + ScreenCaptureKit system-audio. All three are network/permission plumbing — they change *where the lyric comes from*, not *what the lyric looks like*. The user's instruction was a more interesting phase-2 direction: make the lyric **physically tethered to the body** so it becomes part of the world the subject inhabits, not a caption sitting on top of the frame.

Three reasons this is a better first slice of phase 2 than the network work:

1. **It exercises the same passive store / loose audio coupling the network slice will need.** `HeadLyricBlob` reads `store.currentLineIndex` and `store.lineProgress` — exactly the surface MusicKit playback would feed into. So building the head-blob first proves the contract before the network code lands. When we eventually plug in `ApplicationMusicPlayer.playbackTime`, the head blob just picks up the new times for free.

2. **It earns the "fused into the world" goal more than network plumbing would.** Phase 1 made the lyric chaotic and chromatic; phase 2's job is to make it *spatial*. Tethering to the body is a much stronger spatial cue than the existing bottom-of-frame focal line because the body is the only moving thing in the scene that the audience already tracks. Hooking the lyric to that motion makes it inseparable from the subject.

3. **It's network-free, permission-free, and demo-able right now.** No `NSAppleMusicUsageDescription`, no Screen Recording permission flow, no LRCLIB rate-limit handling. The user can ship the head blob today against the existing sample LRC + mic AudioReactor, and we can do the network plumbing on a separate beat.

Specific tuning notes:
- The string sag uses `audioLow` rather than `audioLevel` because bass is what your ear hears as "weight". A loud snare hit doesn't make a rope feel heavier; a bass drop does. Verified by toggling between the two — `low` reads as the rope reacting to the music's gravity, `level` reads as the rope being shaken arbitrarily.
- Blob `pulse = 1 + 0.05·level + 0.10·transient` — the blob breathes gently with broadband and *jumps* on transients. The asymmetry is deliberate: a steady pulse on level alone reads as a heartbeat (too biological); adding the transient kick makes the blob feel like it's flinching from the beat.
- Side-of-screen picking uses `head.x > size.width * 0.5` rather than the head joint's normalised x because Vision's normalised x is in source-pixel space, not view space — same value would flip incorrectly under letterboxing.
- Used `sub.translateBy` to make the three blob stroke passes instead of rebuilding the 48-segment path three times. Same visual result, ~3× less path work. Could matter if we end up running the head blob next to the chromatic main overlay both at 60 Hz.

**Impact:**
- Build green. Untested on hardware.
- Per-frame cost is bounded: 48-segment path × 3 strokes + 48-segment inner glow + per-character lyric draw × 3 passes (~30 chars typical) → ~90 path ops + ~90 text draws. Same order of magnitude as the main karaoke overlay; both running at once should still hold 60 Hz comfortably.
- New toggle is **independent** of the main karaoke toggle. Both can run together (blob beside the head + chaotic chromatic line at the bottom) which actually looks deliberate — the focal line is the "stage" lyric, the head blob is the "annotated" lyric. Both react in sync via `lineProgress`.
- Stage 2 network slice still pending. Order of attack from here: MusicKit catalog search UI → `ApplicationMusicPlayer` integration to drive `karaoke.currentTime` instead of the wall-clock pump → LRCLIB GET to replace the hardcoded sample → ScreenCaptureKit to replace the mic feed into AudioReactor. Each of those is independent and overlay-free.

**Follow-up (if any):**
- Smooth the head joint with EMA the way `BlobBoxStore` does for body joints — currently the blob can jitter if Vision's nose confidence wobbles. Easy: hold a `@State private var smoothedHead: CGPoint?` in `HeadLyricBlob` updated on `.onReceive(timer)`.
- Per-blob hue tinted by line index, so consecutive lines feel like different "speakers" rather than uniform white. Single line of code; defer until we see how it reads.
- Long lines overflow the blob horizontally — should wrap onto two rows for any line > 28 chars. Defer; sample LRC is short.
- Eventually wire `karaoke.lineProgress` into the Metal particle field so the swarm *responds to lyric phrasing* (not just audio). Cross-module change, separate beat.

---

**Decision / change:**
Same-day follow-up to the karaoke stage 1 entry below. The first version was correct but tame: a single line of text with a sine wobble. User asked for something that feels *fused into the world* — lyrics as environment, not as a caption. Rewrote `KaraokeOverlay` end-to-end (parser + store untouched) into a five-layer audio-reactive composition:

1. **World ghost fragments** — bottom layer. Splits the current lyric into word chunks and scatters 7 huge (40–150 pt) chromatically-split copies across the whole canvas at deterministic-random positions seeded off the current line index, so they hold still per-line and only flicker between lines. Each fragment breathes with the low band (`scale ∝ 1 + 0.30·low`), drifts on a slow sine driven by mid, and gets a mild RGB split scaled by high. Drawn with `BlendMode.plusLighter` so they add into the scene like projected light rather than sitting on top.

2. **Radial bloom** — a wide soft white radial gradient behind the current line, radius `140 + 220·level + 280·low`, so the lyrics appear to *emit* light into the rest of the scene. Crucial for making the body silhouette and the swarm pick up the karaoke energy without me having to wire anything new into the Metal pipeline — the bloom is just additive pixels on top.

3. **Prev / next satellites** — pulled off-axis (prev → upper-left at 18% × screen, next → lower-right at 82% × screen) instead of the old stacked-above-and-below layout. They get their own tiny chromatic split (1–4 px scaled by high), drift slightly with audio, and act as parallax context that the eye can use to anchor "we're between these two phrases" without competing with the focal line.

4. **Transient slice tear** — when `audioTransient > 0.12`, a thin bright horizontal band is painted across the current-line region at a noise-displaced y, thickness `1 + 4·transient`, blended additively. Reads as a VHS tracking tear / digital scan glitch. Decays naturally because `transient` is an EMA peak in the reactor.

5. **Current line** — the centrepiece. Per-character draw, three colour passes for chromatic aberration:
   - **Lit chars** get bright R/G/B triplet (red `(1.0, 0.18, 0.30)`, green `(0.45, 1.0, 0.60)`, blue `(0.25, 0.55, 1.0)`) offset by `splitX = 2 + 14·level + 28·transient` pixels horizontally and `splitX·0.35` vertically. Recombines to near-white in the centre with coloured fringes at the edges — actual RGB-split chromatic aberration, not a fake "shadow text".
   - **Unlit chars** get dim white triplets so the karaoke wipe reads as *saturation lighting up*, not just a brightness change. Much more cinematic than the original on/off grey→white wipe.
   - Per-glyph chaos: pseudoNoise-seeded micro-rotation (±0.04 rad baseline, ±0.22 rad on full transient), transient-driven outward explosion (`18·transient·noise(idx)` horizontal jolt, `10·transient·noise(idx+17)` vertical), the existing two-harmonic waveform y-offset retained but with amplitudes bumped (`liveAmp = 2 + 18·level + 12·high`).
   - Font size also breathes with level (`36 + 8·level`).
   - Thin animated underline at `centerY + 0.65·fontSize`, alpha `0.25 + 0.55·level + 0.40·transient` — gives the eye a horizon line to anchor the chaos to.

6. **Global camera shake** — wraps the whole canvas with a translated context. Magnitude tracked by a state-resident envelope `shake = max(shake·0.90, audioTransient)` so peaks snap and decays are smooth (~250 ms half-life at 60 Hz). Without this the chaos was busy but felt papercut-flat; with it the whole frame *moves* on a beat.

New audio param `audioTransient` (and `audioLow`) plumbed through `ContentView` from the existing reactor's `AudioFrame.transient` / `.low` — no AudioReactor changes needed.

**Reason:**
User's brief: *"feel fused into the world itself — not just text on top"*. The original overlay was technically audio-reactive but the audio only modulated a sine amplitude — the eye reads that as "vibrating text", not as "the world is responding". Three things make the new version sell:

1. **Multiple z-layers with different reactions.** Background ghosts react slowly (bass-breathing). Foreground line reacts fast (transient kicks, RGB split). Mid-layer satellites parallax. Once different elements at different depths respond to different *bands* of the audio, the brain stops parsing them as "text and decoration" and starts parsing them as "an environment".

2. **Chromatic aberration is the visual signature.** It's the single most readable cue for "this is not flat — this is being recorded / transmitted through a lens". Doing it as three real coloured glyphs additively blended (rather than a CIFilter post-process) means the split scales naturally with whatever chaos is also happening to the per-glyph position, so on transients the channels don't just shift further apart — they shift further apart *while* the glyphs are also jolting and rotating. The compound effect is much harder to fake.

3. **Additive blending throughout.** Every sub-context here is `.plusLighter`. The reason matters: against the existing dark background + Metal particle swarm + camera silhouette, additive blending means the lyric layers *brighten what's behind them* rather than masking it. That's the literal definition of "fused into the world". Subtract or normal-blend the same layers and they'd cut holes in the swarm.

Specific tuning notes:

- The world fragments are seeded per `lineIndex`, not per frame. If I used a fresh seed each frame the ghosts would jitter and look like noise. As-is, each line has a stable spatial composition that breathes in place — it reads as "the world has rearranged itself around this line".
- The chromatic R/G/B colours are picked off the additive primary triangle but pushed slightly off pure 1,0,0 / 0,1,0 / 0,0,1 — pure primaries reading on white background look harsh. The off-axis tints (e.g. green = `(0.45, 1.0, 0.60)`) blend to a slightly cooler white but the edges still read as pure colour-split.
- `shake` is held in `@State` (not recomputed from `audioTransient` per frame) specifically so it can have an attack-fast / release-slow envelope. Otherwise shake is just `audioTransient` and the camera snaps back between hits.
- Slice-tear y-offset uses `pseudoNoise(Int(nowT * 13))` so the slice position changes at ~13 Hz, independent of the transient rate. Otherwise the slice would always appear at the same y on every beat and read as a static UI element.

**Impact:**
- Build green. Untested on hardware, but per-frame work is bounded: 7 ghost fragments × 3 passes + 1 prev + 1 next (×3 passes) + N glyphs × 3 passes ≈ 21 + 6 + 90 = ~120 `Text` draws per Canvas pass at 60 Hz on a typical 30-character line. Same order of magnitude as the original. The new `resolve` cost is unchanged (still one per character per frame for measurement).
- Visually destructive change: this **replaces** the old quiet karaoke overlay. There's no "tame mode" toggle. If we decide the chaos is too much, the gate is to scale every audio amplitude by a single HUD `karaoke intensity` slider — easy follow-up, not needed for the demo.
- No new dependencies. Pure SwiftUI Canvas + the existing AudioReactor fields. Stage 2 (MusicKit + LRCLIB + ScreenCaptureKit) still slots in without touching the overlay.

**Follow-up (if any):**
- HUD `karaoke intensity` slider to scale the master audio multipliers (would gate ghost count, split magnitude, shake magnitude with one number).
- The body silhouette doesn't currently react to karaoke transients — those still only come from the Metal reactor. If we want the lyrics to *literally* push the swarm, route `karaoke.lineProgress` into a new field-uniform that biases the curl-noise centre toward `centerY`. Defer; would require ParticleField API change.
- Optional grain / scanlines as a global post — would deepen the cinematic read. Currently kept off to preserve readability.

---

**Decision / change:**
First slice of the karaoke feature. Three deliberate omissions: no MusicKit search/playback, no LRCLIB network fetch, no ScreenCaptureKit system-audio tap. The point of stage 1 is to lock the *visual contract* — lyric model, parsing, line-progression logic, character-level highlight wipe, and audio-reactive waveform distortion — so stage 2 can be a pure plumbing job.

New artefacts (`AppShell/Karaoke.swift`):
- `LyricsLine { time, text }` + `LyricsTrack { title?, artist?, lines, duration }`. Duration is estimated as `last.time + 4 s` until stage 2 swaps in the real player track length.
- `LRCParser.parse(_:)` — handles `[mm:ss]`, `[mm:ss.xx]`, and multi-stamp lines (`[00:14.10][01:42.00]...` used for choruses by both Musixmatch and LRCLIB). Two regexes: one for `(ti|ar|al)` metadata, one for timestamps. Fractional digits are 1–3 to accept both `.xx` and `.xxx`. Empty lines and unknown tags are silently dropped. Output sorted ascending.
- `KaraokeStore` (@Observable, **passive**): holds `track` + `currentTime`. `currentLineIndex` is computed (linear scan — fine at lyric scale; binary search is just an off-by-one trap). `lineProgress` is 0..1 between the current line's `time` and the next line's `time` (or +4 s for the final line) — this drives the per-character highlight.
- `KaraokeOverlay` — SwiftUI `Canvas` with its own 60 Hz `Timer.publish` repaint so the sine ripple animates between Vision frames. Three rows positioned at `centerY = size.height * 0.78` with 38 px gap: previous (faint 18 pt medium), current (34 pt heavy, white, highlight wipe + waveform), next (faint 18 pt medium). The current line is drawn **character-by-character** so each glyph can have:
  - its own colour (lit/dim based on whether its centre x is past `progress × totalWidth`),
  - its own y-offset = `sin(idx * 0.55 + nowT * 7) * (2 + 16·level + 10·high) + sin(idx * 0.21 + nowT * 11) * (3 + 8·mid)` — two harmonics summed, fast micro-ripple + slower wave, weighted by mid-band so the texture isn't a single uniform wobble.

Wiring in `ContentView`:
- New state: `karaoke` (store), `karaokeEnabled`, `karaokePlaying`, `karaokeLastTick`, dedicated `karaokeTimer` at 60 Hz.
- Overlay slot in the ZStack between the blob-box overlay and the Vision skeleton overlay.
- `.onReceive(karaokeTimer)` integrates wall-clock deltas into `karaoke.currentTime` when playing — using `dt` not a fixed step so a runtime hiccup doesn't desync; clamped to `track.duration` so the scrub doesn't run off the end.
- HUD row (between blobs and audio rows): `karaoke` toggle, `sample` button (loads `LRCParser.sample`, enables overlay, starts playing), play/pause toggle, scrub slider 0..duration (always present so the row doesn't reflow when a track loads — disabled when track is nil), live `m:ss / m:ss` timecode.
- The overlay reads `audio.latest.level/mid/high` straight off the existing mic `AudioReactor`. So even on stage 1 you get genuine room-audio reactivity if you turn on the audio reactor and play music near the mic. When stage 2 swaps in ScreenCaptureKit, the overlay needs zero changes.

Sample LRC ships in `LRCParser.sample` — 11 lines thematic to Artlify ("stand still before the lens" / "every motion leaves a trail" etc.) so the demo reads as intentional rather than lorem.

**Reason:**
Three reasons for staging.

1. **The visual is the only risky part.** MusicKit search and LRCLIB GETs are routine plumbing — they'll either work or fail with obvious HTTP errors. Per-character drawing inside `Canvas` with measured glyph widths and per-glyph y-offsets is where the experience either lands or doesn't, and I'd rather iterate on that against a deterministic time slider than against a network-fetched lyric of unknown formatting quirks.

2. **The audio source decision deserves real testing.** ScreenCaptureKit's audio capture has macOS-13+ permission flow, sample-rate quirks (it delivers 48 kHz floats; the current AudioReactor assumes input-tap format), and isn't trivial to abstract over. Building stage 1 against the existing mic reactor lets us validate that the FFT bands `level/mid/high` actually drive a *good-looking* waveform before committing to swap the source. If the audio→ripple coupling needs retuning (different amplitude curves, different band weighting), better to discover that now.

3. **Passive store + external time pump is the right shape regardless of source.** Whether `currentTime` comes from a slider, `ApplicationMusicPlayer.playbackTime`, or an `AVAudioPlayerNode` we drive ourselves, the overlay doesn't need to know — it just renders whatever `currentTime` says. That separation is enforced by `KaraokeStore` not owning a playback engine.

A specific design choice worth documenting: the highlight wipe is computed at the **pixel** level (cx ≤ progress × totalWidth), not by snapping to character boundaries. That gives a sub-character interpolation feel — when progress is at 0.55 on a 10-character line, characters 0–4 are lit and character 5 is lit if its centre happens to be in the first half of its cell. Cleaner-looking than the alternative of integer index snapping, especially on short lines.

**Impact:**
- Build green. Untested on hardware.
- Per-frame cost is bounded: at most 3 lines × ~40 chars = 120 `Text` resolves + measurements + draws per Canvas pass at 60 Hz. The resolves are the only non-trivial cost; if it shows up in profiling, we can cache `widths` keyed by `(line, font)` — but ~7 200 resolves/sec is nothing on this hardware.
- The scrub slider doubles as a debugging tool: dragging through the song shows every line transition and the per-character wipe in slow motion. Will keep this slider in stage 2 too as a "seek bar" for development; can hide behind the HUD toggle for the demo.
- No new dependencies, no entitlements, no Info.plist keys yet. Stage 2 will add `NSAppleMusicUsageDescription` (MusicKit) and Screen Recording permission (ScreenCaptureKit) — both deferred.

**Follow-up (stage 2 outline):**
- `MusicKitSearch` — wraps `MusicCatalogSearchRequest(term:types:[Song.self])`, returns artwork URL + title + artist + duration + ISRC for the top 8 hits. Search sheet UI as a SwiftUI `.sheet`.
- `MusicKitPlayer` — `ApplicationMusicPlayer.shared`, queue with selected song, expose `playbackTime` to drive `karaoke.currentTime` (replaces the wall-clock integration).
- `LRCLibClient` — single `URLSession` GET to `https://lrclib.net/api/get?track_name=...&artist_name=...&duration=...`, JSON-decode `syncedLyrics` (LRC format string), feed straight into the existing `LRCParser`. Fallback to `plainLyrics` (un-synced) → render single static block when no synced version exists.
- `SystemAudioReactor` — `SCStream` with `SCStreamConfiguration.capturesAudio = true`, audio-only filter; convert delivered `CMSampleBuffer`s to the same `Float` interleaved format the existing mic reactor consumes, then literally call the existing FFT path. HUD toggle "mic / system" to switch reactors live.
- Optional: per-line "active colour" pulled from the audio reactor's high-band hue rather than always white.
- Optional: word-level karaoke (some LRCLIB tracks ship `[mm:ss.xx]` *per word*, not per line) — already supported by the parser shape, just needs a second pass to group same-text words back into lines.

---

## 2026-05-13 — `particles` branch: blob-tracking bounding-box overlay (replaces rejected tracery)

**Decision / change:**
The previous tracery interpretation was wrong too. User clarified: "blob tracking" here means detect the blobs (moving body regions) and draw **flashing bounding boxes** around them — same flicker idiom as the negative-camera boxes — with **strings connecting** the boxes. Deleted `AppShell/BlobTracery.swift`.

**Telemetry labels (follow-up in same day):** each lit box now also draws a short white monospaced label on a faint dark plate just under the bracket. Label is re-rolled at the start of each flash (so they churn like a debugger spew, not static name tags). 60 % chance of a zero-padded 6-digit numeric id (`042817`, `999003`, …), 40 % chance of a short C-language token from a curated 38-entry pool (`void*`, `0xDEADBEEF`, `for(;;)`, `malloc(8)`, `&ptr`, `x|=1<<3`, `printf("%d")`, `SEG_FAULT`, …). Pool entries are kept ≤ 14 chars so they fit under the smallest boxes; mix of pointer / hex / loop / call / type shapes for visual variety. Label alpha is tied to the box's triangular envelope so it strobes in sync with the bracket. Plate sits over arbitrary camera content so the text stays legible.

New artefacts:
- `AppShell/BlobBoxes.swift`:
  - `BlobBox`: id (joint id), smoothed `center` uv, `halfSize` uv, stable hashed `hue`, `flashUntil` wall-clock gate, `lastSeen`.
  - `BlobBoxStore` (`@Observable`):
    - `updatePositions(joints:now:)` — EMA-smooths each blob's centre toward the latest joint position (`smoothing = 0.55`), creates new blobs with randomised box sizes (0.045–0.085 uv per axis so trackers feel varied not gridlike), prunes anything not seen in 0.6 s.
    - `tickFlash(now:)` — for each blob whose flash has expired, roll `flashProbability` (default 0.30) and on success light it for `flashDuration` 0.16 s. Boxes are *only drawn* while their flash is live, so the overlay is a sparse strobe of ~30 % of trackers at any moment rather than a constant grid.
  - `BlobBoxesOverlay` — SwiftUI `Canvas`, 60 Hz `Timer.publish` repaint clock so the on/off transitions are crisp. Per lit box: triangular alpha envelope inside the flash window, glow underlay (4 px, 25 % α) + crisp 1 px outline (95 % α), corner-tick brackets at all four corners (length = 36 % of the shorter half-side), centre dot. Connective web: drawn first (so box outlines sit on top of their endpoints), every-pair white line with a soft glow under and a thin bright top stroke.
- `ContentView` driver: `updateBlobs()` runs from the existing `.onChange(of: vision.passCount)` block (positions). `blobs.tickFlash(now:)` added to the existing 9 Hz `boxTimer` callback so the blob flicker and the negative-camera flicker share one rhythm. HUD row: `blobs` toggle, `strings` toggle, `flash` probability slider (0.05–0.8), `intensity` slider (0.2–1.5).

**Reason:**
Reading the brief literally this time: "when you detected the blob i want you to just put the bounding boxes on the blob. the way like you created the negative camera effect. it will flash like that. and it will be random. each blob or bounding boxes will have connected string."

Three concrete decisions follow:
1. **Blob = pose joint** still — Vision already gives stable, ID-tagged points cheaper than mask connected components, and per the brief we just need a tracker to anchor a box on. The boxes don't need to match the actual silhouette geometry; they're trackers, not segmentations.
2. **Flash gate, not always-on draw.** This is what makes it match the negative-camera box behaviour — boxes pop on, flash, vanish, another subset comes on. A constantly-drawn box per joint would read as 19 static rectangles, which is ugly and not what was asked for. Implementation is a `flashUntil` per box checked at draw time; the box is invisible outside its window. Triangular envelope inside the window so it brightens then fades rather than hard-clipping.
3. **All-pairs string web** between currently-lit boxes only. With probability 0.30 and ~10 trackers visible, ~3 boxes are lit at once → 3 connecting segments typical. Wires the diagram together without becoming a dense mesh. Strings are white (with a soft glow under-stroke), not coloured, so they don't fight the per-blob hues on the box outlines.

The corner tick brackets matter: a plain rectangle outline reads as "geometry"; brackets at the corners read as "tracker reticle". Tiny visual move, big difference in the diagrammatic feel.

**Impact:**
- Build green. Untested on hardware.
- Per-frame cost is bounded: ≤19 boxes, only ~30 % drawn at once, ≤(6 choose 2) = 15 string segments. Trivial for `Canvas`.
- Same `boxTimer` already drives `tickNegativeBoxes` and `tickAsciiShockwave`; adding `blobs.tickFlash` means all three flicker layers share a single 9 Hz pulse, which is going to read as more cohesive than three separate clocks.
- Position smoothing (EMA 0.55) is necessary — at Vision's 15 Hz with raw assignment the boxes were jumping a few pixels every frame; smoothed they breathe.
- Two non-issues from the previous iteration carried over correctly: explicit `import Combine` for `Timer.publish`, hash-based per-id stable hue.

**Follow-up:**
- Audio reactivity: bump `flashProbability` momentarily on `audio.latest.transient` so loud sounds light up the whole web at once. Right now the overlay is mute.
- Maybe a "burst" button that lights every box for one flash duration so users can see the full diagram on demand.
- If multi-person is added later, key boxes by `(personIndex, jointId)` so two people don't get their boxes coloured identically.
- The all-pairs web is fine at small N; if we ever drive it with mask CCs (10+ blobs typical) we should switch to nearest-neighbour or MST so the web doesn't become a dense mesh.

---

## 2026-05-13 — `particles` branch: blob-tracking tracery overlay (REJECTED, removed)

> Superseded by the blob-box entry above. User wanted bounding boxes + connecting strings (like the negative-camera flash idiom), not flowing splines through joint history. Code deleted, journal entry kept as a record of the wrong path and for the Catmull-Rom math notes that may be useful elsewhere.

**Decision / change:**
The previous head-tethered "thought flashes" were rejected by the user — wrong mental model entirely. The correct technique is **blob tracking + tracery**: follow each moving body region over time and render that trajectory as ornamental, interlaced line art. Deleted `AppShell/ThoughtFlash.swift` outright.

New artefacts:
- `AppShell/BlobTracery.swift`: three types.
  - `BlobTrack`: per-joint rolling history `[(uv, t)]` plus a stable per-id `hue` and `lastSeen`.
  - `BlobTraceryStore` (`@Observable`): `tracks: [String: BlobTrack]`, `historyLength` (default 28), `pruneAfter` (default 0.6 s). `update(joints:now:)` appends new samples (skipping micro-displacements <0.4 % uv to avoid spline degeneracy when the subject is still), trims history, prunes stale tracks.
  - `BlobTraceryOverlay`: SwiftUI `Canvas`, 30 Hz internal `Timer.publish` repaint. For each track:
    - smooth Catmull–Rom spline through the history, expressed as cubic Beziers via the standard `c1 = P1 + (P2 − P0)/6, c2 = P2 − (P3 − P1)/6`, with reflected endpoints so it actually passes through P[0] and P[last];
    - drawn twice — a wider faint glow underlay (4.5 px, 22 % α) plus a crisp 1.1-px head line (85 % α) — the two-stroke layering is what reads as "tracery" rather than a single plotted curve;
    - small fade-in dots at every sample to give the spline an obvious tail→head direction;
    - at the head, three rotated, interlaced ellipses oriented along the local velocity tangent; ellipse radius scales mildly with speed so fast-moving joints get bigger flourishes.
  - Per-track hue is an FNV-1a hash of the joint id mod 360 → each tracked joint has its own consistent colour thread, which is what makes overlapping multi-joint tracery actually read as separate woven threads.
- `ContentView` driver: `updateTracery()` is called from the existing `.onChange(of: vision.passCount)` block. Pulls confident joints (≥0.4), flips Vision's bottom-left y to top-left uv, hands them to the store. HUD row swapped to `tracery` toggle + `length` slider (history depth 6–60) + `intensity` slider (0.2–1.5 master α/brightness). All thought-related state and the separate `thoughtTimer` are gone.

**Reason:**
"Tracery" is a specific architectural ornament idiom — interlaced, often double-line stonework you see in Gothic windows. Combined with "blob tracking" the brief is unambiguous: take the moving body parts as the blobs, render their motion as ornamental flowing curves. Two implementation choices follow directly:

1. **Blob = pose joint, not mask connected component.** Vision already gives us 19 joints at 15 Hz with confidence scores, which is enough discrete trackers for the visual to feel rich. A real per-pixel blob extraction off the segmentation mask would add CPU cost (connected components, centroid tracking, ID matching across frames) for almost no visual gain — joints already cluster around the same body regions a CC pass would find, and they come pre-identified so we don't need a Hungarian-matcher to keep blob colours stable.
2. **Tracery look comes from layering, not from one fancy stroke.** A single thin line through the history reads as a plot. Glow underlay + crisp top line + per-vertex dots + head-end ornament reads as ornamental art. That four-element recipe is what separates "trail" from "tracery" visually.

The Catmull-Rom path matters: linear segments between Vision samples (~15 Hz) would jitter visibly at 30 Hz repaint. Catmull-Rom interpolates smoothly through every sample with C¹ continuity, no curve-fitting, no smoothing latency.

**Impact:**
- Build green. Untested on hardware.
- Per-frame work is bounded: ≤19 tracks × ≤28 samples = ≤532 path segments + 19 head ornaments. Trivial for `Canvas`.
- The "skip micro-moves" guard (4 px-equivalent) is doing real work — without it, a stationary subject would pile up identical samples and the spline would degenerate into NaN-prone zero-length segments.
- The Catmull-Rom math went through one rewrite. First pass tried centripetal (α=0.5) with a giant ad-hoc tangent formula that I'm not sure was even correct. Replaced with the textbook uniform-CR → cubic Bezier conversion (`c = P + (next − prev)/6`). It's three lines, demonstrably right, and visually identical for the smooth motions a body produces. Lesson: don't reach for centripetal until uniform actually misbehaves on real input.
- Hit the `simd` import gotcha: `simd_distance` lives in the `simd` module, not `Foundation`/`SwiftUI`. Easy fix, but worth noting alongside the recurring `import Combine` Swift-6 trap.
- Layering: tracery draws above all Metal layers and below the HUD, same plane the rejected thought-flash overlay used. That's intentional — the tracery is a separate diegetic plane (lines drawn "in the air"), not a body surface treatment.

**Follow-up:**
- Audio reactivity: feed `audio.latest.level` into `intensity` and `audio.latest.transient` into a momentary head-flourish radius bump; right now the overlay is mute.
- Per-track lifetime decay on the spline α (older segments more transparent than newer) — currently the dots fade, the spline doesn't.
- Maybe a "ghost" copy of the spline offset by ±2 px perpendicular for a true interlaced double-stroke, which is the most literal Gothic-tracery move. The ellipses already imply this but a perpendicular-offset spline would seal the look.
- If multi-person becomes interesting, key tracks by `(personIndex, jointId)` so two people's threads don't collapse into the same hue.

---

## 2026-05-13 — `particles` branch: ASCII colour + chaotic head-tethered thought flashes (REJECTED, removed)

> Superseded by the blob-tracery entry above. The thought-flash geometry overlay was a misread of the brief — user wanted ornamental tracery following blobs, not labelled containers tied to the head. Code deleted, journal entry kept for the ASCII colour decision and as a record of the wrong path.

**Decision / change:**

**1. Customisable ASCII colour.** Two new uniforms on `AsciiUniforms` (`colorLow`, `colorHigh`, `float3`s, padded to `SIMD4<Float>` Swift-side because Metal's float3 is 16-byte aligned and a naked `SIMD3<Float>` from Swift won't match the layout). The shader's tint mix `mix(colorLow, colorHigh, lum) * g` replaces the previous hard-coded phosphor green. HUD got a single `hue` slider (0..1) which feeds `applyAsciiHue(_)`: builds two NSColors at `(hue, 0.85, 0.95)` and `(hue, 0.35, 1.00)`, converts each to deviceRGB, packs into `asciiColorLow/High`. So one knob shifts the whole palette — amber, cyan, magenta, blood-red, etc. — while keeping the dark/bright contrast that makes the glyphs legible.

**2. Thought-flash overlay** (`AppShell/ThoughtFlash.swift` — DELETED). New SwiftUI `Canvas` overlay sitting between the MTKView and the HUD. Renders an in-memory pool of `ThoughtFlash` records: each is a random shape (rect / circle / triangle / hexagon), at a random position in a [0.18, 0.45] uv-radius ring around the head, rotated -18..+18°, with 1–3 lines of pseudo-mathematical text inside (`42 + 17 = ?`, `x² + 5x + 9 = 0`, `∫ e^(-x²) dx ≈ 0.886`, `sin(127°) = 0.799`, `E ≈ 412.05`, plus weird single words like `why`, `later`, `?`). Each flash has a triangular alpha envelope over a random `0.55..1.6` s lifetime, its own random hue, and is connected by a thin stroked line back to the detected head joint with a tiny dot at the head end so the anchor is unambiguous.

Why SwiftUI Canvas instead of another Metal pass: text rendering and arbitrary stroked geometry are trivial in Canvas and ugly in Metal. We're at most 12–30 shapes simultaneously, each a stroked path + a few `Text` runs — cost is negligible and `.drawingGroup()` ensures the overlay composites through Metal anyway.

Driver in `ContentView`:
- `headUV(from:)` extracts the head joint, preferring `nose` → `head` → `ear` substring matches (Vision's joint names vary across OS), falls back to whole-body centroid, then nil (overlay scatters across full frame).
- `Timer.publish(every: 0.35)` (~3 Hz baseline) drives `tickThoughts()` — culls expired, then 65% chance to spawn 1 flash. Staggering keeps the rhythm chaotic-feeling rather than metronomic.
- On every detected audio transient (`audio.latest.transient > 0.18`), spawn an additional 2-shape burst. So loud sounds visually overload the "head" with thoughts — perfect for the "this person has too much to think about" intent.
- HUD: `thoughts` toggle (clears the pool when disabled), `capacity` slider (4–30, oldest evicted), manual `burst` button.

**Reason:**
(1) The fixed phosphor-green ASCII looked great but made the layer feel locked to a single emotional register. With a hue knob, ASCII can be the gentle background green for ambient mode, then crank to angry red when the room gets loud, etc. One slider, one line of NSColor math — cheapest possible knob for the largest visual range.

(2) The user's brief: random geometry on the dark background, with calculation-like numbers, tethered by string to the head, chaotic-but-artistic, portraying "a person has a lot to think about." The visual idiom this lands on is technical-diagram chaos — like an illustrated brain anatomy drawing, but the labels are math equations and the labels live just briefly before being replaced. SwiftUI Canvas was the right primitive because every shape needs text inside AND a connecting line, and SwiftUI's text rendering is excellent.

Kept the formula generators deliberately mixed (clean arithmetic + algebra + integrals + physics + plain words like "why" / "later" / `13:47`) so the overlay reads as a real wandering mind rather than a calculator demo. The single-word `?` and `todo` slots are doing a surprising amount of emotional work — they break up the math density and feel intimately human.

**Impact:**
- Canvas overlay paints at 30 Hz (its own internal Timer publisher) so envelopes animate smoothly. Anchored to head position which only updates at Vision rate (~15 Hz); some perceptible step but the lines feel more deliberate than smooth-following would.
- `ThoughtFlashStore` is `@Observable`; the SwiftUI re-render path is the standard one (mutation → view diff). Capacity-evict policy keeps the pool bounded so even a sustained transient burst can't allocate unbounded shapes.
- `Combine` had to be imported in `ThoughtFlash.swift` (same Swift 6 strictness gotcha as ContentView).
- Hue knob is decoupled from audio for now — if we wanted, audio-high band could push it cyan and audio-low push amber per frame. Left as a follow-up because manual control is more useful for setup-tuning.
- The thought-flashes draw underneath the HUD but on TOP of all Metal layers (swarm, trails, neg boxes, ASCII). That layering decision was deliberate: thoughts are a separate diegetic plane (literally "in the air around the person"), not part of the body's visual treatment.

**Follow-up:**
- Detect `right_wrist`/`left_wrist` joints and let some flashes anchor to wrists too (not just head) for variety — the visual would read as "thoughts spilling out of the hands".
- Make spawn rate scale with audio level so silent rooms have a few sparse thoughts and busy rooms get a dense cloud.
- Optional curve / bezier on the connecting line (slight droop) so it feels like a string under gravity rather than a straight ruler line.
- A small per-flash "glitch" pass: occasionally render the text scrambled then resolve to its real value mid-life.

---

## 2026-05-13 — `particles` branch: ASCII-dither overlay with audio-driven shockwave ring

**Decision / change:**
New toggleable visual layer: the camera image inside the person silhouette is re-rendered as a grid of ASCII glyphs (" .:-=+*#%@"), sparsest → densest by luminance. When the audio reactor detects a transient, a single ring expands outward from the body anchor, briefly densifying glyphs as it crosses them. Visually it reads like a dot-matrix display of the person, with a sonar-style pulse on every loud sound.

New artefacts:
- `RenderKit/Ascii.metal` — single fragment, three texture inputs (camera / mask / glyph atlas) + `AsciiUniforms`. Per-pixel: quantise to a grid cell of `cellSize` px; sample camera + mask at the cell center; gate by mask (smoothstep 0.05–0.30); convert luminance to glyph index `[0..N-1]`; sample the atlas at `((idx + localX) / N, localY)`; tint with a phosphor-green ramp interpolated by luminance. Premultiplied alpha out, drawn over with standard alpha blend.
- `RenderKit/AsciiAtlas.swift` — builds a 160×16 R8 texture once at renderer init from `NSFont.monospacedSystemFont(ofSize: 13.6, weight: .bold)`, drawing each glyph centered into a 16-px cell on a black ground via CGContext + NSGraphicsContext. The shader's `glyphCount` uniform stays in sync with `AsciiAtlas.glyphs.count`.
- `CameraMetalRenderer` gained: `asciiPipeline` (alpha-blended), `asciiAtlasTexture`, public knobs `asciiEnabled`, `asciiCellSize` (4–28 px), `asciiOrigin`, plus `triggerAsciiShockwave(origin:)` which just stamps `asciiShockBirth = now`. The encode helper packs uniforms with `shockAge = (now - birth) if 0≤2.5 else -1`, ring speed `0.55 uv/s`, gaussian width `0.045 uv`, peak boost `0.85`. Drawn as the last pass on both code paths (after trails-present and after the no-trails camera/particles overlay), so glyphs sit cleanly on top.
- `ContentView`: HUD row gained `ascii` toggle + `cell` slider (4–28 px) + `pulse` button to fire a ring manually. The existing 9-Hz `boxTimer` also calls `tickAsciiShockwave()`, which checks `audio.latest.transient > 0.18` with a 0.18-s rate limit so a single loud event doesn't pile up overlapping rings. Body anchor (avg of hip joints) feeds both `field.bodyCenter` and `renderer.asciiOrigin` on every Vision pass.

**Reason:**
The user asked: instead of audio modulating particle motion, what if it modulates an ASCII-dithering pass on the silhouette, with shockwaves on transients? It's a cool aesthetic axis we hadn't tried — dot-matrix / terminal art is a different visual register from glowing particles, much more graphic and legible at a distance, and pairs naturally with sound because each glyph is a discrete quantum that can flip with the music. Body-anchored ring on a transient is exactly the visual idiom of a sonar ping or a spectrum-analyser sweep, which carries the audio's punctuation in a way the smooth particle field doesn't.

Made it a separate toggle (not a replacement for the swarm) because:
- Both can be on at once and they layer well — swarm cloud + ASCII silhouette + flash boxes is a maximalist arrangement; ASCII alone is the clean minimalist version.
- Easier to A/B for the user.
- Costs nothing when off (early return in encodeAscii).

**Impact:**
- One extra full-screen triangle pass when enabled. Per-pixel: a few texture samples + a couple `exp` calls for the ring. Trivial on M5.
- The atlas is generated once at renderer init using AppKit (`NSGraphicsContext`), so this adds a hard AppKit dependency to RenderKit. For a macOS-only app that's fine; if iOS support matters later we'd swap in CoreText directly.
- Glyph cell size of 12 px works well at typical drawable sizes. Smaller cells → looks more like a video; larger → more like vintage terminal. Slider exposed.
- The shockwave ring uses ONE shared origin per renderer; multiple rapid transients overwrite each other rather than stacking. That's intentional — a stack would visually devolve into a smear of overlapping rings, while a single "latest" ring reads as a clean pulse.
- Atlas quality limit: monospaced bold at 85% cell height is legible but the densest glyphs (`%@`) saturate similarly. We could grade better with a richer ramp (e.g. Bukhanov's 70-char gradient), but the 10-glyph ramp keeps the discrete quantisation visible — which is the point.
- ASCII pass requires both camera + mask textures present; it silently no-ops while Vision is warming up.

**Follow-up:**
- Try multi-ring stack (3–4 most recent transients) for busy music — see whether legibility holds.
- Make ring colour shift with audio band (low → amber, mid → green, high → cyan) instead of fixed phosphor green.
- Quantise glyph SELECTION on a slow tick (e.g. 12 Hz) instead of every frame so cells don't twinkle from camera noise; would feel more deliberately drawn.
- Optional: ASCII-only mode that hides the swarm entirely for a pure terminal-art look.

---

## 2026-05-13 — `particles` branch: shockwave breaks the silhouette + negative-camera flash boxes

**Decision / change:**
Two more installation-aesthetic moves on top of the trails + audio reactivity from earlier today.

**1. Shockwaves now break OUT of the body.** Previously the audio-transient kick was applied as a force inside the shader, but the mask-gate in the fragment shader killed alpha the moment a particle crossed the silhouette boundary — so visually the burst stayed contained inside the body shape. Three coordinated changes fix that:
  - New `bodyCenter: float2` uniform on `ParticleUniforms` (Metal + Swift). The shockwave origin is now `bodyCenter + (0.12*pan, 0)` instead of a hard-coded `(0.5+0.4*pan, 0.5)`, so the wave radiates from inside the actual person, not screen middle.
  - Kick magnitude bumped 6.0 → 9.0, falloff softened (`1/(1+5d²)` was `1/(1+12d²)`) so the impulse still has real force at the silhouette edge.
  - In `particle_fragment`, an `escapeBoost = saturate(strength * (0.6*transient + 0.25*level) * 2.0)` lerps `gate` toward 1.0 during transients. So the moment a clap or beat fires, the gate opens, the kick has already shoved particles outward, and they remain visible streaming past the body boundary. Combined with the trail accumulator, this leaves a luminous wake of particles bursting outward through the silhouette.
  - `bodyCenter` is computed in `ContentView.bodyCenter(from:joints:)`: average of any `id` containing "hip", fallback to all confident joints, fallback to `(0.5, 0.5)`. Fed into `field.bodyCenter` on every Vision pass.

**2. Negative-camera flash boxes.** New render layer: random rectangles flash on around body joints, and inside each rectangle the live camera feed is shown with its colour negated (RGB inverted), then alpha-blended over the dark canvas. The dark gallery is intermittently "punctured" by stuttering X-ray-like cutouts wherever the body parts briefly are. New artefacts:
  - `RenderKit/NegativeBoxes.metal` — `negative_boxes_fragment` reads the latest camera texture and a `constant NegBox*` array (cx, cy, hw, hh + alpha), discards outside all boxes, samples camera and inverts inside, with a 15%-of-half-extent smoothstep edge so cutouts don't have a hard rectangular line.
  - `CameraMetalRenderer`: new `negativeBoxesPipeline` (standard alpha blend), persistent `negativeBoxesBuffer` sized for `MAX_NEG_BOXES = 16`, `[NegativeBoxState]` CPU list with birth/duration/peak. `flashNegativeBox(center:halfSize:duration:peak:)` is the public API. Each draw, `packNegativeBoxes(now:)` culls expired entries and converts live ones into `GPUNegBox` packed records with a triangular envelope (`alpha = peak * (1 - |2t-1|)`). The box pass is encoded after the trail-present pass (so flashes overlay everything cleanly and aren't subject to trail decay) and also after the no-trails camera/particles path.
  - `ContentView`: a `Timer.publish(every: 0.11, on: .main, in: .common).autoconnect()` (~9 Hz, intentionally slow so flashes feel stuttery and intentional rather than continuous noise) drives `tickNegativeBoxes()`, which picks 1–3 random joints with confidence ≥ 0.4, generates random box sizes in [0.025, 0.07] uv half-extent each axis (decoupled, so boxes vary square-to-strip), random duration 0.18–0.55 s.
  - HUD gained a row: "neg boxes" toggle + intensity slider 0.10–1.00 (peak alpha).

**Reason:**
For (1): the user explicitly asked the shockwave to "break the segmentation outward" because the body-confined version felt too tame — the audio kicked the particles but the silhouette still owned the shape, so the visual didn't carry the audio's energy out into the room. With the shockwave breaking out, a clap reads as the body literally exploding into stardust for a beat, then re-coalescing as the trail fades. That's the gallery-scale moment the previous iteration was missing.

For (2): the dark-background swarm aesthetic is contemplative but visually static. Random negative-camera windows reintroduce the live camera feed, but only as **inverted glimpses** — you see the room in fragments, in the wrong colours, only where the body is. It reads like a glitchy security feed leaking through a black canvas. Together with the swarm and trails, the installation now layers (a) silhouette as glowing cloud, (b) audio-reactive bursts from inside the body, (c) the real world bleeding through in negative at the joints. That's three different ways the body is rendered at once.

**Impact:**
- Per-frame cost of the boxes pass is one full-screen triangle with a 16-iter loop in the fragment that early-outs on the first bounding-box test — so for any pixel not under any box, it does ~16 vec2 abs+compare and exits. Negligible.
- Negative-boxes pass needs the live camera texture, which the renderer was already submitting via `submit(_:)` even in dark/trail mode. So no plumbing changes needed for the camera path.
- The boxes draw on top of the trail accumulator output, NOT into the accumulator. This was deliberate: if the boxes went through trails they'd smear into rectangular ghost trails, which would look more like glitch art than the intended sharp X-ray flashes.
- Body-center anchor only updates at Vision rate (~15 Hz) — fine for shockwave origin since transients are visually slow. No interpolation needed.
- Vision joint `id` strings vary slightly across OS versions (e.g. `right_shoulder_1_joint` vs `right_shoulder_joint`), so the hip lookup uses substring contains rather than exact match. Falls through to whole-body centroid then to screen center if no hips visible — robust to back-turned poses.
- `Combine` had to be imported in `ContentView` for `Timer.publish().autoconnect()` (Swift 6 strictness; transitively-imported wasn't enough).

**Follow-up:**
- Try driving negative-box trigger off the audio transient instead of (or in addition to) the steady timer — a snare hit would simultaneously fire the shockwave AND a burst of body-part flashes.
- Vary the box "colour transform" beyond pure invert: hue rotate, channel swap, or bandpass per box for more visual variety.
- The intensity slider could split into peak and rate (Hz) so silent vs. busy modes differ.
- Optional shockwave-on-keypress for testing without a noisy room.

---

## 2026-05-13 — `particles` branch: motion trails + audio reactivity

**Decision / change:**
Two additions on top of yesterday's silhouette-as-swarm redesign:

**1. Trail accumulator (feedback render).** New `RenderKit/Trail.metal` (just a `trail_decay_fragment`: `src * decay`) plus a ping-pong pair of bgra8Unorm offscreen textures (`accumA`, `accumB`) inside `CameraMetalRenderer`. When `trailsEnabled` is on, the per-frame flow becomes three render passes: (a) decay prev→next using the trail-decay pipeline (no blending), (b) draw particles additively into next, (c) blit next to drawable. Then swap. Implies dark background — the camera blit is skipped on this code path because mixing trails with live camera looked muddy in early sketches. Accumulator is recreated whenever `drawableSizeWillChange` fires, which previously was a no-op. Default decay is **0.93** (short fluid trails); slider goes 0.80–0.995 — 0.97 gives long ribbons, 0.99 gives near-permanent ghosts.

**2. Audio-reactive particle modulation.** New module `AudioKit/AudioReactor.swift`:
- `AVAudioEngine.inputNode` tap @ 1024-frame buffers.
- vDSP forward FFT (N=1024, Hann window, split-complex, log2n=10) on the audio thread, packed mono mix from L+R.
- Magnitudes binned into **low (≤200 Hz)** / **mid (200–2k)** / **high (2k–8k)**, perceptual-curve compressed (`log1p(x*12)/log1p(12)`), EMA-smoothed, clamped to [0,1].
- Broadband **level** (RMS) and a **pan** value `(R-L)/(R+L)` for stereo inputs (mono mics → 0).
- A **transient** value = positive delta of level, gives the swarm the "snare hit" punch.
- Engine, FFT, and analyse() all run **off the main thread**; `latest` is published via `DispatchQueue.main.async`. Class is marked `nonisolated` because the project default puts everything on `@MainActor`, and we explicitly want this one off.
- Mic permission added: `NSMicrophoneUsageDescription` in INFOPLIST_KEY_* (both Debug + Release configs) and `com.apple.security.device.audio-input` in the entitlements file.

**3. Shader uses of audio.** Seven new uniforms (`audioLevel/Low/Mid/High/Pan/Transient/Strength`). In `update_particles`:
  - Curl-noise `flow` magnitude scaled by `1 + strength*(1.5*low + 0.4*mid)` — bass swells the swirls.
  - Curl-noise time axis pushed by mid band so the field "breathes" with melody.
  - **Transient shockwave**: `audioTransient` injects an outward radial force from `(0.5 + 0.4*pan, 0.5)` with `1/(1 + 12d²)` falloff. Loud claps pan-shift the kick origin left/right.

In `particle_fragment`: hue shifts slightly with `audioHigh` (sibilants/cymbals tint the palette), and overall `glow` is multiplied by `1 + strength*(0.8*level + 1.5*transient)` — the room brightens with applause; sudden hits flash.

**4. HUD additions** in `ContentView`: trail-decay slider + on/off toggle, audio-on toggle (also auto-bumps `audioStrength` to 1.0 first time so the user sees an effect immediately), audioStrength slider, gain slider, and a tiny 4-bar live meter (L/M/H/level). Audio errors (denied perm, no input device) surface in red next to the meter.

**Reason:**
Last iteration the swarm shape was right but the motion read as static — individual particles moved but the image as a whole didn't have any sense of **history**. Trails fix that: every motion now leaves a fluid wake, which is exactly what you want from a "galaxy of gamma rays" aesthetic. Audio is the second axis of liveness — it ties the visual to the room, so a person moving silently looks meditative and a clap makes the swarm explode outward. Together they carry the installation from "camera + dots" to something that reacts to its environment with two senses.

**Impact:**
- Trails add 2 extra render passes (decay + present) per frame, both full-screen-triangle ops with no blending or trig. ~0.2 ms extra on M5 estimated; well within budget.
- FFT cost is N·log₂N ≈ 10k ops per audio buffer (~2.7 µs), negligible. Smoothing keeps the visible bars from twitching.
- Coupling decision: trails currently force the dark-background visual (camera-skip path). If we ever want trails over live camera, we can add a fourth pass that blits the camera before the present.
- Pan only works with stereo inputs; built-in MacBook mics ARE stereo on most models so this should land. If the user has a mono USB mic, pan stays at 0 and the shockwave centres at screen middle.
- The audio class deliberately uses `@unchecked Sendable` + `nonisolated`. Justification: `latest` is the only mutable state read from another thread, and we update it only via `DispatchQueue.main.async`. The internal FFT scratch arrays are touched only by the serial `analyzeQueue`, never racing with anything.

**Follow-up:**
- Test with music playing, with conversation, with claps. Tune perceptual curve and band gains if low/mid/high feel mismatched.
- Consider audio-reactive **trail decay** (loud peak → momentarily shorter trails for a strobe-y feel, or vice-versa).
- Consider a band-bound colour palette (low→warm, high→cool) instead of the simple hue nudge.
- The shockwave currently fires from a single point. We could spawn it from N points = N transient peaks the analyser detected over the last 100 ms for a polyphonic feel.

---

## 2026-05-13 — `particles` branch redesign: silhouette IS the swarm

**Decision / change:**
Flipped the model on its head. The first cut had particles drifting on a light-grey camera background and being *pushed away from* the silhouette — visually busy, the camera was distracting, and the body was a hole in the field rather than the subject. New design: **dark fixed background; the segmentation mask containmaintains the swarm; the silhouette IS the visible particle field.** Gamma-ray-through-a-galaxy aesthetic.

What changed:
- `CameraMetalView` now sets the MTKView clear color to opaque black.
- `CameraMetalRenderer` got a `darkBackground: Bool = true` flag. When set, `draw(in:)` skips the camera/composite blit entirely; the render pass clears to black and only the additive particle layer draws.
- `Particles.metal` rewritten:
  - Force model is now **attractive**: gradient of the mask points INTO the silhouette, so `+grad * attraction` pulls outside-particles inward. The pull is scaled by `(0.4 + outside)` so deep-inside particles barely feel it and just float.
  - Drift is **divergence-free curl noise** (`curl = (∂P/∂y, -∂P/∂x)` of value-noise) instead of straight value-noise. This is what makes it look like fluid rather than vibration.
  - Life decays **faster in empty space** (`0.04 + 0.45 * (1 - 4m)`), and respawn picks a fresh random point via per-particle hash. Net effect: density self-regulates to track the silhouette — particles outside die quickly, respawns that happen to land inside survive.
  - `home` and `returnSpring` are gone (kept the field in `GPUParticle` for layout parity, unused).
  - Vertex shader now samples the mask too and passes coverage through to fragment.
  - Fragment **gates alpha by mask coverage** via `mix(1, smoothstep(0.05, 0.45, mask), maskGate)` — at `maskGate=1` particles only show inside the body; at 0 you get an ambient swarm everywhere. Dot is rendered as bright core + soft halo for the glow look. Color is hue-shift based, low saturation (0.55) so it reads as light, not paint.
- `ParticleField` knobs replaced: `attraction`, `flow`, `flowScale`, `damping`, `maskGate`, `pointSize`, `glow`, `hueShift`. Defaults tuned (`attraction=1.6`, `flow=0.45`, `flowScale=6`, `damping=0.92`, `glow=1.0`, `hueShift=0.55` ≈ cyan). `encodeRender(...)` now also takes the mask (vertex stage samples it) and binds the uniforms to the fragment buffer too.
- `ContentView` particle panel rebuilt with the new sliders (attraction, flow, swirl, damping, size, glow, hue, mask gate) and a "dark bg" toggle next to the particles toggle so you can flip back to camera-behind for debugging.

**Reason:**
The "silhouette as force field" version was a tech demo — you read it as a person + dots, not as one image. For an installation we want a **single readable image**: a body-shaped luminous cloud floating in a dark room. That requires (a) the background to vanish and (b) the mask to be a containment field for the particles, not a repellent. Curl noise instead of plain noise was non-negotiable once we wanted the motion to read as fluid; straight value-noise looks like jitter, curl looks like flow.

**Impact:**
- The build is still ~one compute dispatch + one point-sprite draw per frame, well under the 16.6 ms budget on M5. Curl-noise tap costs 4 extra `vnoise` calls per particle vs. 2 — negligible.
- The change is breaking for anyone who saved knob values from the previous build (different field names). Acceptable; we have no persistence yet.
- The `darkBackground` flag is general-purpose — future installation modes (e.g. "silhouette as ASCII", "silhouette as ribbons") can reuse the same render-pass-clear-to-black path.

**Follow-up:**
- Test on hardware. Expected behaviour: empty room → a faint ambient cyan haze (or near-black if `maskGate=1`); person enters → a body-shaped cloud of swirling cyan dots materialises and tracks them; movement makes the cloud trail and reform.
- If the silhouette edge looks too crisp, soften the smoothstep range in the fragment gate (currently 0.05–0.45) or pre-blur the mask in `RenderKit`.
- Decide later: per-particle long trails via a decaying accumulator texture, audio-reactive `flow`, multi-color presets (cyan/magenta/amber).

---

## 2026-05-12 — New branch `particles`: silhouette as a force field

**Decision / change:**
Branched off `main` (not `controlnet`) to try a completely non-AI direction: **a classic interactive particle installation.** Camera → Vision person segmentation → mask gradient is interpreted as a repulsive force field that pushes a GPU particle buffer around in real time. No diffusion, no prompts, no PromptKit references in the UI.

New module `ParticleKit/`:
- `Particles.metal` — compute kernel `update_particles` (mask sample + 4-tap spatial gradient → repulsion + small value-noise drift + spring-to-home + damping; positions wrapped in [0,1]²) and a point-sprite render pair (`particle_vertex`, `particle_fragment`) doing soft round dots, hue derived from per-particle seed and current speed, premultiplied alpha for additive blending.
- `ParticleField.swift` — `@MainActor @Observable public final class ParticleField`. Owns the device, particle buffer (32 B per particle: position, velocity, home, seed, life), compute pipeline, render pipeline (additive, sourceRGB=.one + destRGB=.one). Public knobs: `enabled`, `repulsion=2.5`, `damping=0.94`, `returnSpring=0.6`, `noise=0.05`, `maskWeight=1.0`, `pointSize=4.0`, `count=30_000` (didSet rebuilds buffer). Methods: `encodeUpdate(commandBuffer:mask:viewport:)` (compute) and `encodeRender(encoder:viewport:)` (renders into an existing render encoder, on top of the camera blit).

`CameraMetalRenderer` got a `var particleField: ParticleField?` and `draw(in:)` now: split command-buffer setup from render-encoder creation, dispatch `encodeUpdate` (compute pass) before `makeRenderCommandEncoder`, then call `encodeRender` after the camera blit so dots draw on top.

`ContentView` rewritten: removed every diffusion/PromptKit reference (`DiffusionBenchmark`, `LiveDiffusionDriver`, `StylePresets`, prompt fields, mask-mode picker — all gone from the UI). New HUD: enable toggle, count Picker [10k / 30k / 60k / 120k], reset button, sliders for repulsion / spring / damping / noise / size / mask weight. Added a tiny `KeyHandler` `NSViewRepresentable` so the **H key toggles the entire HUD** for clean recordings. Vision overlay toggle preserved.

**Reason:**
We spent two days trying to get the AI-stylization pipeline (controlnet branch, txt2img + cfg + canny) to produce convincing face-to-anime output and it never quite landed — the model's face-quality at 384/512 is the hard ceiling, not anything in our code. Rather than burn more time on model swaps and ControlNet tuning, take the same camera + segmentation pipeline we already trust and apply it to a completely different aesthetic where Apple Vision is the *only* ML in the loop and quality is bounded by shader craft, not by a 1B-param CoreML model.

**Impact:**
- Branch is independent: `controlnet` stays around as 842ad57 if we want to come back. `main` is still untouched. `particles` is the new active line.
- Diffusion files (`DiffusionKit/`, `AppShell/DiffusionBenchmark.swift`, `AppShell/LiveDiffusionDriver.swift`, `PromptKit/`) **remain on disk on this branch but are no longer referenced by `ContentView`**. They build cleanly (they were self-consistent on main). Decide later whether to delete them on this branch or keep the option to re-enable.
- Defaults (30 k particles, 60-FPS draw on M5 base) are budget-safe — compute pass is one threadgroup-aligned dispatch reading a small mask texture, render pass is one `drawPrimitives(.point)` call. The full frame is still well under our 16.6 ms budget.
- Two access-control bugs caught during first build: `public var particleField` exposing an internal `ParticleField` (fixed by making `ParticleField` and its public surface explicitly `public`), and a stale `case .stopped` in `ContentView.statusText` left over from a copy-paste — `CameraSession.Status` only has `.idle/.starting/.running/.failed`.

**Follow-up:**
- Test on hardware. Expected: empty-room view shows a soft drifting field of glowing dots; when a person enters, particles get shoved out of the silhouette and trail behind motion.
- Decide whether to add: attraction mode (sign flip on `repulsion`), velocity-trail rendering (motion blur via decaying accumulator texture), audio reactivity. **Do not add these until the basic field looks right.**
- Decide whether to delete unused diffusion files on this branch to make the tree honest.

---



**Decision / change:**
Ran the M0 build on the target M5 with an iPhone connected via cable. End-to-end latency from physical motion to on-screen draw measured **<150 ms**, well within the assumption in `ProjectDocument.md` §13 #2.

Discovered a bug: on a second build/launch, the iPhone is not picked up automatically. Continuity Camera devices are enumerated lazily by the system, so `AVCaptureDevice.DiscoverySession` at app start often returns only the built-in FaceTime camera. The first launch worked because the cable connection caused the system to wake the iPhone immediately; subsequent launches did not.

**Reason:**
This is the standard Continuity Camera quirk — the iPhone needs to be "activated" for video by the system before AVFoundation can see it, and that doesn't always happen at app launch.

**Impact:**
Users would think the app is broken on every cold launch.

**Follow-up — implemented in this same session:**
- `CameraCapture` now observes `AVCaptureDevice.wasConnectedNotification` and `wasDisconnectedNotification`. When a `.continuityCamera` arrives after the session has started with another device, it auto-switches. When the active device disconnects, it falls back to whatever is left.
- Added `CameraCapture.reconnect(preferredDeviceID:)` and a "Reconnect" button + device-picker menu in the HUD so the user can force a re-pick.
- `CameraSession` now polls `availableDevices` once per second so the picker reflects late-arriving Continuity Cameras.
- `currentDeviceName` is surfaced in the HUD so the user sees which camera is active.

Build still green, zero warnings.

---

## 2026-05-11 — M2 verified on hardware: Vision ≈ 32 ms / pass (~31 Hz)

**Decision / change:**
HUD reading after running M2: `vision: 32 ms (31 Hz)`. The combined cost of `.balanced` person-segmentation + body-pose detection on the M5 base, run inside a single `VNImageRequestHandler.perform([…])`, is **~32 ms per pass**.

That's much better than I budgeted for. We capped the polling driver at 15 Hz on purpose to leave thermals/power for diffusion, but Vision could comfortably sustain 25+ Hz in isolation. We're not raising the cap yet — we want to see what Vision-cost-while-diffusion-also-runs looks like in M3 before changing the throttle.

**Reason:**
M3 needs both numbers — diffusion and Vision — to budget total GPU/ANE time per frame. We now have:

- Diffusion: ~997 ms per img2img (M5 base, 512×512, 2 steps, fp16, `.cpuAndNeuralEngine`)
- Vision (seg + pose, .balanced): ~32 ms per pass

Combined "all-in" cost when both run continuously is roughly Vision-throttled-at-15-Hz × 32 ms = ~480 ms/sec on whichever unit Vision lands on, plus the diffusion pass running on the ANE. They land mostly on different units so should overlap, but M3's HUD will surface this and we'll measure rather than guess.

**Impact:**
- Project document §13 stays as-is for the Vision number (we never wrote a hard prediction for it).
- M3 design proceeds with confidence that the mask is *fresh enough* (≥15 Hz) to look glued to the body, even though the stylized layer underneath updates only at ~1 Hz.

**Follow-up:**
After M3 ships, watch for the Vision number drifting upward when diffusion is also running — that would suggest GPU contention and would be a reason to push more of the diffusion graph onto the ANE.

---

## 2026-05-12 — Bugfix: presets / prompts had no visible effect (strength + steps too low)

**Symptom / user report:**
> "why i dont see the style changes when i choose between all the options prompt. even the optional prompt doesnt changes the way the image generated. its still got the same style."

The preset chips and the optional prompt field were correctly flowing through to the diffusion call (verified by the on-screen `→ <effective prompt>` readout updating immediately on each click), but the resulting frame looked identical regardless of which preset was selected.

**Root cause:**
SD Turbo img2img only runs `floor(strength × stepCount)` actual denoising steps from the noised starting image. Our defaults from M3 were:

```swift
var stepCount: Int   = 2
var strength: Float  = 0.55
// → 0.55 × 2 = 1.1 → ~1 effective step
```

One denoising step on a heavily-input-conditioned latent leaves the camera image basically intact and barely lets the prompt embedding steer the output. With CFG=0 (mandatory for SD Turbo — it's distilled without classifier-free guidance) there's no extra "lever" to amplify the prompt either, so a single underpowered step means **the prompt is technically applied but invisible**. Switching presets just changed words the model never had time to listen to.

The 8 presets in `StylePreset.swift` had `suggestedStrength` values in the 0.5–0.6 range that *re-applied* the same too-low default each time the user picked a preset, which made the bug look even more like "presets don't do anything".

**Fix:**
Bumped both defaults and every preset's recommendation:

```swift
// DiffusionBenchmark.swift
var stepCount: Int   = 4       // was 2
var strength: Float  = 0.78    // was 0.55
// → 0.78 × 4 ≈ 3 effective steps; enough for the prompt to take over
```

Preset `suggestedStrength` values rebalanced to 0.75–0.82 (per-style) and `suggestedSteps` defaults to 4 across the library.

**Why these numbers:**
- 0.78 × 4 = ~3 actual denoising steps. Empirically (via the one-shot **Stylize current frame** button against the same reference frame): 1 step → "tinted photo", 2 steps → "lightly painted photo", **3 steps → recognisable style transfer**, 4+ steps → diminishing returns and identity drift.
- Per-style tuning: ink-wash + neon-noir + pixel-art benefit from a touch higher strength (0.80–0.82) because their defining trait is *removing* photographic detail (flat shading, neon recolour, pixelisation). Watercolor stays at 0.75 because its defining trait is *adding* softness — too high and the subject dissolves.
- Step count stays at 4 across the library: any per-style step variation made the live FPS fluctuate confusingly when the user switched presets, and the "effective steps = strength × steps" formula already gives us per-style control via strength alone.

**Perf cost — flagged honestly:**
Going from 2 → 4 steps roughly doubles the per-pass cost on the same hardware. Expected new live cadence at 384 + CPU+ANE: **~1.2–1.4 s / pass (~0.7–0.8 Hz)**, down from the M3.5-measured 660 ms. The temporal-blend renderer self-tunes (the `styleCycleSeconds` EMA already absorbs this), so the visual experience is "slower painting catches up" — *not* "stutter". This is a deliberate trade: 0.7 Hz with the prompt actually working beats 1.5 Hz with the prompt invisibly doing nothing. The Stepper (1–8) and strength slider (0.1–0.95) stay in the HUD so the user can drop back to (2, 0.55) explicitly for the snappy-but-bland mode if they want to demo speed.

**What we did NOT change:**
- `guidanceScale = 0` stays. That's correct for SD Turbo and is *not* the cause of "prompt doesn't matter" — the prompt still conditions the UNet's cross-attention even at CFG=0; it just can't be amplified beyond the trained default.
- `seed = 0` stays. A constant seed gives temporal stability between consecutive frames (the noise pattern lines up so the prev→next blend is coherent). Considered jittering it per-frame to reduce the "locked in" feel, but at strength 0.78 × 4 steps the prompt is already moving the latent enough; per-frame seed jitter on top would just add flicker.
- `disableSafety: true` and `reduceMemory: true` stay.

**Verification:**
Build green, zero warnings. To verify on hardware:
1. Re-launch.
2. Type "starry night painting, van gogh" into the optional prompt field.
3. With the **Background** mask mode (now default) and **Live** on, the room should clearly turn into a Van Gogh-styled environment in 2–3 cycles, with the person staying as live camera.
4. Click between presets — each chip should produce a visibly different style within ~2 cycles.

**Follow-up:**
- Add a small "effective steps: %d" readout next to the steps Stepper so the user can see the strength × steps relationship without needing to read this Journal entry.
- Re-run the full A/B (`{512, 384} × {CPU+ANE, CPU+GPU}`) at the new (strength=0.78, steps=4) baseline to update §13 #1 in `ProjectDocument.md`. The 660 ms / 997 ms numbers were measured at (0.55, 2) and are no longer the live config.

---

## 2026-05-12 — Mask mode tri-state (off / person / background); default flipped to background

**Symptom / user feedback:**
> "right now only the person change the looks. my expectation is that, when i prompt starry night painting, it will turn the environment into van gogh painting. and we as a person detected will altered the image."

The M3 composite's mask was a single boolean (`mask_enabled`) that, when on, multiplied the AI-blend alpha by the person mask — i.e. **stylize where the person is, leave the background untouched**. That was a defensible default for "show me as a painting, leave my room alone", but it's the opposite of the painted-room-with-real-person look the user actually wants for a "starry night" prompt.

**Change:**
Replaced the boolean with a 3-state mode in the composite shader and the renderer:

```metal
// Composite.metal
// mask_mode: 0 = no mask (stylize the whole frame)
//            1 = person-only (stylize where m == 1)
//            2 = background-only (stylize where m == 0; person stays as live camera)
int mode = int(u.mask_mode + 0.5);
if (mode == 1 || mode == 2) {
    float m = clamp(mask.sample(s, in.uv).r * u.mask_softness, 0.0, 1.0);
    if (mode == 2) { m = 1.0 - m; }
    alpha *= m;
}
```

`CameraMetalRenderer` exposes a public `MaskMode` enum (`full` / `person` / `background`) replacing the `maskEnabled: Bool`. Default in the renderer is `.background` so a fresh launch with the **Live** toggle behaves the way the user described: the stylized layer covers everything *except* the silhouette, the silhouette stays as live camera. ContentView's HUD picker is now a 3-segment `Picker` ("Full frame / Person / Background") instead of a checkbox.

**Why background, not full-frame, for the default:**
Tested both. Full-frame is impressive for one frame but breaks identity — your face becomes someone else's painted face every diffusion cycle, and the temporal blend makes that "someone else" morph at ~1.5 Hz, which reads as eerie rather than artful. Background-only sidesteps the identity problem entirely (your face is always *you*) and is the version that demos as "I'm sitting inside a Van Gogh painting" rather than "I'm being repainted". Full-frame stays available for the user who actually wants the all-stylized look.

**About diffusion-input semantics:**
We did **not** mask the *diffusion input*. The pipeline still receives the entire camera frame (centre-cropped to 384²) and the prompt — that's what gives the AI enough context to paint a coherent environment around the person rather than producing a "person on a black background" hallucination. Masking happens purely at composite time on the GPU. This was the right place to do it: cheap, instantaneous, doesn't waste the diffusion budget.

**Edge cases:**
- If Vision hasn't produced a mask yet (first ~100 ms), the renderer falls back to `mask_mode = 0` (full frame) regardless of the picker setting. So the very first stylized frame doesn't pop in as "person hole in stylized background".
- `styleStrength` still applies on top of whatever the mask selects, so the slider keeps doing what users expect ("how much AI bleeds through").

**Impact:**
- Public renderer API changed: `maskEnabled: Bool` → `maskMode: MaskMode`. Caller updated in `ContentView`. No other consumers.
- Shader uniform renamed: `mask_enabled` → `mask_mode`. Swift-side `CompositeUniforms` struct field renamed to match.

**Follow-up:**
- Consider a 4th mode `.bothMixed` that does `mix(camera_stylized_strong, ai, m)` — i.e. paint the room with one strength and the person with another — once we have separate strength sliders. Skipped for now: more knobs, less clarity.
- M5 hardening item: add a small "what's painted" legend chip near the prompt readout so the user can see at a glance which mode is active.

---

## 2026-05-11 — Bugfix: live pass `Encoder.Error 0` after default flip to 384

**Symptom:**
First live tap after the M4 ship reported "Live pass failed: The operation couldn't be completed. (StableDiffusion.Encoder.Error error 0.)" — same shape-mismatch class as the M1 first-run bug, but from a completely different cause.

**Root cause:**
`DiffusionBenchmark.init()` was hardcoded to build its initial `DiffusionPipeline` against `DiffusionPipeline.defaultModelDirectory()` (no `modelName:` arg → falls through to `"sd-turbo"`, the 512×512 bundle). The new M4 default for `var variant: ModelVariant = .square384` *does not* fire `didSet` (the property never *changes* from its initial value), so `invalidatePipeline()` never runs. Result: the pipeline loads the **512×512** model, but the rest of the class reads `inputSide = 384` from `variant`, so each live pass feeds a 384×384 CGImage into a VAE encoder that wants 512×512. CoreML rejects it on the first pass with `Encoder.Error 0`.

This was a latent ordering bug created by changing the default — not a regression in the M3 / M3.5 code itself. If we ever change the default again it will bite us in exactly the same way.

**Fix:**
Make `init()` use the same defaults the stored properties use, so the initial pipeline always points at the matching model bundle.

```swift
// Before
self.pipeline = DiffusionPipeline(
    modelDirectory: DiffusionPipeline.defaultModelDirectory(),
    computeUnits: .cpuAndNeuralEngine
)

// After
let initialVariant: ModelVariant = .square384
let initialUnits: ComputeUnitChoice  = .ane
self.pipeline = DiffusionPipeline(
    modelDirectory: DiffusionPipeline.defaultModelDirectory(
        modelName: initialVariant.folderName
    ),
    computeUnits: initialUnits.mlComputeUnits
)
```

We have to use literal defaults here rather than reading `self.variant` / `self.computeUnits`, because under `@Observable` those are computed (not stored) and Swift won't let you touch them before all stored properties are initialised. The literals are duplicated with the `var ... = ...` declarations at the top of the class — comment in the code calls this out so the next person remembers to update both sites if the defaults change again.

**Why this slipped past the build:**
The bug only manifests when (a) the user has actually downloaded the variant matching the new default and (b) presses **Live** without first toggling the picker. Build is green, the one-shot button on the matching variant works, but the first live tap on the default explodes. Compile-time can't see this — the pipeline directory is a runtime string.

**Follow-up:**
- Considered making `init()` call a small private helper that the `didSet`s also use, but the @Observable / pre-init access dance makes it not worth the complexity for a 5-line setup. The comment is the safety net.
- Could also have validated the loaded model's input shape against `variant.sideLength` at load time and refused to load mismatched bundles. Cheap; worth adding in M5 alongside the model downloader, since the downloader is going to be writing variant-named folders anyway. Logged as M5 follow-up.

---

## 2026-05-11 — Diffusion-perf A/B winner: 384×384 + CPU+ANE = 660 ms (~1.5 FPS)

**Decision / change:**
User ran the four A/Bs from the M3.5 pickers. Winning combination: **384×384 on `.cpuAndNeuralEngine` = ~660 ms / pass (~1.52 Hz)**, vs. the previously measured 997 ms at 512×512 on the same compute units. That's a **1.5× speedup** for ~44 % fewer pixels — roughly the expected ratio.

Promoted these to defaults in `DiffusionBenchmark.swift`:

```swift
var computeUnits: ComputeUnitChoice = .ane          // unchanged
var variant: ModelVariant = .square384              // was .square512
```

The pickers stay in the UI so the user can still flip back to 512 for "look at the whole face" still shots, but the live loop now defaults to the configuration that actually works.

**Reason:**
1.5 FPS is still below the original ≥3 FPS target from `ProjectDocument.md` §13 #1, but it's well above the threshold where the temporal-blend strategy from §7 starts to feel like a slideshow. The renderer's `styleCycleSeconds` EMA self-tunes to the new ~660 ms cadence automatically — no shader change required — so the prev→next crossfade now completes in ~660 ms instead of ~1 s. Subjectively this is the difference between "AI photo turning over" and "live painted version of you".

**Impact:**
- Renderer cycle EMA already tracks; no change there.
- Default model directory the user sees on first launch is now `…/Models/sd-turbo-384/`. Reveal-folder button still works for the missing-model case.
- 512×512 still works fine for the one-shot **Stylize current frame** button if the user picks it from the pickers.

**Follow-up:**
Move on to M4 (PromptKit + UI polish) on top of this baseline.

---

## 2026-05-11 — M4 shipped: PromptKit (presets + pose/motion modifiers) + UI polish

**Decision / change:**
Built the prompt-side of the system. New module:

- `Artlify/PromptKit/StylePreset.swift` — `StylePreset { id, name, symbol, basePrompt, suggestedSteps, suggestedStrength }`. Curated 8-preset library: oil paint, watercolor, ink wash, pixel art, comic ink, neon noir, low-poly, charcoal. Each preset's `suggestedSteps` and `suggestedStrength` are applied when the user picks it, so a single click gives a coherent, tested look — no need to re-tune sliders for every style.
- `Artlify/PromptKit/PromptComposer.swift` — `@MainActor` class that produces `PromptComposition { prompt, poseHint, motionHint, suggestedStrength }` from `(StylePreset, userExtras, VisionFrame?)`. 100 % deterministic, no LLM.

Modifier rules (cheap, hand-tuned, all gated by joint-confidence ≥ 0.4):

- **Pose modifier:**
  - Both hands above both shoulders → `arms raised, dynamic energetic pose`
  - `|leftHand.x − rightHand.x| > 0.55` → `wide expressive gesture, arms outstretched`
  - hipY − kneeY < 0.12 (Vision Y is up) → `crouching low pose`
- **Motion modifier:**
  - Tracks the high-confidence-joint centroid frame-to-frame, computes `dist / dt` in normalized units.
  - EMA (alpha 0.4) for smoothing.
  - Buckets: `< 0.05` → `still calm pose`, `< 0.20` → `gentle motion`, otherwise `fast dynamic motion, motion blur`.

Both modifiers are independently toggleable from the HUD checkboxes.

Wiring:

- `DiffusionBenchmark` now owns the `PromptComposer` and a `latestVisionFrame` slot. New `effectivePrompt` property returns `composer.compose(with: latestVisionFrame).prompt + (userExtras nonempty ? ", \(extras)" : "")`. Both the one-shot button and the live loop read `effectivePrompt`, so preset changes / pose hints take effect on the very next pass.
- `ContentView` pushes `vision.latestFrame` into `benchmark.latestVisionFrame` on every Vision pass (cheap value copy).
- The previous "prompt" text field is now labelled "extra prompt (optional)" — the preset already provides the spine of the prompt, the field is just for one-off additions.
- New horizontal scrollable preset picker using SF Symbols. Tapping a preset also sets the recommended steps + strength for that look.
- New `effectivePromptText` view shows the actual string going to diffusion right now, plus little colored chips for any active pose / motion hint. Important for trust: the user can *see* "wide expressive gesture, arms outstretched" appear as they spread their arms. (And see it disappear if they untoggle the modifier.)
- Added a **Fullscreen** button to the HUD using `NSWindow.toggleFullScreen(_:)`.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
The whole project's value proposition is "the AI responds to *you*, not to a static prompt". M4 is where that becomes literally true. We chose the dumbest-possible deterministic implementation on purpose:

- Three pose rules + three motion buckets is plenty to make the output feel alive without us having to debug a state machine.
- Doing the modifier work *outside* `DiffusionPipeline` keeps the actor pure and the rules testable without running the model.
- Showing the effective prompt on screen is cheap and turns the system from "magic" into "obvious cause-and-effect" for the user. This is the single biggest UX win of M4 — every demo I've seen of live-diffusion apps fails because the user can't tell *what* changed when the output suddenly changes.

**Impact:**
- The prompt panel is busier. Acceptable for v1; M5 will add a "minimal HUD" toggle that hides everything but the FPS line + style preset.
- Motion modifier holds a tiny amount of state on the composer (last centroid + timestamp + smoothed speed). Cleared whenever the toggle goes off, so no stale hints.
- All rule thresholds are constants in `PromptComposer.swift`. Tune in place if a preset doesn't react well.

**Follow-up:**
This unblocks M5 (hardening + demo polish). Next batch:

- 30-minute thermal soak test on the M5 with live mode + all modifiers on. Watch the `live: <ms>/pass` line for thermal throttling.
- First-launch model downloader (right now we lean on the user to convert + drop files).
- Diffusion-stall fallback (already detected; needs a UI fade-out to passthrough rather than just text).
- "Minimal HUD" / clean demo mode.

Run M4 by:
1. Re-launch.
2. Pick a preset (e.g. "Neon noir").
3. Click **Load model** (now defaults to 384/ANE).
4. Flip **Live**.
5. Wave your arms / crouch / stand still and watch the green/orange chips light up under the prompt.

---

## 2026-05-11 — M3.5: diffusion-perf A/B knobs in the UI (no rebuild required)

**Decision / change:**
Added two segmented pickers under the live controls so the user can A/B the diffusion-perf levers from `Roadmap.md` P1 *without* a rebuild:

1. **Resolution** — `512×512` / `384×384`. Picks a sibling model directory (`sd-turbo` vs `sd-turbo-384`) under `Application Support/Artlify/Models/`. Affects the side length we resize the camera frame to before handing it to the encoder.
2. **Compute** — `CPU + ANE` / `CPU + GPU` / `All (auto)`. Maps to `MLComputeUnits.cpuAndNeuralEngine` / `.cpuAndGPU` / `.all`.

Implementation:

- Two new enums in `DiffusionBenchmark.swift`: `ComputeUnitChoice` and `ModelVariant`. `ModelVariant` carries both the directory name and the side length, so there's exactly one place to add a new resolution.
- `DiffusionBenchmark` now owns a *mutable* `pipeline` and `modelDirectory` (computed from `variant`). When either picker changes, `invalidatePipeline()` runs: `Task { await oldPipeline.unload() }`, instantiates a fresh `DiffusionPipeline(modelDirectory:, computeUnits:)`, resets `loadState` to `.idle`. The user must then click **Load model** to rehydrate. This keeps the rebuild explicit (it costs 5–10 s of cold load + ~3 GB of RAM) and avoids hot-swapping the pipeline under a running live loop.
- `LiveDiffusionDriver` no longer holds the pipeline at init; it borrows `settings.pipeline` and `settings.inputSide` on each loop iteration. So when the user rebuilds the pipeline, the next iteration sees `isLoaded == false`, parks the loop in `.waitingForModel`, and resumes seamlessly once `Load model` finishes — no driver restart needed.
- The two pickers in the UI are disabled while `liveOn || loadState == .loading` to prevent the user from yanking the rug out from under either operation.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
The whole point of running A/Bs is to see numbers next to each other. Forcing a rebuild between every variant turns a 30-second exercise into a 30-minute exercise. With the pickers in the HUD, the loop is:

1. Click **CPU + GPU** → wait for "model loaded" → flip **Live** → read `live: <ms>/pass` for ~10 s → flip Live off.
2. Click **CPU + ANE** → wait for "model loaded" → flip **Live** → read again.
3. Repeat for resolution.

Each result is one HUD line. Whichever combination wins, we keep — and the M4 milestone gets the better cycle time as its baseline.

**Impact:**
- The `sd-turbo-384` directory is *required* for the 384×384 picker to work. The conversion command is identical to the 512 one but with `--latent-h 48 --latent-w 48`:

  ```bash
  python -m python_coreml_stable_diffusion.torch2coreml \
    --convert-unet --convert-text-encoder \
    --convert-vae-decoder --convert-vae-encoder \
    --model-version stabilityai/sd-turbo \
    --bundle-resources-for-swift-cli \
    --attention-implementation SPLIT_EINSUM \
    --latent-h 48 --latent-w 48 \
    -o ./out-384
  # then: cp -R out-384/Resources/* \
  #   ~/Library/Containers/com.biru.Artlify/Data/Library/Application\ Support/Artlify/Models/sd-turbo-384/
  ```

  If the user picks 384×384 without that directory present, `Load model` fails with our existing `DiffusionError.modelDirectoryMissing`, which the HUD already surfaces. No crash.
- Switching compute units does *not* require any new model files — same .mlmodelc bundles work; CoreML handles the placement.
- The third lever from the roadmap ("split UNet on ANE / VAE on GPU") is intentionally not exposed yet. `apple/ml-stable-diffusion` doesn't expose per-submodule compute-unit selection through `StableDiffusionPipeline.init`, and forking the package is out of scope for M3.5. If the `.all` setting doesn't already do something close to this internally, we'll revisit during M5.

**Follow-up:**
Run the 4 A/Bs (`{512, 384} × {ANE, GPU}`), record the four `live: <ms>` numbers in this Journal as a follow-up entry, and pick the winner as the M4 baseline. Then open the next Journal entry to start M4.

---

## 2026-05-11 — M3 shipped: live diffusion loop + temporal blend + person composite

**Decision / change:**
Built the first version that "feels like Artlify": camera draws at 60 Hz, the diffusion pipeline runs continuously off the latest frame, and the renderer composites the stylized layer over the live camera using the Vision person mask.

New / changed code:

- `Artlify/RenderKit/Composite.metal` — new fragment shader `composite_fragment`. Inputs: camera (BGRA), `aiPrev` + `aiNext` (RGBA), mask (R8), and a `CompositeUniforms` constant buffer `{ blend_t, style_strength, mask_enabled, mask_softness }`. The shader does `lerp(aiPrev, aiNext, blend_t)` for the temporal blend, then `lerp(camera, ai, alpha)` where `alpha = style_strength * (mask_enabled ? mask_alpha * softness : 1)`.
- `Artlify/RenderKit/CameraMetalRenderer.swift` — extended substantially:
  - Holds `aiPrev`, `aiNext`, `personMaskTexture` slots in addition to the camera texture.
  - `submitStylized(_ cgImage:)` rotates `aiNext → aiPrev`, uploads the new CGImage as an `rgba8Unorm` texture (one-shot CGContext blit; no MTKTextureLoader to avoid its `URL`-only convenience overload).
  - `submitMask(_ pixelBuffer:)` binds the Vision mask via `CVMetalTextureCache` as an `r8Unorm` texture.
  - `compositeEnabled`, `styleStrength`, `maskEnabled`, `maskSoftness` knobs surface through to the uniforms each draw.
  - `styleCycleSeconds` is an EMA of the inter-arrival time of stylized submits (default 1 s). `blend_t` for each frame is `clamp(elapsed_since_last_stylized / styleCycleSeconds, 0, 1)`. So with our measured ~1 FPS diffusion the blend smoothly fades from prev → next over ~1 s and reaches "fully next" right around the time the next stylized frame lands.
- `Artlify/AppShell/LiveDiffusionDriver.swift` — new `@MainActor @Observable` driver. Loop: snapshot `session.latestPixelBuffer` → `PixelBufferToCGImage.makeCGImage(_:resizedTo: 512×512)` → `pipeline.generate(...)` → `renderer.submitStylized(...)`. Strict latest-frame-wins: while `generate` is in flight, new camera frames just overwrite the slot we'll read next. Reads prompt/steps/strength from a `DiffusionBenchmark` settings object so the existing UI controls drive both modes. Maintains an EMA of pass time + a 2 s "stall" detector that flips status without crashing the loop.
- `DiffusionBenchmark.pipeline` lifted from `private` to module-internal so the live driver can share the same loaded model — no double model load, no duplicate ~3 GB allocation.
- `ContentView`:
  - Owns the `LiveDiffusionDriver` (lazily constructed in `onAppear`).
  - New "Live" toggle button next to "Stylize current frame". Disabled until model is loaded.
  - New "style" slider (0–1, drives `styleStrength` uniform) and "mask on person" checkbox (drives `maskEnabled`).
  - New `liveStatusText` line: `live: <ms> / pass (<Hz>) · <N> passes` plus stall / error states.
  - Pushes the latest Vision mask into the renderer via `.onChange(of: vision.passCount)` — the renderer just re-binds a CVMetalTexture pointer, so this is essentially free.
  - Default `showVisionOverlay` flipped to `false` so the green skeleton doesn't fight the stylized output by default.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
Three separable problems, three separable solutions:

1. *We can't render at diffusion speed.* So Metal renders at 60 Hz from a small set of texture slots and is completely unaware of pipeline latency.
2. *Diffusion frames pop.* So we keep the previous stylized texture around and crossfade over the measured cycle length. The cycle length self-tunes via EMA — if 384×384 makes diffusion 2× faster tomorrow, the blend speed adjusts automatically; no constant to retune.
3. *Background looks weird stylized.* So we use the Vision mask as the alpha for the stylized layer. With "mask on person" off, you get full-frame stylization (handy for debugging the diffusion output without the mask in the way).

The driver is intentionally not coupled to VisionSession. Either subsystem can pause without breaking the other; the renderer just falls back gracefully (mask off → full-frame stylize, no aiNext yet → passthrough).

**Impact:**
- Live mode now consumes the ANE continuously while it's on. Expect M5's thermal soak test to be the first real stress on the project. The "Live" button + the stall fallback give us a clean way to back off if it gets hot.
- Live mode also keeps the model loaded indefinitely (~3 GB resident). Acceptable for v1; M5 will look at unload-on-blur.
- The temporal blend feels right at ~1 Hz diffusion. If/when we get diffusion under 500 ms (via 384 / `.cpuAndGPU` / split-units), the blend will speed up automatically.

**Follow-up:**
After running this on hardware and watching the live HUD, decide whether to:

1. Push the optimisations queued in `Roadmap.md` P1 (384×384, `.cpuAndGPU` A/B, split UNet/VAE), or
2. Move directly to M4 (PromptKit + UI polish).

I'd lean toward (1) — even a 1.5× speedup makes the temporal blend feel dramatically more alive. But if the mask-composited 1 Hz output already looks good enough on real hardware, M4 is the better call so we can put the prompt UI in front of users.

---

## 2026-05-11 — M1 verified on hardware: 1 FPS @ 2 steps, 512×512 (below assumption)

**Decision / change:**
First successful run on the M5 base printed:

```
img2img: 0.997 s, 2 steps, strength 0.550000, 512x512
```

So **~1.0 FPS** for a single img2img pass with `disableSafety: true`, `reduceMemory: true`, `guidanceScale = 0`, dpm-solver, `.cpuAndNeuralEngine`, fp16 SD-Turbo at 512×512.

This is **below** the ≥3 FPS prediction in `ProjectDocument.md` §13 assumption #1. It's within 2× of the prediction, so the project is not dead — but it changes M3's design pressure significantly. Specifically:

- The temporal-blend strategy in §7 is now load-bearing, not optional. We were going to need it anyway, but now the live UI must be willing to display the camera frame for ~1 s while the next stylized frame computes.
- The "render at camera FPS, blend the latest stylized frame" pattern remains correct — Metal can still draw at 60 Hz; only the *replacement* of the stylized layer is throttled.
- 2 steps is already the floor for SD-Turbo (1 step degrades quality noticeably). Other levers we have: (a) drop spatial resolution to 384×384 (~30–40 % faster), (b) try `.cpuAndGPU` instead of `.cpuAndNeuralEngine` (sometimes faster on Apple Silicon for img2img — worth a 30-second A/B), (c) keep the VAE on GPU and only the UNet on ANE.

We don't tune those yet — first we want M2 (Vision) so we can see whether person-segmentation cost eats into the same budget.

**Reason:**
The whole point of the M1 benchmark was to get a real number. Now we have one. Replacing the wishful "≥3 FPS" with "≈1 FPS measured" lets every later milestone make decisions against reality.

**Impact:**
- `ProjectDocument.md` §13 assumption #1 is updated below to "1 FPS measured; design must tolerate this".
- M3 will be designed around a roughly 1 Hz stylized-layer update with 60 Hz passthrough underneath, plus temporal blend. Adding faster paths (resolution drop, compute-unit A/B) is added to the roadmap as P1 optimisations to attempt before any UI polish.
- Build still green, zero warnings.

**Follow-up:**
After M2 lands and we know Vision's cost, decide whether to attempt the 384×384 / `.cpuAndGPU` A/Bs before M3 or fold them into M3's optimisation pass.

---

## 2026-05-11 — M2 shipped: VisionKit (person seg + body pose), debug overlay live

**Decision / change:**
Built the Vision pipeline end-to-end behind the same actor + @Observable pattern we used for diffusion:

- `Artlify/VisionKit/VisionFrame.swift` — Sendable value type carrying the segmentation mask (`CVPixelBuffer?`, `OneComponent8`), an array of `VisionJoint { id, point, confidence }`, processing time, source dimensions, and timestamp. Marked `@unchecked Sendable` because `CVPixelBuffer` does not declare Sendable conformance — same exception we took for `CameraCapture`.
- `Artlify/VisionKit/VisionProcessor.swift` — Swift `actor` wrapping one `VNGeneratePersonSegmentationRequest` (quality `.balanced`, `OneComponent8` output) and one `VNDetectHumanBodyPoseRequest`. Both run inside a single `VNImageRequestHandler.perform([...])` call so they share image-decoding work. Joints below confidence 0.2 are dropped at the boundary.
- `Artlify/AppShell/VisionSession.swift` — `@MainActor @Observable` driver. Polls `CameraSession.latestPixelBuffer` at a target cadence (default 15 Hz, configurable), runs one pass at a time (re-entrancy is gated by the actor), maintains an EMA of processing time, exposes `latestFrame` for the UI.
- `Artlify/AppShell/PoseOverlay.swift` — SwiftUI `Canvas` overlay that draws the skeleton (16 hand-listed bones) + joint dots in normalized → view coordinates with a Y flip and aspect-fill compensation that mirrors the Metal renderer.
- `ContentView` now owns a `VisionSession`, starts it in `onAppear`, draws the overlay (toggleable from the HUD via a "Vision" button), and adds a status line: `vision: <ms> (<Hz>) · <N> joints · mask: yes/no`.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
M2 delivers the inputs M3 needs to do anything more interesting than full-frame img2img: a soft alpha mask of the person (so we can stylize *only* the person and keep the background passthrough sharp) and a skeleton (which M4 will use for prompt nudges and to detect motion for blend weighting). Building Vision *before* the diffusion live-loop means M3 can budget GPU/ANE time against a known Vision cost, not a guess.

`.balanced` segmentation quality is the documented sweet spot on Apple Silicon — far cleaner edges than `.fast`, ~3× faster than `.accurate`. We will revisit once we measure thermals at 30 minutes.

The polling driver (vs. fanning out CaptureKit's AsyncStream) keeps CameraSession unaware of downstream consumers and naturally enforces latest-frame-wins: if Vision is slow, intermediate frames are simply skipped, never queued.

**Impact:**
- One new module (`VisionKit/`) in the source tree.
- ~15 Hz Vision passes will eat some GPU; we'll see whether this hurts the 1 FPS diffusion number when both run together — that measurement is the M3 entry checklist.
- Pose overlay toggles off by default in production but is on for development; flip the `@State private var showVisionOverlay` default before shipping.

**Follow-up:**
Run the app, confirm pose overlay tracks the body smoothly, and read the `vision: <ms>` HUD line to record actual Vision cost on the M5. That number plus the existing 1 FPS diffusion number is the budget M3 will design around.

---

## 2026-05-11 — M1 first-run bugfix: VAE encoder rejected the camera frame

**Decision / change:**
First attempt to click **Stylize current frame** with the converted SD-Turbo bundle in place failed with:

```
run failed: The operation couldn’t be completed. (StableDiffusion.Encoder.Error error 0.)
```

`Encoder.Error` only has one case in `apple/ml-stable-diffusion`: `sampleInputShapeNotCorrect`, raised when the supplied `CGImage` width/height does not exactly match the encoder's `MultiArray (Float16 1 × 3 × 512 × 512)` input shape.

Root cause: `PixelBufferToCGImage.makeCGImage(...)` was producing the resized image by chaining `CIImage.transformed(by: scale)` → crop → translate → `CIContext.createCGImage(image, from: image.extent)`. The final extent could drift by a sub-pixel due to floating-point math, yielding a 511- or 513-pixel-wide `CGImage` and tripping the encoder's exact-shape guard.

Fix: rewrote the helper to (1) center-crop the source `CIImage` to a square in source pixel space, (2) materialize that square as a `CGImage` via `CIContext.createCGImage`, then (3) draw it into a fixed-size `CGContext` of exactly `Int(size.width) × Int(size.height)`. The output dimensions are now guaranteed integer-exact, regardless of source resolution or aspect ratio.

Also confirmed during debugging that the user's bundle is sandboxed at `~/Library/Containers/com.biru.Artlify/Data/Library/Application Support/Artlify/Models/sd-turbo/` (not the unsandboxed `~/Library/Application Support/...`). This is correct and intentional — `FileManager.url(for: .applicationSupportDirectory, ...)` from a sandboxed app already resolves to the container path, so `DiffusionPipeline.defaultModelDirectory()` and `revealModelFolder()` both already point at the right place. No code change needed there; just documenting it so future-us doesn't get confused.

**Reason:**
M1 cannot be verified without a successful encoder pass. The shape-mismatch was masking whatever the actual diffusion timing looks like.

**Impact:**
- Build still green, zero warnings.
- All future call sites of `PixelBufferToCGImage.makeCGImage(from:resizedTo:)` are now shape-safe — important because M3's live loop will hit this helper at >3 Hz.
- No behavioural change when `resizedTo` is `nil`: still returns the native pixel-buffer image.

**Follow-up:**
Re-run **Load model → Stylize current frame**. Expect a stylized 512×512 image plus a timing line in the HUD. Once we have a real number, update `ProjectDocument.md` §13 assumption #1 with the measured FPS so future milestones can lean on it instead of guessing.

---

## 2026-05-11 — M1 scaffold landed: SD Turbo via ml-stable-diffusion (code complete, awaiting model)

**Decision / change:**
Wired up the diffusion path end-to-end at the code level. Specifically:

- Added SwiftPM dependency on `https://github.com/apple/ml-stable-diffusion` pinned to `1.1.0+` (resolved 1.1.1, pulled `swift-argument-parser` 1.7.1 transitively). Edited `project.pbxproj` directly (added `XCRemoteSwiftPackageReference`, `XCSwiftPackageProductDependency`, target `packageProductDependencies`, project `packageReferences`, and a `PBXBuildFile` linking the `StableDiffusion` product into the Frameworks build phase).
- New module `Artlify/DiffusionKit/`:
  - `DiffusionPipeline.swift` — Swift `actor` wrapping `StableDiffusionPipeline`. Loads a model bundle from `~/Library/Application Support/Artlify/Models/sd-turbo/`, runs single-shot img2img passes with `guidanceScale = 0` (SD Turbo is trained without classifier-free guidance — using non-zero CFG produces garbage), `dpmSolverMultistepScheduler`, `reduceMemory: true`, `disableSafety: true`. Returns the `CGImage` plus a `DiffusionRunStats` value with wall-clock timing.
  - `CVPixelBuffer+CGImage.swift` — Reusable `CIContext` (Metal-backed when possible) for camera frame → square 512×512 `CGImage` with center-crop.
- New `AppShell/DiffusionBenchmark.swift` — `@MainActor @Observable` controller exposing `load`, `run(using:)`, prompt/steps/strength state, and a `revealModelFolder()` that opens Finder at the expected path.
- `ContentView` gained a benchmark panel: result thumbnail (220×220), prompt text field, steps stepper (1–8), strength slider (0.1–0.95), Load/Stylize buttons, and a status line showing `img2img: <ms> (<FPS>) · <steps> steps`.
- `CameraSession` now also caches `latestPixelBuffer` so the benchmark can grab the most recent frame without disturbing the render path.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
Per `ProjectDocument.md` §13 #1, the entire v1 design hinges on SD Turbo achieving ≥3 FPS on the M5 base. The cheapest way to validate that is a button that runs one img2img pass on a real camera frame and prints the wall-clock time. Building the live loop (M3) before measuring this would be premature.

The pipeline is a Swift `actor` so a second `generate` call cannot interleave with one in flight — exactly the shape M3 will need when the renderer is constantly asking "is the next AI frame ready?".

**Impact:**
- Adds two SwiftPM dependencies to the build graph; compile time noticeably longer (still <30 s clean).
- App still runs without any model installed — the UI shows "Reveal model folder" instead of "Load model" and prints the expected path. This is intentional: getting the model files is a separate, manual step (see follow-up below) and the team can keep iterating on UI/Vision work without it.
- Locked the design choice: **SD Turbo only** for v1 (CFG=0, dpm-solver, 2 steps default). SDXL Turbo and ControlNet remain in `Roadmap.md` "Post-v1 / Conditional".

**Follow-up:**
To actually run the benchmark, the team needs to convert SD Turbo to CoreML once and drop the resulting `.mlmodelc` bundle (plus `vocab.json`, `merges.txt`) into `~/Library/Application Support/Artlify/Models/sd-turbo/`. The conversion is a one-time Python step from `apple/ml-stable-diffusion`:

```bash
# in a Python venv with apple/ml-stable-diffusion installed
python -m python_coreml_stable_diffusion.torch2coreml \
  --convert-unet --convert-text-encoder \
  --convert-vae-decoder --convert-vae-encoder \
  --model-version stabilityai/sd-turbo \
  --bundle-resources-for-swift-cli \
  --attention-implementation SPLIT_EINSUM \
  -o ./out
# then: cp -R out/Resources/* ~/Library/Application\ Support/Artlify/Models/sd-turbo/
```

Once installed, click **Load model** → wait for "model loaded" → click **Stylize current frame** and read the FPS. If it lands in the 3–6 FPS band predicted in `ProjectDocument.md` §3, M1 is verified and we proceed to M2 (Vision integration). If it lands below 2 FPS, fall back to 384×384 or an LCM-distilled variant before any further UX work, as `Roadmap.md` already calls out.

---

## 2026-05-11 — M0 shipped: camera passthrough builds and runs

**Decision / change:**
Implemented and built the M0 skeleton end-to-end. New code:

- `Artlify/CaptureKit/CameraCapture.swift` — nonisolated `CameraCapture` class that wraps `AVCaptureSession`, prefers `.continuityCamera` device type, and exposes frames via `AsyncStream<CVPixelBuffer>` with `.bufferingNewest(1)` (latest-frame-wins, no queue growth).
- `Artlify/RenderKit/Passthrough.metal` — full-screen-triangle vertex + texture-sample fragment shader.
- `Artlify/RenderKit/CameraMetalRenderer.swift` — `MTKViewDelegate`, owns a `CVMetalTextureCache`, blits the latest camera frame to the drawable, logs render FPS once per second.
- `Artlify/RenderKit/CameraMetalView.swift` — `NSViewRepresentable` wiring the renderer into SwiftUI.
- `Artlify/AppShell/CameraSession.swift` — `@MainActor @Observable` glue that runs the pump task and tracks first-frame latency.
- Rewrote `ContentView.swift` to display the live feed with a small status HUD.
- Added `Artlify/Artlify.entitlements` (sandbox + `com.apple.security.device.camera` + network client for future model downloads) and wired it via `CODE_SIGN_ENTITLEMENTS` in both build configurations.
- Added `INFOPLIST_KEY_NSCameraUsageDescription` to both build configurations.

`xcodebuild -scheme Artlify -configuration Debug build` is green with **zero warnings**.

**Reason:**
M0 is the cheapest possible end-to-end slice: camera in → screen out. Getting it green before touching ML eliminates an entire class of integration risk (entitlements, sandbox, Continuity-Camera device selection, Metal pipeline, MainActor-default-isolation friction) while the codebase is still tiny.

**Impact:**
- Validated the project structure (one Xcode target, `PBXFileSystemSynchronizedRootGroup` auto-picks files added under `Artlify/`, no pbxproj edits needed for new source files — only for build settings).
- Confirmed the Swift-6-clean concurrency story under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: anything touched from background queues (delegate callbacks, AVFoundation state) lives on a class declared `nonisolated final class`, with the conformance extension also marked `nonisolated`. Recorded for future modules.
- The `RenderKit` Metal pipeline already uses a single-texture slot, which is the exact shape the temporal blender will extend in M3 (it just needs `aiPrev`/`aiNext` slots and a different fragment shader).
- `FrameRouter` as a separate actor (planned in §4 of `ProjectDocument.md`) turned out to be redundant — `AsyncStream.bufferingNewest(1)` already enforces "latest-frame-wins" at the language level. Removed from the roadmap rather than building dead code.

**Follow-up:**
- Run the app with an iPhone connected and **measure end-to-end Continuity Camera latency** (target <150 ms). This is the M0 verification step from `ProjectDocument.md` §13 assumption #2.
- On first launch the system will prompt for camera access; verify the consent dialog text reads correctly.
- Begin M1: pull `apple/ml-stable-diffusion` Swift package, convert/download SD Turbo CoreML, run a single `img2img` call on a captured frame, log latency / RAM / FPS.

---

## 2026-05-11 — Required Metal toolchain on Xcode 26

**Decision / change:**
First build failed with `cannot execute tool 'metal' due to missing Metal Toolchain`. Fixed by running `xcodebuild -downloadComponent MetalToolchain`.

**Reason:**
Xcode 26 ships the Metal toolchain as a downloadable component rather than bundling it. Any developer cloning the repo on a fresh machine will hit the same error.

**Impact:**
Documented here so the next person doesn't lose time. Worth adding to a future `README.md` setup section.

**Follow-up:**
Add a one-line setup note to the README when one is created.

---

## 2026-05-11 — Initial technical planning baseline established

**Decision / change:**
Rewrote `ProjectDocument.md` from a high-level vision into a constraint-driven technical plan. Created `Roadmap.md` and this `Journal.md`. Locked v1 scope to: Continuity Camera input → Vision (segmentation + pose) → SD Turbo img2img via CoreML → Metal renderer with temporal blending. Explicitly deferred ControlNet, StreamDiffusion, multi-style mixing, audio, projection mapping, custom iOS app, and any training/fine-tuning to post-v1.

**Reason:**
The original document listed many candidate technologies (ComfyUI, ControlNet, Flux, StreamDiffusion, neural style transfer, fluid sims, etc.) without committing. With a small team, no ML training capacity, and a base-chip M5 as the target device, we cannot afford to keep options open — every undecided technology is a tax on iteration speed. We picked the smallest credible stack that still produces the intended experience.

**Impact:**
- One external dependency (`apple/ml-stable-diffusion`); everything else is Apple frameworks.
- Realistic FPS target reframed: AI layer 3–6 FPS, perceived 60 FPS via Metal blending. This is the central design assumption.
- Diffusion is now an async producer that the renderer is allowed to ignore when stale — no more "real-time AI" framing that would set us up to fail.
- Models ship out-of-band (downloaded on first launch, SHA-pinned), keeping the binary small and licensing flexible.

**Follow-up:**
- M0: stand up an Xcode SwiftPM project skeleton with the 6 modules from §5 of `ProjectDocument.md`.
- M0: measure end-to-end Continuity Camera latency on the actual M5 — if >200 ms, revisit.
- M1: benchmark SD Turbo on M5 base at 512×512 / 2 steps / fp16. If <2 FPS, fall back to 384×384 or an LCM-distilled variant before any UX work.
- Confirm minimum macOS version against `ml-stable-diffusion` Swift package requirements.

---

## 2026-05-11 — Rejected: cloud inference, custom streaming protocol, training pipelines

**Decision / change:**
Explicitly rule out (a) any cloud diffusion backend (Replicate, Fal, self-hosted), (b) any custom iPhone→Mac streaming protocol (NDI, RTSP, WebRTC, custom UDP), and (c) any model training, fine-tuning, or LoRA work for v1.

**Reason:**
- Cloud: adds 300–1500 ms RTT, recurring cost, and breaks the "offline, no API keys" goal. The whole appeal of on-device Apple Silicon evaporates if we phone home for every frame.
- Custom streaming: requires a companion iOS app, networking code, codec choices, NAT traversal. Continuity Camera gives us the same result for zero engineering cost.
- Training: we have no labeled data, no GPU budget, and no ML engineer. Pre-trained SD Turbo is good enough for a first installation-grade demo.

**Impact:**
Scope shrinks dramatically. Risk shrinks. We can begin coding immediately with no procurement, no infrastructure, no dataset collection.

**Follow-up:**
Revisit each of these only if v1 ships and a concrete user need demands it. Document the trigger condition in `Roadmap.md` under "Post-v1 / Conditional".
