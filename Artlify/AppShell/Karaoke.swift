//
//  Karaoke.swift
//  Artlify / AppShell — `particles` branch
//
//  Stage 1 of the karaoke-style synced-lyric feature:
//
//    - A pure-Swift LRC parser (the de-facto karaoke timestamp format
//      used by every synced-lyric provider: each line begins with one
//      or more `[mm:ss.xx]` timestamps).
//    - `KaraokeStore`: passive @Observable that holds a parsed track
//      and a `currentTime`; computes current line index + intra-line
//      progress on demand.
//    - `KaraokeOverlay`: SwiftUI Canvas. Three lines on screen at any
//      moment — previous (faint, smaller), current (bold, scrubbing
//      per-character highlight), next (faint, smaller). The current
//      line's baseline is *waveform-distorted*: each glyph gets a
//      sinusoidal y-offset whose amplitude scales with audio level
//      and whose phase varies per character + over time, so the line
//      ripples like a vibrating string when the room gets loud.
//
//  Stages still pending (deliberately deferred):
//    - MusicKit search + ApplicationMusicPlayer playback
//    - LRCLIB network fetch
//    - ScreenCaptureKit system-audio tap feeding AudioReactor
//
//  Until those land, this file ships a hardcoded sample LRC and the
//  driving "currentTime" comes from a HUD slider in ContentView. The
//  visual contract for stage 2 stays exactly the same — only the
//  source of `track` and `currentTime` changes.
//

import SwiftUI
import Combine

// MARK: - Model

/// One timestamped line of lyrics. `time` is seconds-from-start.
struct LyricsLine: Hashable {
    let time: TimeInterval
    let text: String
}

/// A parsed song's worth of lines, plus optional metadata. Lines are
/// guaranteed sorted by `time` ascending after `LRCParser.parse`.
struct LyricsTrack: Hashable {
    let title: String?
    let artist: String?
    let lines: [LyricsLine]

    var duration: TimeInterval {
        // Estimate: last timestamp + 4 s tail. Stage 2 will replace
        // this with the player's known track duration.
        (lines.last?.time ?? 0) + 4
    }
}

// MARK: - LRC parser

/// LRC format primer:
///
///     [ti:Title]              ← metadata tag, ignored except ti/ar
///     [ar:Artist]
///     [al:Album]
///     [00:12.34]first line    ← single-stamp synced line
///     [00:14.10][01:42.00]second line  ← multi-stamp (chorus repeats)
///
/// We parse leniently — any line with at least one timestamp prefix
/// becomes one or more `LyricsLine` entries; everything else is
/// either a known metadata tag or ignored.
enum LRCParser {
    /// Matches `[mm:ss]` and `[mm:ss.xx]` / `[mm:ss:xx]` timestamp
    /// forms. Fractional part is 1–3 digits to accept both `.xx` and
    /// `.xxx` (Musixmatch / LRCLIB use both).
    private static let stampRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        )
    }()

    /// Matches metadata tags we care about, e.g. `[ti:Hello]`.
    private static let metaRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^\[(ti|ar|al):(.*)\]$"#)
    }()

    static func parse(_ raw: String) -> LyricsTrack {
        var title: String? = nil
        var artist: String? = nil
        var out: [LyricsLine] = []

        for rawLine in raw.split(separator: "\n",
                                 omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            // Metadata?
            if let m = metaRegex.firstMatch(in: line, range: full) {
                let key = ns.substring(with: m.range(at: 1))
                let val = ns.substring(with: m.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)
                if key == "ti" { title = val }
                else if key == "ar" { artist = val }
                continue
            }

            // Synced line?
            let stamps = stampRegex.matches(in: line, range: full)
            guard !stamps.isEmpty else { continue }

            // The lyric text is whatever's left after stripping every
            // timestamp from the front of the line.
            let text = stampRegex.stringByReplacingMatches(
                in: line, range: full, withTemplate: ""
            ).trimmingCharacters(in: .whitespaces)

            for stamp in stamps {
                let mm = Int(ns.substring(with: stamp.range(at: 1))) ?? 0
                let ss = Int(ns.substring(with: stamp.range(at: 2))) ?? 0
                var frac: TimeInterval = 0
                if stamp.range(at: 3).location != NSNotFound {
                    let fs = ns.substring(with: stamp.range(at: 3))
                    // `12` → 0.12, `123` → 0.123 — same rule both lengths.
                    frac = Double("0.\(fs)") ?? 0
                }
                let t = TimeInterval(mm * 60 + ss) + frac
                out.append(LyricsLine(time: t, text: text))
            }
        }

        out.sort { $0.time < $1.time }
        return LyricsTrack(title: title, artist: artist, lines: out)
    }

    /// Placeholder track shipped with stage 1. Replaced in stage 2 by
    /// LRCLIB fetch keyed off the MusicKit selection. The lines are
    /// thematic to Artlify so the demo reads as intentional, not lorem.
    static let sample: String = """
    [ti:Artlify Demo Loop]
    [ar:Placeholder]
    [00:00.00]stand still before the lens
    [00:03.20]watch the silhouette respond
    [00:06.80]every sound becomes a wave
    [00:10.40]every motion leaves a trail
    [00:14.00]raise your hand
    [00:15.40]paint the air
    [00:18.00]breathe in
    [00:20.00]breathe out
    [00:22.50]the room is listening
    [00:26.00]you are the canvas
    [00:30.00]
    """
}

