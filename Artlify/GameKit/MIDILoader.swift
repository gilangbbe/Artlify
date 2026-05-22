//
//  MIDILoader.swift
//  Artlify / GameKit — universe-tune branch
//
//  Reads a Standard MIDI File (.mid / Format 0 or 1) from the app bundle.
//
//  Returns TWO event arrays:
//    • events  — melody tiles: long notes (≥ 0.5 beats) whose pitch maps to
//                a game lane.  One tile per melody note.
//    • bgNotes — background auto-play: short arpeggios (<0.5 beats) and any
//                note whose pitch is outside the 8 lane pitches.  These play
//                automatically so the song sounds complete even when tiles
//                are missed.
//
//  Multi-tempo aware: builds a full tempo map so every tick position converts
//  to an accurate absolute time in seconds, then re-expresses that as a beat
//  position at the dominant (longest-spanning) tempo.
//

import Foundation

enum MIDILoader {

    static func load(
        resource: String,
        laneNotes: [UInt8],
        beatLimit: Double,
        quantize: Double = 0.25
    ) -> (events: [NoteEvent], bgNotes: [BgNote], bpm: Double)? {
        guard
            let url  = Bundle.main.url(forResource: resource,
                                       withExtension: "mid",
                                       subdirectory: "Songs"),
            let data = try? Data(contentsOf: url)
        else { return nil }

        return parse(data: data, laneNotes: laneNotes,
                     beatLimit: beatLimit, quantize: quantize)
    }

    // MARK: - Parser

    private static func parse(
        data: Data,
        laneNotes: [UInt8],
        beatLimit: Double,
        quantize: Double
    ) -> (events: [NoteEvent], bgNotes: [BgNote], bpm: Double)? {

        var r = Reader(data: data)

        guard r.bytes(4) == [0x4D, 0x54, 0x68, 0x64] else { return nil }  // "MThd"
        _ = r.u32()
        _ = r.u16()                        // format
        let trackCount = Int(r.u16())
        let tpq        = Int(r.u16())
        guard tpq > 0 else { return nil }

        let tracksStart = r.pos

        // Pass 1: build tempo map
        let tempoMap  = buildTempoMap(data: data, pos: tracksStart, trackCount: trackCount)
        let canonical = dominantBPM(tempoMap: tempoMap)
        let limitSecs = beatLimit * 60.0 / canonical

        let pitchSet    = Set(laneNotes)
        let pitchToLane = Dictionary(uniqueKeysWithValues: laneNotes.enumerated().map { ($1, $0) })

        var tilesSeen = Set<String>()
        var bgSeen    = Set<String>()
        var tileEvents = [NoteEvent]()
        var bgNotes    = [BgNote]()

        // Pass 2: extract notes
        r.pos = tracksStart
        for _ in 0..<trackCount {
            guard r.bytes(4) == [0x4D, 0x54, 0x72, 0x6B] else { continue }  // "MTrk"
            let trackLen = Int(r.u32())
            let trackEnd = r.pos + trackLen

            var tick:      Int          = 0
            var runStatus: UInt8?       = nil
            var noteOnAt:  [UInt8: Int] = [:]

            while r.pos < trackEnd {
                tick += r.vlq()
                let b = data[r.pos]

                if b == 0xFF {
                    r.pos += 1; r.pos += 1; r.pos += r.vlq()

                } else if b == 0xF0 || b == 0xF7 {
                    r.pos += 1; r.pos += r.vlq()

                } else {
                    if b & 0x80 != 0 { runStatus = b; r.pos += 1 }
                    guard let status = runStatus else { break }

                    switch (status >> 4) & 0xF {
                    case 0x9:
                        let pitch = data[r.pos]; r.pos += 1
                        let vel   = data[r.pos]; r.pos += 1
                        if vel > 0 { noteOnAt[pitch] = tick }
                        else {
                            commit(pitch: pitch, endTick: tick,
                                   noteOnAt: &noteOnAt, tpq: tpq,
                                   tempoMap: tempoMap, canonical: canonical,
                                   limitSecs: limitSecs, quantize: quantize,
                                   pitchToLane: pitchToLane, pitchSet: pitchSet,
                                   tilesSeen: &tilesSeen, bgSeen: &bgSeen,
                                   tileEvents: &tileEvents, bgNotes: &bgNotes)
                        }
                    case 0x8:
                        let pitch = data[r.pos]; r.pos += 1; r.pos += 1
                        commit(pitch: pitch, endTick: tick,
                               noteOnAt: &noteOnAt, tpq: tpq,
                               tempoMap: tempoMap, canonical: canonical,
                               limitSecs: limitSecs, quantize: quantize,
                               pitchToLane: pitchToLane, pitchSet: pitchSet,
                               tilesSeen: &tilesSeen, bgSeen: &bgSeen,
                               tileEvents: &tileEvents, bgNotes: &bgNotes)
                    case 0xA, 0xB, 0xE: r.pos += 2
                    case 0xC, 0xD:      r.pos += 1
                    default: break
                    }
                }
            }
            r.pos = trackEnd
        }

        guard !tileEvents.isEmpty else { return nil }
        return (tileEvents.sorted { $0.beat < $1.beat },
                bgNotes.sorted    { $0.beat < $1.beat },
                canonical)
    }

    // MARK: - Tempo map

    private struct TempoPoint {
        let tick: Int
        let uspb: Int
    }

