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

struct TileSong {
    let title: String
    let composer: String
    let bpm: Double
    let events: [NoteEvent]

    /// MIDI note number per lane (4 values).
    let laneNotes: [UInt8]
    /// UI accent colour per lane (4 values).
    let laneColors: [Color]

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
    // Lanes: G4(0) B4(1) D5(2) G5(3)
    //
    // Structure (48-beat loop ≈ 51 s):
    //   Section A  beats  0–15   Ostinato only   G–B–D–B × 4
    //   Section B  beats 16–31   Melody enters   ascending G4→G5 phrases
    //   Section C  beats 32–47   Full melody     peak + resolution
    // -------------------------------------------------------------------------
    static let experience: TileSong = {
        var ev: [NoteEvent] = []

        func add(_ beat: Double, _ lane: Int, dur: Double = 1.0) {
            ev.append(NoteEvent(beat: beat, lane: lane, duration: dur))
        }

        // Section A: Pure ostinato (G B D B) × 4
        for bar in 0..<4 {
            let b = Double(bar * 4)
            add(b + 0, 0); add(b + 1, 1); add(b + 2, 2); add(b + 3, 1)
        }

        // Section B: Melody starts
        add(16, 1); add(17, 2); add(18, 3, dur: 1.5); add(19.5, 2)
        add(20, 1); add(21, 0); add(22, 1); add(23, 2)
        add(24, 3, dur: 1.5); add(25.5, 2); add(26, 1); add(27, 2)
        add(28, 3, dur: 1.5); add(29.5, 2); add(30, 1); add(31, 0)

        // Section C: Full melody, peak + resolution
        add(32, 1); add(33, 2); add(34, 3, dur: 1.5); add(35.5, 2)
        add(36, 1); add(37, 2); add(38, 3, dur: 1.0); add(39, 3, dur: 1.0)
        add(40, 2); add(41, 1); add(42, 0); add(43, 1)
        add(44, 2); add(45, 3, dur: 2.0); add(47, 2); add(47.5, 1)

        return TileSong(
            title: "Experience",
            composer: "Ludovico Einaudi",
            bpm: 56.0,
            events: ev.sorted { $0.beat < $1.beat },
            // G4  B4   D5   G5
            laneNotes: [67, 71, 74, 79],
            laneColors: [
                Color(red: 0.20, green: 0.72, blue: 1.00),  // cyan-blue
                Color(red: 0.25, green: 1.00, blue: 0.55),  // spring-green
                Color(red: 1.00, green: 0.80, blue: 0.20),  // gold
                Color(red: 1.00, green: 0.28, blue: 0.75),  // rose-pink
            ]
        )
    }()

    // -------------------------------------------------------------------------
    // MARK: "Für Elise" — Ludwig van Beethoven  (WoO 59, c. 1810)
    //
    // 75 BPM, quarter-note tile grid (8th-note motif compressed to quarters
    // so tiles arrive at a body-movement-friendly pace).
    // Lanes: A4(0) C5(1) E5(2) D#5(3)
    //
    // Structure (32-beat loop ≈ 26 s):
    //   Section A1 beats  0–7   Opening motif   E–D#–E–D#–E–C–E–A
    //   Section A2 beats  8–15  Bridge/response A–C–E–A + bass echo
    //   Section B  beats 16–23  Relative major  C–E–A arpeggios
    //   Section A3 beats 24–31  Reprise + close E–D#–E–D#–E–C–E–A
    // -------------------------------------------------------------------------
    static let furElise: TileSong = {
        var ev: [NoteEvent] = []

        func add(_ beat: Double, _ lane: Int, dur: Double = 1.0) {
            ev.append(NoteEvent(beat: beat, lane: lane, duration: dur))
        }

        // Section A1: Famous opening motif (E D# E D# E C E A)
        add(0, 2);          // E5
        add(1, 3);          // D#5
        add(2, 2);          // E5
        add(3, 3);          // D#5
        add(4, 2);          // E5
        add(5, 1);          // C5
        add(6, 2);          // E5
        add(7, 0, dur: 1.5) // A4 held

        // Section A2: Bass arpeggio response (A C E / A B E)
        add(9, 0);          // A4
        add(10, 1);         // C5
        add(11, 2);         // E5
        add(12, 0, dur: 1.5) // A4 held
        add(14, 0);         // A4
        add(15, 1);         // C5

        // Section B: Relative major (C major arpeggios, then back)
        add(16, 1);         // C5
        add(17, 2);         // E5
        add(18, 0);         // A4 (oct)
        add(19, 0, dur: 1.5) // A4 held
        add(21, 2);         // E5
        add(22, 1);         // C5
        add(23, 2);         // E5

        // Section A3: Reprise of opening motif
        add(24, 2);         // E5
        add(25, 3);         // D#5
        add(26, 2);         // E5
        add(27, 3);         // D#5
        add(28, 2);         // E5
        add(29, 1);         // C5
        add(30, 2);         // E5
        add(31, 0, dur: 2.0) // A4 long close

        return TileSong(
            title: "Für Elise",
            composer: "Ludwig van Beethoven",
            bpm: 75.0,
            events: ev.sorted { $0.beat < $1.beat },
            // A4   C5   E5   D#5
            laneNotes: [69, 72, 76, 75],
            laneColors: [
                Color(red: 1.00, green: 0.62, blue: 0.10),  // amber
                Color(red: 0.10, green: 0.85, blue: 0.78),  // teal
                Color(red: 0.72, green: 0.22, blue: 1.00),  // violet
                Color(red: 1.00, green: 0.18, blue: 0.38),  // crimson
            ]
        )
    }()
}
