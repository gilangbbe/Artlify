//
//  TileSong.swift
//  Artlify / GameKit — universe-tune branch
//
//  Data model for a falling-tile song.  One NoteEvent = one tile.
//  Each TileSong carries its own lane→MIDI mapping and per-lane colours
//  so Experience and Für Elise can use completely different pitches and
//  visual identities.
//

import Foundation
import SwiftUI

struct NoteEvent: Identifiable {
    var id = UUID()
    let beat: Double
    let lane: Int
    let duration: Double  // beats — controls tile height
}

/// A background note that plays automatically — not a tile, not interactive.
/// Carries the raw MIDI pitch so any note (bass, arpeggios below lane range) can play.
struct BgNote: Identifiable {
    var id = UUID()
    let beat: Double
    let midiNote: UInt8
    let duration: Double  // beats — controls sustain length
}

// Plain handle — no MusicKit import required here.
struct AppleMusicHandle {
    let musicItemID: String
    let title: String
    let artistName: String
    let duration: TimeInterval? // nil when unknown
    let tempo: Double?          // BPM from MusicKit extended attributes; nil = not in catalog
    let keySignature: String?   // e.g. "C", "F#m", "Bb Minor"; nil = not in catalog
}

struct TileSong {
    let title: String
    let composer: String
    let bpm: Double
    /// Tile events — only the main melody.  Each one spawns a falling tile.
    let events: [NoteEvent]
    /// Background notes — arpeggios and bass.  Auto-play; never become tiles.
    let bgNotes: [BgNote]

    /// MIDI note number per lane (8 values).
    let laneNotes: [UInt8]
    /// UI accent colour per lane (8 values).
    let laneColors: [Color]

    /// Non-nil when this song is backed by an Apple Music catalog track.
    var appleMusicHandle: AppleMusicHandle? = nil

    init(title: String, composer: String, bpm: Double,
         events: [NoteEvent], bgNotes: [BgNote] = [],
         laneNotes: [UInt8], laneColors: [Color],
         appleMusicHandle: AppleMusicHandle? = nil) {
        self.title            = title
        self.composer         = composer
        self.bpm              = bpm
        self.events           = events
        self.bgNotes          = bgNotes
        self.laneNotes        = laneNotes
        self.laneColors       = laneColors
        self.appleMusicHandle = appleMusicHandle
    }

    var beatDuration: Double { 60.0 / bpm }

    /// Seconds from beat-0 to the last note's end (used for loop boundary).
    var totalDuration: Double {
        guard let last = events.max(by: { $0.beat < $1.beat }) else { return 0 }
        return (last.beat + last.duration) * beatDuration + 1.0
    }

    // -------------------------------------------------------------------------
    // MARK: "Experience" — Ludovico Einaudi  (from "In a Time Lapse", 2013)
    //
    // Loaded from "Songs/Ludovico Einaudi - Experience.mid" at runtime via
    // MIDILoader.  Falls back to the hand-transcribed events if the bundle
    // resource is missing.
    //
    // Key: A major.  Lanes: A4(0) B4(1) C#5(2) D5(3) E5(4) F#5(5) G#5(6) A5(7)
    // Tempo: 72 BPM intro (beats 0–32) → 80 BPM main body (beats 32–418) →
    //        ritardando ending.  MIDILoader picks 80 BPM as the canonical tempo.
    // Full song: ~450 beats (≈5.8 min).  Loops on completion.
    // -------------------------------------------------------------------------
    static let experience: TileSong = {
        // A major scale A4→A5 — the 8 lanes
        let laneNotes: [UInt8] = [69, 71, 73, 74, 76, 78, 80, 81]
        //                         A4  B4  C#5 D5  E5  F#5 G#5 A5

        // Prefer MIDI file; fall back to hand-coded events if bundle load fails.
        // beatLimit 9999 = load the complete ~450-beat song.
        // MIDILoader separates long notes (melody tiles) from short notes (bg arpeggios + bass).
        let midi    = MIDILoader.load(resource: "Ludovico Einaudi - Experience",
                                      laneNotes: laneNotes,
                                      beatLimit: 9999)
        let events  = midi?.events  ?? Experience.fallback
        let bgNotes = midi?.bgNotes ?? []
        let bpm     = midi?.bpm     ?? 80.0

        return TileSong(
            title: "Experience",
            composer: "Ludovico Einaudi",
            bpm: bpm,
            events: events,
            bgNotes: bgNotes,
            laneNotes: laneNotes,
            laneColors: [
                Color(red: 1.00, green: 0.75, blue: 0.20),  // A4  — amber
                Color(red: 1.00, green: 0.95, blue: 0.35),  // B4  — yellow
                Color(red: 0.30, green: 1.00, blue: 0.65),  // C#5 — spring (primary melody)
                Color(red: 0.20, green: 0.80, blue: 1.00),  // D5  — sky-blue
                Color(red: 0.45, green: 0.55, blue: 1.00),  // E5  — periwinkle
                Color(red: 0.72, green: 0.25, blue: 1.00),  // F#5 — violet
                Color(red: 1.00, green: 0.28, blue: 0.65),  // G#5 — rose
                Color(red: 1.00, green: 1.00, blue: 1.00),  // A5  — white (octave peak)
            ]
        )
    }()

