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
    /// Beat number from the start of this loop (0-based, quarter-note grid).
    let beat: Double
    /// Lane index 0–3 into this song's laneNotes/laneColors arrays.
    let lane: Int
    /// Duration in beats — controls tile height (long note = taller tile).
    let duration: Double
}

// Plain handle — no MusicKit import required here.
struct AppleMusicHandle {
    let musicItemID: String
    let title: String
    let artistName: String
    let duration: TimeInterval?    // nil when unknown
}

struct TileSong {
    let title: String
    let composer: String
    let bpm: Double
    let events: [NoteEvent]

    /// MIDI note number per lane (8 values).
    let laneNotes: [UInt8]
    /// UI accent colour per lane (8 values).
    let laneColors: [Color]

    /// Non-nil when this song is backed by an Apple Music catalog track.
    var appleMusicHandle: AppleMusicHandle? = nil

    init(title: String, composer: String, bpm: Double, events: [NoteEvent],
         laneNotes: [UInt8], laneColors: [Color],
         appleMusicHandle: AppleMusicHandle? = nil) {
        self.title            = title
        self.composer         = composer
        self.bpm              = bpm
        self.events           = events
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
    // 56 BPM, 4/4, quarter-note tile grid.
    // Lanes: G4(0) A4(1) B4(2) C5(3) D5(4) E5(5) F#5(6) G5(7)
    //
    // Structure (48-beat loop ≈ 51 s):
    //   Section A  beats  0–15   Ostinato G–B–D–B with passing fills
    //   Section B  beats 16–31   Melody enters   ascending G4→G5 phrases
    //   Section C  beats 32–47   Full melody     all 8 lanes engaged
    // -------------------------------------------------------------------------
    static let experience: TileSong = {
        var ev: [NoteEvent] = []

        func add(_ beat: Double, _ lane: Int, dur: Double = 1.0) {
            ev.append(NoteEvent(beat: beat, lane: lane, duration: dur))
        }

        // Section A: Ostinato (G B D B) on lanes 0,2,4,2 + passing fills on odd lanes
        for bar in 0..<4 {
            let b = Double(bar * 4)
            add(b + 0, 0); add(b + 0.5, 1)
            add(b + 1, 2); add(b + 1.5, 3)
            add(b + 2, 4); add(b + 2.5, 3)
            add(b + 3, 2)
        }

        // Section B: Ascending melody
        add(16, 2); add(16.5, 3); add(17, 4); add(17.5, 5)
        add(18, 7, dur: 1.5); add(19.5, 4)
        add(20, 2); add(20.5, 1); add(21, 0); add(21.5, 1); add(22, 2); add(23, 4)
        add(24, 7, dur: 1.5); add(25.5, 5); add(26, 4); add(26.5, 3); add(27, 2)
        add(28, 7, dur: 1.5); add(29.5, 5); add(30, 4); add(30.5, 2); add(31, 0)

        // Section C: Full melody, all 8 lanes
        add(32, 2); add(32.5, 3); add(33, 4); add(33.5, 5)
        add(34, 7, dur: 1.5); add(35.5, 4)
        add(36, 2); add(36.5, 3); add(37, 4); add(37.5, 5); add(38, 6); add(38.5, 7)
        add(39, 6)
        add(40, 5); add(40.5, 4); add(41, 2); add(41.5, 1); add(42, 0); add(43, 2)
        add(44, 4); add(45, 7, dur: 2.0); add(47, 5); add(47.5, 2)

        return TileSong(
            title: "Experience",
            composer: "Ludovico Einaudi",
            bpm: 56.0,
            events: ev.sorted { $0.beat < $1.beat },
            // G4  A4  B4  C5  D5  E5  F#5 G5
            laneNotes: [67, 69, 71, 72, 74, 76, 78, 79],
            laneColors: [
                Color(red: 0.20, green: 0.72, blue: 1.00),  // cyan-blue
                Color(red: 0.10, green: 0.90, blue: 0.82),  // teal
                Color(red: 0.25, green: 1.00, blue: 0.55),  // spring-green
                Color(red: 0.72, green: 1.00, blue: 0.20),  // lime
                Color(red: 1.00, green: 0.80, blue: 0.20),  // gold
                Color(red: 1.00, green: 0.50, blue: 0.10),  // orange
                Color(red: 1.00, green: 0.28, blue: 0.75),  // rose-pink
                Color(red: 0.72, green: 0.22, blue: 1.00),  // violet
            ]
        )
    }()

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
