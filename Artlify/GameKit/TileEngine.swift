//
//  TileEngine.swift
//  Artlify / GameKit — universe-tune branch
//
//  Game loop: spawns falling tiles from TileSong events, detects when
//  body joints (VisionJoint, UV top-left origin) intersect a tile rect,
//  updates score/combo, loops the song, and drives NotePlayer.
//
//  Coordinate system throughout: UV (0,0) = top-left, (1,1) = bottom-right.
//  Vision joints arrive with y flipped by the caller (1 − vision_y).
//
//  Physics:
//    fallSpeed   = 0.22 UV/s → tile crosses the screen in ~5.4 s
//    hitZoneY    = 0.72       → "perfect" tile centre at this UV-y at beat time
//    spawnLeadY  = −0.06      → tile spawns just above the visible area
//
//  A tile is missed only after its leading edge (topY) passes 1.04 UV.
//  It is hit when any confident joint sits inside the tile rect.
//

import Foundation
import CoreGraphics
import Observation

// MARK: - Live tile

struct LiveTile: Identifiable {
    let id = UUID()
    let lane: Int
    let noteDuration: Double       // beats → controls height
    let absoluteTargetTime: Double // game-seconds when tile should be at hitZoneY

    enum State { case active, hit, missed }
    var state: State = .active
    var hitTime: Double?
    var missedTime: Double?
}

// MARK: - Engine

@Observable
@MainActor
final class TileEngine {

    // ---- Published state (read by overlay)
    private(set) var activeTiles: [LiveTile] = []
    private(set) var score: Int = 0
    private(set) var combo: Int = 0
    private(set) var totalHits: Int = 0
    private(set) var totalMisses: Int = 0
    private(set) var songTime: Double = 0
    private(set) var isPlaying: Bool = false

    // ---- Constants
    let fallSpeed: Double = 0.22    // UV per second
    let hitZoneY:  Double = 0.72    // target y at note's beat time
    let laneCount: Int    = 4

    /// When true the joint x-axis is flipped (1 − x) before lane
    /// collision checks, matching the mirrored camera display.
    var isMirrored: Bool = true

    // ---- Dependencies
    let song: TileSong
    let notePlayer: NotePlayer

    // ---- Private state
    private var startTime: CFAbsoluteTime = 0
    private var loopOffset: Double = 0     // running beat offset across loops
    private var nextEventIdx: Int = 0

    // Lead time before tile should hit hitZoneY; tile enters at y = spawnLeadY
    private let spawnLeadY: Double = -0.06
    private var spawnLeadTime: Double { (hitZoneY - spawnLeadY) / fallSpeed }

    init(song: TileSong = .experience) {
        self.song = song
        self.notePlayer = NotePlayer(song: song)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isPlaying else { return }
        isPlaying  = true
        startTime  = CFAbsoluteTimeGetCurrent()
        loopOffset = 0
        nextEventIdx = 0
        activeTiles = []
        score = 0; combo = 0; totalHits = 0; totalMisses = 0
    }

    func stop() {
        isPlaying = false
        activeTiles = []
        notePlayer.teardown()
    }

    func reset() { stop(); start() }

    // MARK: - Per-frame update (60 Hz from ContentView timer)

    /// `joints` must be in UV top-left coords: x ∈ [0,1] left→right,
    /// y ∈ [0,1] top→bottom (Vision's y already flipped by caller).
    func update(joints: [VisionJoint]) {
        guard isPlaying else { return }
        songTime = CFAbsoluteTimeGetCurrent() - startTime

        spawnTiles()
        processCollisions(joints: joints)
        pruneTiles()
        advanceLoop()
    }

    // MARK: - Geometry helpers (used by overlay)

    func tileTopY(_ tile: LiveTile) -> Double {
        hitZoneY + (songTime - tile.absoluteTargetTime) * fallSpeed
    }

    func tileHeight(_ tile: LiveTile) -> Double {
        // 82 % of the tile's duration in screen-distance gives a slight gap
        // between consecutive quarter-note tiles so they read as separate.
        tile.noteDuration * song.beatDuration * fallSpeed * 0.82
    }

    // MARK: - Private

    private func spawnTiles() {
        while nextEventIdx < song.events.count {
            let event  = song.events[nextEventIdx]
            let absTarget = (event.beat + loopOffset) * song.beatDuration
            let spawnAt   = absTarget - spawnLeadTime
            guard songTime >= spawnAt else { break }
            activeTiles.append(LiveTile(
                lane: event.lane,
                noteDuration: event.duration,
                absoluteTargetTime: absTarget
            ))
            nextEventIdx += 1
        }
    }

    private func processCollisions(joints: [VisionJoint]) {
        let laneW = 1.0 / Double(laneCount)

        for i in activeTiles.indices where activeTiles[i].state == .active {
            let topY   = tileTopY(activeTiles[i])
            let height = tileHeight(activeTiles[i])
            let lane   = activeTiles[i].lane

            // Miss: leading edge past bottom
            if topY > 1.04 {
                activeTiles[i].state     = .missed
                activeTiles[i].missedTime = songTime
                combo = 0
                totalMisses += 1
                notePlayer.playGhost(lane: lane)
                continue
            }

            // Hit: any confident joint inside the tile rect
            let laneMinX = Double(lane) * laneW
            let laneMaxX = laneMinX + laneW

            for joint in joints where joint.confidence >= 0.30 {
                // Flip x when mirrored so lane checks match the visual display.
                let jx = isMirrored ? 1.0 - Double(joint.point.x) : Double(joint.point.x)
                let jy = 1.0 - Double(joint.point.y)   // Vision y → top-left UV y

                guard jx >= laneMinX, jx <= laneMaxX,
                      jy >= topY,     jy <= topY + height
                else { continue }

                // Timing accuracy: how close to the "perfect" beat moment
                let timingErr = abs(songTime - activeTiles[i].absoluteTargetTime)
                let accuracy  = max(0.3, 1.0 - timingErr * 1.2)
                let comboBonus = min(combo / 5, 8)
                let pts = Int(Double(100) * accuracy) * (1 + comboBonus)

                activeTiles[i].state   = .hit
                activeTiles[i].hitTime = songTime
                score      += pts
                combo      += 1
                totalHits  += 1

                notePlayer.play(lane: lane, velocity: UInt8(62 + Int(accuracy * 32)))
                break   // one joint hit is enough
            }
        }
    }

    private func pruneTiles() {
        activeTiles.removeAll { tile in
            switch tile.state {
            case .active:  return false
            case .hit:     return songTime - (tile.hitTime    ?? songTime) > 0.55
            case .missed:  return songTime - (tile.missedTime ?? songTime) > 0.75
            }
        }
    }

    private func advanceLoop() {
        guard nextEventIdx >= song.events.count else { return }
        // song.totalDuration is in seconds; convert to beats for loopOffset arithmetic.
        let totalBeats = song.totalDuration / song.beatDuration
        // Absolute seconds when the full loop has played out.
        let loopEndSeconds = (loopOffset + totalBeats) * song.beatDuration
        guard songTime >= loopEndSeconds - 1.0 else { return }
        loopOffset   += totalBeats
        nextEventIdx  = 0
    }
}