    private static func buildTempoMap(data: Data, pos startPos: Int,
                                       trackCount: Int) -> [TempoPoint] {
        var tempos: [TempoPoint] = [TempoPoint(tick: 0, uspb: 500_000)]
        var r = Reader(data: data)
        r.pos = startPos

        for _ in 0..<trackCount {
            guard r.bytes(4) == [0x4D, 0x54, 0x72, 0x6B] else { continue }
            let trackLen = Int(r.u32())
            let trackEnd = r.pos + trackLen
            var tick = 0; var run: UInt8? = nil

            while r.pos < trackEnd {
                tick += r.vlq()
                let b = data[r.pos]
                if b == 0xFF {
                    r.pos += 1; let mt = data[r.pos]; r.pos += 1; let ml = r.vlq()
                    if mt == 0x51, ml >= 3 {
                        var us = 0
                        for _ in 0..<3 { us = (us << 8) | Int(data[r.pos]); r.pos += 1 }
                        r.pos += ml - 3
                        if tick == 0 { tempos[0] = TempoPoint(tick: 0, uspb: us) }
                        else         { tempos.append(TempoPoint(tick: tick, uspb: us)) }
                    } else { r.pos += ml }
                } else if b == 0xF0 || b == 0xF7 { r.pos += 1; r.pos += r.vlq() }
                else {
                    if b & 0x80 != 0 { run = b; r.pos += 1 }
                    guard let s = run else { break }
                    switch (s >> 4) & 0xF {
                    case 0x9, 0x8, 0xA, 0xB, 0xE: r.pos += 2
                    case 0xC, 0xD:                 r.pos += 1
                    default: break
                    }
                }
            }
            r.pos = trackEnd
        }
        return tempos.sorted { $0.tick < $1.tick }
    }

    private static func dominantBPM(tempoMap: [TempoPoint]) -> Double {
        guard tempoMap.count > 1 else {
            return 60_000_000.0 / Double(tempoMap[0].uspb)
        }
        var coverage: [Int: Int] = [:]
        for i in 0..<tempoMap.count - 1 {
            coverage[tempoMap[i].uspb, default: 0] += tempoMap[i + 1].tick - tempoMap[i].tick
        }
        let dominant = coverage.max(by: { $0.value < $1.value })?.key ?? tempoMap[0].uspb
        return 60_000_000.0 / Double(dominant)
    }

    private static func tickToSeconds(_ tick: Int,
                                       tempoMap: [TempoPoint]) -> Double {
        var acc = 0.0; var prevTick = 0; var prevUspb = tempoMap[0].uspb
        for i in 1..<tempoMap.count {
            let tm = tempoMap[i]
            if tm.tick >= tick { break }
            acc += Double(tm.tick - prevTick) * Double(prevUspb)
            prevTick = tm.tick; prevUspb = tm.uspb
        }
        acc += Double(tick - prevTick) * Double(prevUspb)
        return acc
    }

    // MARK: - Commit

    private static func commit(
        pitch: UInt8, endTick: Int,
        noteOnAt: inout [UInt8: Int],
        tpq: Int, tempoMap: [TempoPoint], canonical: Double,
        limitSecs: Double, quantize: Double,
        pitchToLane: [UInt8: Int], pitchSet: Set<UInt8>,
        tilesSeen: inout Set<String>, bgSeen: inout Set<String>,
        tileEvents: inout [NoteEvent], bgNotes: inout [BgNote]
    ) {
        guard let startTick = noteOnAt.removeValue(forKey: pitch) else { return }

        let scale    = 1.0 / (Double(tpq) * 1_000_000.0)
        let startSec = tickToSeconds(startTick, tempoMap: tempoMap) * scale
        let endSec   = tickToSeconds(endTick,   tempoMap: tempoMap) * scale
        guard startSec < limitSecs else { return }

        let bps     = canonical / 60.0
        let beat    = startSec * bps
        let durBeat = (endSec - startSec) * bps

        let qBeat = (beat    / quantize).rounded() * quantize
        let qDur  = max((durBeat / quantize).rounded() * quantize, quantize)

        // Melody tile: sustained note (≥ 0.5 beats) whose pitch is a lane note
        if durBeat >= 0.5, let lane = pitchToLane[pitch] {
            let key = "\(qBeat):\(pitch)"
            guard !tilesSeen.contains(key) else { return }
            tilesSeen.insert(key)
            tileEvents.append(NoteEvent(beat: qBeat, lane: lane, duration: qDur))

        } else {
            // Background: short arpeggios, bass, any out-of-range pitch
            let key = "\(qBeat):\(pitch)"
            guard !bgSeen.contains(key) else { return }
            bgSeen.insert(key)
            bgNotes.append(BgNote(beat: qBeat, midiNote: pitch, duration: qDur))
        }
    }

    // MARK: - Reader

    private struct Reader {
        let data: Data
        var pos: Int = 0

        mutating func bytes(_ n: Int) -> [UInt8] {
            let r = Array(data[pos..<pos+n]); pos += n; return r
        }
        mutating func u16() -> UInt16 {
            let v = UInt16(data[pos]) << 8 | UInt16(data[pos+1]); pos += 2; return v
        }
        mutating func u32() -> UInt32 {
            let v = data[pos..<pos+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            pos += 4; return v
        }
        mutating func vlq() -> Int {
            var v = 0
            repeat { let b = Int(data[pos]); pos += 1; v = (v << 7) | (b & 0x7F)
                     if b & 0x80 == 0 { break } } while true
            return v
        }
    }
}