// MARK: - Store

/// Holds the currently-loaded track and the playback clock. Passive:
/// `currentTime` is driven from outside (HUD slider in stage 1, the
/// MusicKit player's `playbackTime` in stage 2). All view-relevant
/// derived state lives here so the overlay stays pure.
@Observable
final class KaraokeStore {
    var track: LyricsTrack? = nil
    var currentTime: TimeInterval = 0

    /// Index of the line whose timestamp is the largest ≤ currentTime,
    /// or nil before the first line starts.
    var currentLineIndex: Int? {
        guard let lines = track?.lines, !lines.isEmpty else { return nil }
        // Lyric line counts top out in the hundreds even for long
        // songs, so linear scan is fine; avoids the off-by-one
        // misery of a hand-rolled binary search.
        var idx: Int? = nil
        for i in lines.indices {
            if lines[i].time <= currentTime { idx = i } else { break }
        }
        return idx
    }

    /// 0..1 progress through the current line (used for the per-char
    /// karaoke highlight wipe). Returns 0 when no line is active.
    var lineProgress: Double {
        guard let lines = track?.lines,
              let i = currentLineIndex else { return 0 }
        let start = lines[i].time
        // End = next line's start, or +4 s for the last line.
        let end = (i + 1 < lines.count) ? lines[i + 1].time : (start + 4)
        let span = max(0.01, end - start)
        return max(0, min(1, (currentTime - start) / span))
    }

    func loadSample() {
        track = LRCParser.parse(LRCParser.sample)
        currentTime = 0
    }

    func clear() {
        track = nil
        currentTime = 0
    }
}

// MARK: - View

/// Cinematic karaoke visualiser. Designed to feel *fused into the
/// world* rather than text-on-top:
///
///   1. **World fragments** — pieces of the current line scattered as
///      huge dim ghost-glyphs across the whole canvas, drifting and
///      breathing with the bass. They act as parallax depth.
///   2. **Prev / next satellites** — the surrounding lyric lines float
///      off-axis (upper-left and lower-right) with their own gentle
///      parallax driven by audio pan.
///   3. **Current line** — RGB-split (chromatic aberration) bold text
///      with per-character chaos: waveform y-offset, transient-driven
///      explosive x-jitter, micro-rotation, and a karaoke highlight
///      wipe that controls saturation rather than just brightness.
///   4. **Transient flash** — a horizontal scanline slice tears across
///      the current line on each audio attack, plus a wide soft
///      radial bloom behind the line.
///   5. **Camera shake** — the whole overlay subtly translates with
///      transient impulses so beats land in the body, not the head.
///
/// Audio coupling stays loose: plain `Double`s in, no AudioReactor
/// type leaks here, so stage 2 (ScreenCaptureKit) can swap the source
/// without touching this file.
struct KaraokeOverlay: View {
    let store: KaraokeStore
    /// When false, layer 3 (the loud chromatic + chaos current-line
    /// text) is suppressed entirely — layers 1 (world fragments),
    /// 2 (prev/next satellites), 4a (slice tear) and 4b (bloom) keep
    /// running. Useful for installations where the giant centred
    /// lyric overpowers the visual.
    var showCurrentLine: Bool = true
    /// Layer 1: giant dim ghost glyph fragments scattered across the
    /// canvas. Toggle off for a cleaner, less-busy lyric.
    var showWorldFragments: Bool = true
    /// Layer 2: prev / next lyric lines drifting off-axis.
    var showSatellites: Bool = true
    /// Layer 4a: VHS-style horizontal slice tear that flashes through
    /// the focal line on transients.
    var showSliceTear: Bool = true
    /// Layer 4b: wide soft radial bloom behind the focal line.
    var showBloom: Bool = true
    /// Global camera shake on the overlay (translates *all* layers).
    /// Disable for clean recordings where the shake reads as
    /// jpeg-noise rather than emphasis.
    var showCamShake: Bool = true
    /// Master "chaos" multiplier. Scales the per-glyph explosion,
    /// jitter, micro-rotation, and the camera-shake envelope. 1 =
    /// shipping default, 0 = perfectly stationary glyphs, 2 = louder.
    var intensity: Double = 1.0
    /// Extra multiplier on the chromatic RGB-split distance. 1 =
    /// shipped default; bump up for the obvious VHS look or down to
    /// near 0 for a clean monochrome render.
    var chromaticSplit: Double = 1.0
    /// Base font size for the focal current-line text. Audio level
    /// still adds up to ~8 pt on top, same as before.
    var fontSize: Double = 36
    /// Vertical position of the focal line as a fraction of the
    /// view height (0 = top, 1 = bottom). 0.78 is the shipped
    /// default — below the body silhouette, above the bottom HUD.
    var verticalPosition: Double = 0.78
    /// 0..1 normalised broadband level — drives base amplitudes.
    var audioLevel: Double = 0
    /// 0..1 low-band energy — drives the bass "breathing" of the
    /// background fragments and the bloom radius.
    var audioLow: Double = 0
    /// 0..1 mid-band energy — second waveform harmonic + ghost drift.
    var audioMid: Double = 0
    /// 0..1 high-band energy — sharpens the chromatic split.
    var audioHigh: Double = 0
    /// 0..1 instantaneous attack — drives shake, glyph explosion and
    /// the horizontal slice tear. Fades fast in the reactor.
    var audioTransient: Double = 0