    // Hand-transcribed fallback extracted from the MIDI file (32-beat phrase)
    private enum Experience {
        static let fallback: [NoteEvent] = {
            var ev: [NoteEvent] = []
            func add(_ beat: Double, _ lane: Int, dur: Double = 1.0) {
                ev.append(NoteEvent(beat: beat, lane: lane, duration: dur))
            }
            // Core motif: C#5(2) C#5(2) D5(3) C#5(2) × 7 bars + ending
            add( 0, 2); add( 1, 2); add( 2, 3); add( 3, 2)
            add( 4, 2); add( 5, 2); add( 6, 3); add( 7, 2)
            add( 8, 2); add( 9, 2); add(10, 3); add(11, 2)
            add(12, 2); add(13, 1); add(14, 2); add(15, 3)  // B4 variation
            add(16, 2); add(17, 2); add(18, 3); add(19, 2)
            add(20, 2); add(21, 2); add(22, 3); add(23, 2)
            add(24, 2); add(25, 2); add(26, 3); add(27, 2)
            add(28, 2); add(29, 1); add(30, 0); add(31, 1)  // C#5 B4 A4 B4
            return ev
        }()
    }

    // -------------------------------------------------------------------------
    // MARK: "Für Elise" — Ludwig van Beethoven  (WoO 59, c. 1810)
    //
    // 75 BPM, quarter-note tile grid.
    // Lanes: A4(0) B4(1) C5(2) D5(3) E5(4) F5(5) G#5(6) A5(7)
    //        (A harmonic minor, two octaves)
    //
    // Structure (32-beat loop ≈ 26 s):
    //   Section A1 beats  0–7   Opening motif   E–G#–E–G#–E–C–E–A
    //   Section A2 beats  8–15  Bridge/response A–C–E arpeggio + fills
    //   Section B  beats 16–23  Relative major  C–D–E–F run + arpeggios
    //   Section A3 beats 24–31  Reprise + high A5 close
    // -------------------------------------------------------------------------
    static let furElise: TileSong = {
        var ev: [NoteEvent] = []

        func add(_ beat: Double, _ lane: Int, dur: Double = 1.0) {
            ev.append(NoteEvent(beat: beat, lane: lane, duration: dur))
        }

        // Section A1: Famous motif (E G# E G# E C E A) — lanes 4,6,2,0
        add(0, 4)            // E5
        add(0.5, 5)          // F5 passing
        add(1, 6)            // G#5
        add(2, 4)            // E5
        add(2.5, 3)          // D5 passing
        add(3, 6)            // G#5
        add(4, 4)            // E5
        add(4.5, 3)          // D5
        add(5, 2)            // C5
        add(6, 4)            // E5
        add(7, 0, dur: 1.5)  // A4 held

        // Section A2: Bass arpeggio A–B–C–D–E + echo
        add(9, 0)            // A4
        add(9.5, 1)          // B4
        add(10, 2)           // C5
        add(10.5, 3)         // D5
        add(11, 4)           // E5
        add(12, 0, dur: 1.5) // A4 held
        add(14, 0)           // A4
        add(14.5, 1)         // B4
        add(15, 2)           // C5
        add(15.5, 3)         // D5

        // Section B: C major arpeggios across all 8 lanes
        add(16, 2)           // C5
        add(16.5, 3)         // D5
        add(17, 4)           // E5
        add(17.5, 5)         // F5
        add(18, 0)           // A4
        add(19, 0, dur: 1.5) // A4 held
        add(20.5, 5)         // F5
        add(21, 4)           // E5
        add(21.5, 3)         // D5
        add(22, 2)           // C5
        add(22.5, 3)         // D5
        add(23, 4)           // E5

        // Section A3: Reprise + high A5 close
        add(24, 4)           // E5
        add(24.5, 5)         // F5 passing
        add(25, 6)           // G#5
        add(26, 4)           // E5
        add(26.5, 3)         // D5 passing
        add(27, 6)           // G#5
        add(28, 4)           // E5
        add(28.5, 3)         // D5
        add(29, 2)           // C5
        add(30, 4)           // E5
        add(30.5, 5)         // F5
        add(31, 0, dur: 2.0) // A4 long close
        add(31.5, 7, dur: 1.5) // A5 high close

        return TileSong(
            title: "Für Elise",
            composer: "Ludwig van Beethoven",
            bpm: 75.0,
            events: ev.sorted { $0.beat < $1.beat },
            // A4  B4  C5  D5  E5  F5  G#5 A5
            laneNotes: [69, 71, 72, 74, 76, 77, 80, 81],
            laneColors: [
                Color(red: 1.00, green: 0.62, blue: 0.10),  // amber
                Color(red: 1.00, green: 0.80, blue: 0.10),  // yellow
                Color(red: 0.60, green: 1.00, blue: 0.20),  // chartreuse
                Color(red: 0.10, green: 0.85, blue: 0.78),  // teal
                Color(red: 0.20, green: 0.72, blue: 1.00),  // sky-blue
                Color(red: 0.72, green: 0.22, blue: 1.00),  // violet
                Color(red: 1.00, green: 0.18, blue: 0.38),  // crimson
                Color(red: 1.00, green: 0.45, blue: 0.80),  // hot-pink
            ]
        )
    }()
}
