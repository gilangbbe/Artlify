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
    var autoPlayed: Bool = false   // ghost note already fired for this tile
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
    private(set) var isGameOver: Bool = false
    private(set) var isSongComplete: Bool = false

    // ---- Constants
    let fallSpeed: Double = 0.22    // UV per second
    let hitZoneY:  Double = 0.72    // target y at note's beat time
    let laneCount: Int    = 4

    /// Leave false when the overlay canvas is inside a scaleEffect(x:-1)
    /// group — the tile coordinates and joint coordinates are already in
    /// the same flipped space, so no additional x-flip is needed.
    var isMirrored: Bool = false

    // ---- Dependencies
    let song: TileSong
    let notePlayer: NotePlayer

    // ---- Private state
    private var startTime: CFAbsoluteTime = 0
    private var loopOffset: Double = 0     // running beat offset across loops
    private var nextEventIdx: Int = 0

    // Joint interpolation: store two consecutive Vision snapshots so we can
    // LERP body positions at 60 Hz even when Vision fires at ~30 Hz.
    private var prevJoints: [VisionJoint] = []
    private var currJoints: [VisionJoint] = []
    private var prevJointTime: Double = 0
    private var currJointTime: Double = 0

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
        isPlaying      = true
        isGameOver     = false
        isSongComplete = false
        // Offset startTime into the future by spawnLeadTime so songTime
        // begins at -spawnLeadTime. The first beat-0 tile then spawns
        // immediately but at y = spawnLeadY (off-screen top) and falls
        // into view naturally, rather than appearing at hitZoneY.
        startTime  = CFAbsoluteTimeGetCurrent() + spawnLeadTime
        loopOffset = 0
        nextEventIdx = 0
        activeTiles = []
        score = 0; combo = 0; totalHits = 0; totalMisses = 0
        prevJoints = []; currJoints = []
        prevJointTime = 0; currJointTime = 0
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
    /// `jointTimestamp` is the CFAbsoluteTime of the Vision frame that
    /// produced `joints`; used to LERP positions between Vision frames.
    func update(joints: [VisionJoint], jointTimestamp: CFAbsoluteTime = 0) {
        guard isPlaying, !isGameOver else { return }
        songTime = CFAbsoluteTimeGetCurrent() - startTime

        // Detect a fresh Vision frame by comparing its absolute timestamp.
        if jointTimestamp > currJointTime + 0.001 {
            prevJoints    = currJoints
            prevJointTime = currJointTime
            currJoints    = joints
            currJointTime = jointTimestamp
        }

        spawnTiles()
        processCollisions()
        pruneTiles()
        checkSongEnd()
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

    /// Returns interpolated (x, y) in UV top-left coords for a joint,
    /// blending between the two most recent Vision snapshots so that
    /// body position tracks smoothly at 60 Hz even when Vision fires
    /// at ~30 Hz.  Falls back to the raw position when no prev snapshot
    /// exists yet.
    private func interpolatedPosition(for joint: VisionJoint) -> (x: Double, y: Double) {
        let rawX = Double(joint.point.x)
        let rawY = 1.0 - Double(joint.point.y)   // Vision bottom-left → UV top-left

        guard !prevJoints.isEmpty,
              currJointTime > prevJointTime + 0.001
        else { return (rawX, rawY) }

        // Find the matching joint in the previous snapshot by ID.
        guard let prev = prevJoints.first(where: { $0.id == joint.id }) else {
            return (rawX, rawY)
        }

        let span = currJointTime - prevJointTime
        let now  = CFAbsoluteTimeGetCurrent()
        // How far past currJointTime are we? Clamp [0,1] so we don't
        // extrapolate beyond the next expected Vision frame.
        let alpha = min(1.0, max(0.0, (now - currJointTime) / span))

        let prevX = Double(prev.point.x)
        let prevY = 1.0 - Double(prev.point.y)

        return (prevX + (rawX - prevX) * alpha,
                prevY + (rawY - prevY) * alpha)
    }

    // Joint IDs that belong to the head region in VNHumanBodyPoseObservation.
    private static let headJointTokens = ["nose", "eye", "ear", "neck"]

    private func isHeadJoint(_ id: String) -> Bool {
        Self.headJointTokens.contains(where: { id.localizedCaseInsensitiveContains($0) })
    }

    /// UV position of the head centroid, computed from all sufficiently
    /// confident head-region joints.  Returns nil when no head is visible.
    private func headCenter() -> (x: Double, y: Double)? {
        let headJoints = currJoints.filter { isHeadJoint($0.id) && $0.confidence >= 0.15 }
        guard !headJoints.isEmpty else { return nil }
        var sx = 0.0, sy = 0.0
        for j in headJoints {
            let (rx, ry) = interpolatedPosition(for: j)
            sx += rx; sy += ry
        }
        let n = Double(headJoints.count)
        let rawX = sx / n
        return (x: isMirrored ? 1.0 - rawX : rawX, y: sy / n)
    }

    private func processCollisions() {
        let laneW = 1.0 / Double(laneCount)
        // Pre-compute head centre once per tick (cheaper than per-tile).
        let head = headCenter()

        for i in activeTiles.indices where activeTiles[i].state == .active {
            let topY   = tileTopY(activeTiles[i])
            let height = tileHeight(activeTiles[i])
            let lane   = activeTiles[i].lane

            // Miss: leading edge past bottom → game over
            if topY > 1.04 {
                activeTiles[i].state      = .missed
                activeTiles[i].missedTime = songTime
                combo = 0
                totalMisses += 1
                notePlayer.playGhost(lane: lane)
                isGameOver = true
                return   // stop processing remaining tiles this tick
            }

            let laneMinX = Double(lane) * laneW
            let laneMaxX = laneMinX + laneW

            var didHit = false

            // Body joints: exact point-in-rect check.
            for joint in currJoints where !isHeadJoint(joint.id) && joint.confidence >= 0.30 {
                let (rawJx, jy) = interpolatedPosition(for: joint)
                let jx = isMirrored ? 1.0 - rawJx : rawJx
                guard jx >= laneMinX, jx <= laneMaxX,
                      jy >= topY,     jy <= topY + height
                else { continue }
                didHit = true
                break
            }

            // Head: centroid with a horizontal padding so you don't need
            // pixel-perfect lane alignment.  ±4 % UV ≈ one finger-width.
            if !didHit, let (hx, hy) = head {
                let pad = 0.04
                if hx >= laneMinX - pad, hx <= laneMaxX + pad,
                   hy >= topY,           hy <= topY + height {
                    didHit = true
                }
            }

            // Auto-play: fire a quiet ghost note once the beat passes so
            // the melody is always audible even on a miss.
            if !didHit {
                if !activeTiles[i].autoPlayed,
                   songTime > activeTiles[i].absoluteTargetTime + 0.05 {
                    activeTiles[i].autoPlayed = true
                    notePlayer.playGhost(lane: lane)
                }
                continue
            }

            // Timing accuracy: how close to the "perfect" beat moment
            let timingErr  = abs(songTime - activeTiles[i].absoluteTargetTime)
            let accuracy   = max(0.3, 1.0 - timingErr * 1.2)
            let comboBonus = min(combo / 5, 8)
            let pts = Int(Double(100) * accuracy) * (1 + comboBonus)

            activeTiles[i].state   = .hit
            activeTiles[i].hitTime = songTime
            score      += pts
            combo      += 1
            totalHits  += 1

            notePlayer.play(lane: lane, velocity: UInt8(62 + Int(accuracy * 32)))
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

    private func checkSongEnd() {
        // All events must have been spawned...
        guard nextEventIdx >= song.events.count else { return }
        // ...and every tile resolved (hit tiles are pruned after 0.55 s,
        // missed tiles trigger isGameOver before we get here, so an empty
        // activeTiles array here means a perfect clear).
        guard activeTiles.isEmpty else { return }
        isSongComplete = true
        isPlaying      = false
    }
}