    /// Internal repaint clock. Canvas needs a ticking dependency to
    /// re-evaluate every per-frame derived value.
    private let timer = Timer.publish(every: 1.0 / 60.0,
                                      on: .main, in: .common).autoconnect()
    @State private var nowT: TimeInterval = 0

    /// Persistent low-pass of transient so the camera-shake decays
    /// smoothly rather than snapping back to zero between hits.
    @State private var shake: Double = 0

    var body: some View {
        Canvas { ctx, size in
            guard store.track != nil,
                  let i = store.currentLineIndex else { return }
            let lines = store.track!.lines
            let curr = lines[i].text
            let prev = (i > 0) ? lines[i - 1].text : ""
            let next = (i + 1 < lines.count) ? lines[i + 1].text : ""

            // ---- Global camera shake (translates everything below).
            let shakeAmt = showCamShake ? shake * intensity : 0
            let shakeMag = CGFloat(2 + 26 * shakeAmt)
            let shakeX = CGFloat(sin(nowT * 47.0)) * shakeMag * CGFloat(shakeAmt)
            let shakeY = CGFloat(cos(nowT * 53.0)) * shakeMag * 0.6
                        * CGFloat(shakeAmt)
            var ctx = ctx
            ctx.translateBy(x: shakeX, y: shakeY)

            // Position the karaoke focal point low so it doesn't fight
            // the body silhouette in the centre.
            let centerY = size.height * CGFloat(min(max(verticalPosition, 0), 1))

            // ---- (1) World ghost fragments behind everything.
            if showWorldFragments {
                drawWorldFragments(of: curr, ctx: ctx, size: size,
                                   lineIndex: i, centerY: centerY)
            }

            // ---- (4b) Radial bloom behind the current line.
            if showBloom {
                drawBloom(at: CGPoint(x: size.width / 2, y: centerY),
                          ctx: ctx, size: size)
            }

            // ---- (2) Prev / next satellites (parallax drift).
            if showSatellites {
                if !prev.isEmpty {
                    drawSatellite(prev, ctx: ctx, size: size,
                                  anchor: CGPoint(x: size.width * 0.18,
                                                  y: centerY - 110),
                                  fontSize: 16, opacity: 0.22,
                                  drift: -1)
                }
                if !next.isEmpty {
                    drawSatellite(next, ctx: ctx, size: size,
                                  anchor: CGPoint(x: size.width * 0.82,
                                                  y: centerY + 92),
                                  fontSize: 16, opacity: 0.22,
                                  drift: 1)
                }
            }

            // ---- (4a) Transient horizontal slice tear (drawn under
            //      the current line so the glyphs sit on top of it).
            if showSliceTear {
                drawSliceTear(ctx: ctx, size: size, centerY: centerY)
            }

            // ---- (3) Current line — chromatic + chaos + highlight.
            if showCurrentLine, !curr.isEmpty {
                drawCurrentLine(curr, ctx: ctx, size: size,
                                centerY: centerY)
            }
        }
        .allowsHitTesting(false)
        .drawingGroup()
        .onReceive(timer) { _ in
            nowT = CFAbsoluteTimeGetCurrent()
            // Smooth the camera-shake envelope. Attack = snap to the
            // peak of the new transient; release = exponential decay
            // (~250 ms half-life at 60 Hz).
            shake = max(shake * 0.90, audioTransient)
        }
    }

    // MARK: -- Layer 1: world ghost fragments

    /// Background "world" layer. Splits the current lyric line into
    /// word fragments and scatters them across the canvas at huge,
    /// dim sizes. Each fragment has a deterministic-random position
    /// (seeded by line index + fragment slot) and drifts with bass.
    private func drawWorldFragments(of text: String,
                                    ctx: GraphicsContext,
                                    size: CGSize,
                                    lineIndex: Int,
                                    centerY: CGFloat) {
        // Break the line into salient chunks. If the line is short
        // (≤ 2 words) we duplicate it to fill the field anyway.
        var chunks: [String] = text
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        if chunks.count < 3 { chunks += chunks; chunks += chunks }
        if chunks.isEmpty { return }

        // Stable per-line RNG so fragments don't flicker each frame.
        var rng = SeededRNG(seed: UInt64(truncatingIfNeeded: lineIndex) &* 0x9E3779B97F4A7C15 as UInt64)

        let count = 7
        let breathe = CGFloat(0.85 + 0.30 * audioLow)
        let drift = CGFloat(nowT) * CGFloat(0.18 + 0.6 * audioMid)

        var sub = ctx
        sub.blendMode = .plusLighter

        for slot in 0..<count {
            let frag = chunks[slot % chunks.count]
            // Position in unit space, then nudge by slow drift.
            let ux = rng.unit()
            let uy = rng.unit()
            let driftPhase = Double(slot) * 1.7 + drift
            let dx = CGFloat(sin(driftPhase)) * 24
            let dy = CGFloat(cos(driftPhase * 1.3)) * 18
            let p = CGPoint(x: ux * size.width + dx,
                            y: uy * size.height + dy)

            let fontSize = (40 + rng.unit() * 110) * breathe
            let rot = (rng.unit() - 0.5) * 0.22
            let alpha = 0.06 + rng.unit() * 0.07 + 0.08 * audioLow

            // Single dim render (no per-char), but RGB-split lightly
            // so even the ghosts carry the chromatic theme.
            let split = CGFloat(1.5 + 6 * audioHigh)
            let font = Font.custom("starjhol", size: fontSize)

            var layer = sub
            layer.translateBy(x: p.x, y: p.y)
            layer.rotate(by: .radians(rot))

            for (off, tint) in [
                (-split, Color(red: 1.0, green: 0.18, blue: 0.18)),
                ( 0.0,   Color(red: 0.20, green: 1.00, blue: 0.55)),
                ( split, Color(red: 0.25, green: 0.55, blue: 1.00))
            ] {
                let t = Text(frag)
                    .font(font)
                    .foregroundColor(tint.opacity(alpha))
                layer.draw(t, at: CGPoint(x: off, y: 0),
                           anchor: .center)
            }
        }
    }

    // MARK: -- Layer 2: prev / next satellites

    /// Faint floating context lines off-axis. `drift` is -1 for prev
    /// (pulled up-left by pan) and +1 for next (pulled down-right).
    private func drawSatellite(_ text: String,
                               ctx: GraphicsContext,
                               size: CGSize,
                               anchor: CGPoint,
                               fontSize: CGFloat,
                               opacity: Double,
                               drift: CGFloat) {
        let breathe = CGFloat(1.0 + 0.10 * audioMid)
        let off = CGFloat(sin(nowT * 1.7 + Double(drift))) * 6
        let p = CGPoint(x: anchor.x + drift * off,
                        y: anchor.y + off * 0.3)
      let font = Font.custom("starjhol", size: fontSize * breathe)

        let split = CGFloat(1 + 3 * audioHigh)
        let alpha = opacity + 0.12 * audioLevel
        var sub = ctx
        sub.blendMode = .plusLighter

        for (dx, tint) in [
            (-split, Color(red: 1.0, green: 0.20, blue: 0.30)),
            ( 0.0,   Color.white),
            ( split, Color(red: 0.25, green: 0.60, blue: 1.00))
        ] {
            let t = Text(text)
                .font(font)
                .foregroundColor(tint.opacity(alpha))
            sub.draw(t, at: CGPoint(x: p.x + dx, y: p.y),
                     anchor: .center)
        }
    }

    // MARK: -- Layer 3: current line (chromatic + chaos)

    /// Draws the active lyric line character-by-character with three
    /// RGB-shifted passes for chromatic aberration plus per-glyph
    /// chaos (waveform, transient explosion, micro-rotation).
    private func drawCurrentLine(_ text: String,
                                 ctx: GraphicsContext,
                                 size: CGSize,
                                 centerY: CGFloat) {
        let fontSizeBase: CGFloat = CGFloat(fontSize) + CGFloat(8 * audioLevel)
        let font = Font.custom("starjhol", size: fontSizeBase)
        let chars = Array(text)

        // Per-glyph measure.
        let measureBox = CGSize(width: 200, height: fontSizeBase * 2)
        let widths: [CGFloat] = chars.map { ch in
            ctx.resolve(Text(String(ch)).font(font))
                .measure(in: measureBox).width
        }
        let totalW = widths.reduce(0, +)
        let startX = (size.width - totalW) / 2

        // Highlight wipe boundary in pixels.
        let progress = store.lineProgress
        let highlightX = startX + totalW * CGFloat(progress)

        // Chromatic split scales with the broadband level and gets
        // a sharp kick on transients — the line literally tears open
        // on every beat. `chromaticSplit` is a user-tunable extra
        // multiplier on top of the audio-driven base.
        let splitBase = CGFloat(2 + 14 * audioLevel + 28 * audioTransient)
                      * CGFloat(max(0, chromaticSplit))
        let splitX = splitBase
        let splitY = splitBase * 0.35

        // Waveform amplitude (two summed harmonics, audio-weighted).
        let liveAmp = CGFloat(2 + 18 * audioLevel + 12 * audioHigh)
        let baseAmp = CGFloat(3 + 10 * audioMid)
        let phase1 = nowT * 7.0
        let phase2 = nowT * 11.0 + 1.7

        var x = startX
        for (idx, ch) in chars.enumerated() {
            let w = widths[idx]
            let cx = x + w / 2

            // Per-character pseudo-random scalar (-1..1), stable across
            // frames (depends only on idx).
            let h = pseudoNoise(idx)

            // Waveform y-offset.
            let yWave = CGFloat(sin(Double(idx) * 0.55 + phase1)) * liveAmp
                      + CGFloat(sin(Double(idx) * 0.21 + phase2)) * baseAmp

            // Transient explosion: glyphs jolt outward from the line
            // centre on attacks. Sign comes from per-char noise so
            // they scatter rather than all move the same way. The
            // `intensity` knob scales the whole chaos package.
            let chaos = CGFloat(max(0, intensity))
            let explode = CGFloat(audioTransient) * 18 * CGFloat(h) * chaos
            let yJolt = CGFloat(audioTransient) * 10 * CGFloat(pseudoNoise(idx + 17)) * chaos

            // Micro-rotation, also seeded by the per-char noise so
            // adjacent glyphs tilt opposite ways.
            let rot = CGFloat(h) * (0.04 + 0.18 * CGFloat(audioTransient)) * chaos

            // Highlight: lit chars get colour, unlit chars stay grey.
            // We treat the wipe as a sub-pixel boundary so motion is
            // smooth rather than snapping per character.
            let lit = cx <= highlightX

            // Per-character draw context (rotated around the glyph).
            var sub = ctx
            sub.blendMode = .plusLighter
            sub.translateBy(x: cx + explode, y: centerY + yWave + yJolt)
            sub.rotate(by: .radians(Double(rot)))

            // Three colour passes for chromatic aberration. When lit
            // we use saturated R/G/B that recombine to bright white in
            // the centre. When unlit we use dim greys so the wipe
            // reads as "saturation lighting up", not just brightness.
            let passes: [(CGFloat, CGFloat, Color)]
            if lit {
                let r = Color(red: 1.00, green: 0.18, blue: 0.30)
                let g = Color(red: 0.45, green: 1.00, blue: 0.60)
                let b = Color(red: 0.25, green: 0.55, blue: 1.00)
                passes = [
                    (-splitX, -splitY, r),
                    (0,        0,      g),
                    ( splitX,  splitY, b)
                ]
            } else {
                let dim  = Color.white.opacity(0.22)
                let edge = Color.white.opacity(0.10)
                passes = [
                    (-splitX * 0.5, -splitY * 0.5, edge),
                    (0,              0,            dim),
                    ( splitX * 0.5,  splitY * 0.5, edge)
                ]
            }

            for (dx, dy, tint) in passes {
                let t = Text(String(ch)).font(font).foregroundColor(tint)
                sub.draw(t, at: CGPoint(x: dx, y: dy), anchor: .center)
            }

            x += w
        }

        // Soft inner glow underline that flickers with transients —
        // gives the eye a horizon line to anchor the chaos to.
        let underlineY = centerY + fontSizeBase * 0.65
        let alpha = 0.25 + 0.55 * audioLevel + 0.40 * audioTransient
        let rect = CGRect(x: startX - 16, y: underlineY - 1,
                          width: totalW + 32, height: 2)
        ctx.fill(Path(rect),
                 with: .color(.white.opacity(min(1.0, alpha))))
    }

    // MARK: -- Layer 4a: horizontal slice tear

    /// On a transient, paint a thin bright horizontal band across the
    /// current-line region. Looks like a VHS scan-tear; sells the
    /// "beat physically distorts the air" idea.a
    private func drawSliceTear(ctx: GraphicsContext,
                               size: CGSize,
                               centerY: CGFloat) {
        guard audioTransient > 0.12 else { return }
        let offset = CGFloat(pseudoNoise(Int(nowT * 13))) * 22
        let h: CGFloat = 1 + CGFloat(audioTransient) * 4
        let y = centerY + offset
        let band = CGRect(x: 0, y: y, width: size.width, height: h)
        let alpha = 0.18 + 0.55 * audioTransient
        var sub = ctx
        sub.blendMode = .plusLighter
        sub.fill(Path(band), with: .color(.white.opacity(alpha)))
    }

    // MARK: -- Layer 4b: radial bloom behind the line

    /// Wide, soft, low-alpha radial glow behind the current line so
    /// the rest of the scene seems to *light up from* the lyrics
    /// rather than have text pasted in front of it.
    private func drawBloom(at p: CGPoint,
                           ctx: GraphicsContext,
                           size: CGSize) {
        let radius = 140 + CGFloat(220 * audioLevel + 280 * audioLow)
        let alpha = 0.10 + 0.30 * audioLevel + 0.20 * audioTransient
        let rect = CGRect(x: p.x - radius, y: p.y - radius * 0.55,
                          width: radius * 2, height: radius * 1.1)
        let grad = Gradient(stops: [
            .init(color: Color.white.opacity(alpha),     location: 0.0),
            .init(color: Color.white.opacity(alpha * 0.35), location: 0.35),
            .init(color: Color.white.opacity(0.0),       location: 1.0)
        ])
        var sub = ctx
        sub.blendMode = .plusLighter
        sub.fill(Ellipse().path(in: rect),
                 with: .radialGradient(grad,
                                       center: p,
                                       startRadius: 0,
                                       endRadius: radius))
    }

    // MARK: -- Helpers

    /// Fast deterministic per-index noise in [-1, 1]. Used for stable
    /// per-glyph randomness (rotation, explosion direction).
    private func pseudoNoise(_ i: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i) &* 0x9E3779B97F4A7C15 as UInt64
        x ^= x >> 30
        x &*= 0xBF58476D1CE4E5B9
        x ^= x >> 27
        let n = Double(x & 0xFFFF) / Double(0xFFFF)  // 0..1
        return n * 2 - 1                              // -1..1
    }
}

// MARK: - Tiny seeded RNG (used by world fragments)

/// 64-bit LCG. We don't need anything cryptographic — just stable
/// pseudo-random offsets per line index so the background ghosts
/// don't flicker between frames.
private struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) {
        // Ensure non-zero state.
        self.state = seed == 0 ? 0xCAFEF00DD15EA5E5 : seed
    }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    /// Uniform double in [0, 1).
    mutating func unit() -> CGFloat {
        CGFloat(Double(next() >> 11) / Double(1 << 53))
    }
}

// MARK: - Phase 2 (first slice): head-tethered lyric blob
//
// Toggle-able overlay that pins the current karaoke line to a wobbly,
// audio-reactive blob floating beside the person's head, connected to
// the head joint by a sagging "string". Treats the lyric like a
// thought-bubble / annotation that follows the subject around the
// frame instead of sitting in a fixed bar at the bottom.
//
// Phase-2 design intent: this is the first piece of "lyric becomes
// part of the world" beyond the chromatic visualiser. The blob is
// physically attached to the person via the string, so a moving body
// drags the karaoke around with it. Stage 2-network (MusicKit +
// LRCLIB + ScreenCaptureKit) is still pending and orthogonal to this
// — it'll just change where `store.track` comes from.

/// Renders the current karaoke line inside an organic, audio-wobbly
/// blob anchored above-and-right of the person's head, with a curving
/// string from the head joint to the blob. Stays invisible if no
/// person is detected (no nose joint) or no track is loaded.
struct HeadLyricBlob: View {
    let store: KaraokeStore
    /// Latest Vision frame — we read the `nose` joint to find the head.
    var frame: VisionFrame?
    /// Base font size of the lyric inside the blob. Audio level adds
    /// a couple of points on top.
    var fontSize: Double = 15
    /// Multiplier on the head-to-blob anchor offset (both axes).
    /// 1 = shipped default (~170 px horizontal, ~180 px above the
    /// head), 0.5 hugs the head, 1.5 floats it further away. Clamped
    /// at the view edges by the existing pad logic.
    var offsetRadius: Double = 1.0
    var audioLevel: Double = 0
    var audioLow: Double = 0
    var audioMid: Double = 0
    var audioHigh: Double = 0
    var audioTransient: Double = 0

    private let timer = Timer.publish(every: 1.0 / 60.0,
                                      on: .main, in: .common).autoconnect()
    @State private var nowT: TimeInterval = 0

    var body: some View {
        Canvas { ctx, size in
            guard let frame = frame,
                  let track = store.track,
                  let i = store.currentLineIndex
            else { return }

            // Find the head joint. Vision exposes the nose as the
            // top-of-head anchor; if confidence is low we bail rather
            // than dragging the blob to (0,0).
            guard let nose = frame.joints.first(where: { $0.id == "nose" }),
                  nose.confidence >= 0.3
            else { return }

            // Replicate the renderer's aspect-fill projection so the
            // blob sticks to the head as the camera frame is letter-
            // /pillar-boxed inside the view.
            let srcAspect = CGFloat(frame.sourceWidth)
                          / CGFloat(frame.sourceHeight)
            let viewAspect = size.width / size.height
            let drawW: CGFloat
            let drawH: CGFloat
            if srcAspect > viewAspect {
                drawH = size.height
                drawW = drawH * srcAspect
            } else {
                drawW = size.width
                drawH = drawW / srcAspect
            }
            let offsetX = (size.width - drawW) / 2.0
            let offsetY = (size.height - drawH) / 2.0
            let head = CGPoint(
                x: offsetX + nose.point.x * drawW,
                y: offsetY + (1.0 - nose.point.y) * drawH
            )

            let lineText = track.lines[i].text

            // Blob anchor: above and slightly to one side of the head.
            // Side is picked by which half of the view the head sits
            // in, so the blob doesn't get pushed off-screen when the
            // person stands to one side of the frame.
            let onLeft = head.x > size.width * 0.5
            let sideSign: CGFloat = onLeft ? -1 : 1
            let radius = CGFloat(max(0, offsetRadius))
            let baseOffX: CGFloat = 170 * sideSign * radius
            let baseOffY: CGFloat = -180 * radius

            // Slow float + audio breathing.
            let floatX = CGFloat(sin(nowT * 0.9)) * 10
            let floatY = CGFloat(cos(nowT * 1.3)) * 8
                       + CGFloat(audioLow) * -14
            var anchor = CGPoint(x: head.x + baseOffX + floatX,
                                 y: head.y + baseOffY + floatY)

            // Keep the anchor on-screen with a small margin even when
            // the body is right at an edge.
            let pad: CGFloat = 80
            anchor.x = min(max(anchor.x, pad), size.width  - pad)
            anchor.y = min(max(anchor.y, pad), size.height - pad)

            // ---- (1) String from head to blob (sagging quad bezier).
            drawString(from: head, to: anchor, ctx: ctx)

            // ---- (2) Blob shape (organic, audio-wobbled, glowing).
            let blobSize = blobSize(for: lineText)
            drawBlob(at: anchor, size: blobSize, ctx: ctx)

            // ---- (3) Lyric text inside the blob (chromatic-split).
            drawLyric(lineText, at: anchor, blobSize: blobSize, ctx: ctx)
        }
        .allowsHitTesting(false)
        .drawingGroup()
        .onReceive(timer) { _ in
            nowT = CFAbsoluteTimeGetCurrent()
        }
    }

    // MARK: -- String

    private func drawString(from a: CGPoint, to b: CGPoint,
                            ctx: GraphicsContext) {
        // Slack midpoint pulled downward — gives the rope a believable
        // sag. Sag deepens with bass so the rope visibly slumps on the
        // low end and snaps tight on quiet sections.
        let sag = 28 + CGFloat(audioLow) * 26 + CGFloat(audioTransient) * 18
        let mid = CGPoint(x: (a.x + b.x) / 2,
                          y: (a.y + b.y) / 2 + sag)

        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: mid)

        let split = CGFloat(1 + 3 * audioHigh + 5 * audioTransient)

        var sub = ctx
        sub.blendMode = .plusLighter

        // Red channel — offset left.
        var pr = Path()
        pr.move(to: CGPoint(x: a.x - split, y: a.y))
        pr.addQuadCurve(to: CGPoint(x: b.x - split, y: b.y),
                        control: CGPoint(x: mid.x - split, y: mid.y))
        sub.stroke(pr,
                   with: .color(Color(red: 1.0, green: 0.20,
                                      blue: 0.30).opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        // Blue channel — offset right.
        var pb = Path()
        pb.move(to: CGPoint(x: a.x + split, y: a.y))
        pb.addQuadCurve(to: CGPoint(x: b.x + split, y: b.y),
                        control: CGPoint(x: mid.x + split, y: mid.y))
        sub.stroke(pb,
                   with: .color(Color(red: 0.25, green: 0.55,
                                      blue: 1.0).opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        // Crisp white core on top.
        sub.stroke(path, with: .color(.white.opacity(0.90)),
                   style: StrokeStyle(lineWidth: 1.0, lineCap: .round))

        // Anchor dots at both ends — tiny "this is hooked here" cue.
        let r: CGFloat = 3
        sub.fill(Path(ellipseIn: CGRect(x: a.x - r, y: a.y - r,
                                        width: r * 2, height: r * 2)),
                 with: .color(.white))
        sub.fill(Path(ellipseIn: CGRect(x: b.x - r, y: b.y - r,
                                        width: r * 2, height: r * 2)),
                 with: .color(.white))
    }

    // MARK: -- Blob shape

    private func blobSize(for text: String) -> CGSize {
        // Rough width estimate: 11 px per char at the 16 pt body size,
        // padded; height fixed unless the line is huge.
        let estW = max(140, CGFloat(text.count) * 11 + 56)
        let estH: CGFloat = 64
        let pulse = CGFloat(1 + 0.05 * audioLevel + 0.10 * audioTransient)
        return CGSize(width: estW * pulse, height: estH * pulse)
    }

    private func drawBlob(at center: CGPoint, size: CGSize,
                          ctx: GraphicsContext) {
        // Build the organic outline by sampling N points around an
        // ellipse and perturbing each radius with a sum of sines.
        let segments = 48
        var path = Path()
        let baseRX = size.width  / 2
        let baseRY = size.height / 2

        for k in 0...segments {
            let theta = Double(k) / Double(segments) * 2 * .pi
            let wob = sin(theta * 3 + nowT * 2.1) * 5.0
                    + sin(theta * 5 + nowT * 3.7) * 4.0 * audioMid
                    + cos(theta * 7 + nowT * 1.3) * 6.0 * audioHigh
                    + sin(theta * 2 + nowT * 0.7) * 3.0
            let rx = baseRX + CGFloat(wob)
            let ry = baseRY + CGFloat(wob) * 0.7
            let x = center.x + CGFloat(cos(theta)) * rx
            let y = center.y + CGFloat(sin(theta)) * ry
            if k == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()

        // Dark plate fill so the lyric text inside reads against any
        // background. Slightly transparent so the world shows through.
        ctx.fill(path, with: .color(.black.opacity(0.55)))

        // RGB-split stroke for the chromatic ring.
        let split = CGFloat(1.5 + 4 * audioLevel + 8 * audioTransient)

        var sub = ctx
        sub.blendMode = .plusLighter

        // Offset paths by translating a sub-context — easier than
        // rebuilding the path three times with different centres.
        var subR = sub
        subR.translateBy(x: -split, y: -split * 0.4)
        subR.stroke(path,
                    with: .color(Color(red: 1.0, green: 0.20,
                                       blue: 0.30).opacity(0.80)),
                    style: StrokeStyle(lineWidth: 1.4))

        var subB = sub
        subB.translateBy(x: split, y: split * 0.4)
        subB.stroke(path,
                    with: .color(Color(red: 0.25, green: 0.55,
                                       blue: 1.00).opacity(0.80)),
                    style: StrokeStyle(lineWidth: 1.4))

        // Core white outline on top.
        sub.stroke(path, with: .color(.white.opacity(0.95)),
                   style: StrokeStyle(lineWidth: 1.0))

        // Soft inner glow — single filled blur of the path scaled down
        // a touch. Cheap halo without a real Gaussian.
        var inner = Path()
        let glowRX = baseRX * 0.92
        let glowRY = baseRY * 0.85
        for k in 0...segments {
            let theta = Double(k) / Double(segments) * 2 * .pi
            let x = center.x + CGFloat(cos(theta)) * glowRX
            let y = center.y + CGFloat(sin(theta)) * glowRY
            if k == 0 { inner.move(to: CGPoint(x: x, y: y)) }
            else { inner.addLine(to: CGPoint(x: x, y: y)) }
        }
        inner.closeSubpath()
        let glowAlpha = 0.10 + 0.18 * audioLevel + 0.20 * audioTransient
        sub.fill(inner, with: .color(.white.opacity(min(1.0, glowAlpha))))
    }

    // MARK: -- Inner lyric text

    private func drawLyric(_ text: String, at center: CGPoint,
                           blobSize: CGSize, ctx: GraphicsContext) {
        let fontSizePx: CGFloat = CGFloat(fontSize) + CGFloat(2 * audioLevel)
        let font = Font.system(size: fontSizePx, weight: .heavy,
                               design: .rounded)

        // Per-glyph measure + per-char chromatic split, same idea as
        // the main current-line draw but at a smaller scale and
        // without the camera-shake / explosion chaos (this is the
        // pinned annotation, not the focal moment).
        let chars = Array(text)
        let measureBox = CGSize(width: 200, height: fontSizePx * 2)
        let widths: [CGFloat] = chars.map { ch in
            ctx.resolve(Text(String(ch)).font(font))
                .measure(in: measureBox).width
        }
        let totalW = widths.reduce(0, +)
        var x = center.x - totalW / 2

        // Highlight wipe — same lineProgress semantics as the main
        // overlay. Reusing it here means the blob's lyric lights up
        // in lock-step with the big line.
        let progress = store.lineProgress
        let highlightX = x + totalW * CGFloat(progress)

        let split = CGFloat(0.8 + 2.5 * audioLevel + 4 * audioTransient)
        let phase = nowT * 6.5
        let liveAmp = CGFloat(0.6 + 4 * audioLevel + 3 * audioHigh)

        var sub = ctx
        sub.blendMode = .plusLighter

        for (idx, ch) in chars.enumerated() {
            let w = widths[idx]
            let cx = x + w / 2
            let yWave = CGFloat(sin(Double(idx) * 0.5 + phase)) * liveAmp
            let lit = cx <= highlightX

            // Three-pass colour stack.
            let passes: [(CGFloat, Color)]
            if lit {
                passes = [
                    (-split, Color(red: 1.00, green: 0.22, blue: 0.30)),
                    ( 0,     Color(red: 0.55, green: 1.00, blue: 0.70)),
                    ( split, Color(red: 0.30, green: 0.60, blue: 1.00)),
                ]
            } else {
                passes = [
                    (-split * 0.6, Color.white.opacity(0.12)),
                    ( 0,           Color.white.opacity(0.30)),
                    ( split * 0.6, Color.white.opacity(0.12)),
                ]
            }

            for (dx, tint) in passes {
                let t = Text(String(ch)).font(font).foregroundColor(tint)
                sub.draw(t,
                         at: CGPoint(x: cx + dx, y: center.y + yWave),
                         anchor: .center)
            }
            x += w
        }
        // Small "▸" leading caret so the bubble reads as a tagged
        // annotation, not a free-floating sentence. Drawn dim so it
        // doesn't compete with the lyric.
        let caret = Text("▸")
            .font(.system(size: fontSizePx * 0.85, weight: .black))
            .foregroundColor(.white.opacity(0.45))
        sub.draw(caret,
                 at: CGPoint(x: center.x - totalW / 2 - 14,
                             y: center.y),
                 anchor: .center)
    }
}
