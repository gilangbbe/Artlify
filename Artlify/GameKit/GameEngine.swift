//
//  GameEngine.swift
//  Artlify / GameKit
//
//  Central @Observable game object. Owns the state machine, score,
//  star-dust count, obstacle list, and the two child systems:
//
//    BodyController   — converts Vision joints → jump/duck/stand
//    ObstacleSpawner  — timed drip of rocks / meteors / star-dust
//    CollisionSystem  — zone-based rect intersection → hit / collected
//
//  The tick loop runs at ~60 Hz via a @MainActor Task, moving obstacles
//  and spawning new ones. Collision is checked separately, driven by the
//  Vision frame cadence (~15 Hz) from ContentView's onChange handler.
//  Both paths run on @MainActor so there are no data races.
//

import Foundation
import Observation
import OSLog

enum GameState: Equatable {
    case idle
    case countdown(Int)   // 3 → 2 → 1
    case playing
    case gameOver
}

@MainActor
@Observable
final class GameEngine {

    private let log = Logger(subsystem: "com.biru.Artlify", category: "GameKit")

    // MARK: - Observed state

    private(set) var gameState    : GameState = .idle
    private(set) var starDust     : Int = 1
    private(set) var score        : Int = 0
    private(set) var highScore    : Int = UserDefaults.standard.integer(forKey: "astro.highScore")
    private(set) var obstacles    : [GameObstacle] = []
    /// Kind of the obstacle that caused the last life loss (shown in the game-over panel).
    private(set) var killedByKind : ObstacleKind? = nil

    // MARK: - Child systems

    let body = BodyController()

    // MARK: - Callbacks (wired by ContentView)

    /// Fires with the UV centre of the hit obstacle — triggers renderer effects.
    var onHit     : ((SIMD2<Float>) -> Void)?
    /// Fires with the UV centre of the collected star-dust.
    var onCollect : ((SIMD2<Float>) -> Void)?

    // MARK: - Private

    private var spawner         = ObstacleSpawner()
    private var elapsedSeconds  : Double = 0
    private var lastVisionTime  : CFAbsoluteTime = 0
    private var gameLoopTask    : Task<Void, Never>?
    private var countdownTask   : Task<Void, Never>?

    // MARK: - Public API

    func startCountdown() {
        guard gameState == .idle || gameState == .gameOver else { return }
        reset()
        countdownTask = Task { [weak self] in
            for n in [3, 2, 1] {
                guard !Task.isCancelled, let self else { return }
                self.gameState = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self else { return }
            self.gameState = .playing
            self.startGameLoop()
        }
    }

    func stop() {
        gameLoopTask?.cancel();  gameLoopTask  = nil
        countdownTask?.cancel(); countdownTask = nil
        gameState = .idle
    }

    /// Feed every Vision frame here. Drives body-state, obstacle movement,
    /// spawning, and collision — all locked to the camera segmentation cadence.
    func update(frame: VisionFrame) {
        body.update(frame: frame)
        guard gameState == .playing else { return }

        // Compute dt from the previous Vision frame so obstacle speed is
        // independent of the actual Vision Hz (typically ~15 Hz).
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = lastVisionTime > 0 ? min(now - lastVisionTime, 0.15) : 0
        lastVisionTime = now

        if dt > 0 { tickObstacles(dt: dt) }

        CollisionSystem.resolve(
            obstacles: &obstacles,
            mask:      frame.personMask,
            bodyRect:  body.bodyRect,
            bodyState: body.state
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - Private

    private func reset() {
        gameLoopTask?.cancel();  gameLoopTask  = nil
        countdownTask?.cancel(); countdownTask = nil
        obstacles      = []
        spawner        = ObstacleSpawner()
        elapsedSeconds = 0
        lastVisionTime = 0
        starDust       = 1
        score          = 0
        killedByKind   = nil
        body.reset()
    }

    private func startGameLoop() {
        // Game loop only tracks elapsed time and score — obstacle movement
        // is driven by Vision frames in update(frame:) instead.
        gameLoopTask = Task { [weak self] in
            var last = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.gameState == .playing else { break }
                let now = CFAbsoluteTimeGetCurrent()
                let dt  = min(now - last, 0.05)
                self.elapsedSeconds += dt
                let timePart = Int(self.elapsedSeconds * 10)
                if timePart > self.score { self.score = timePart }
                last = now
            }
        }
    }

    /// Move, spawn, and purge obstacles — called once per Vision frame.
    private func tickObstacles(dt: Double) {
        let speedMult      = 1.0 + floor(elapsedSeconds / 15.0) * 0.08
        let hasObstacle = !obstacles.isEmpty

        spawner.tick(dt: dt, elapsed: elapsedSeconds, speedMult: speedMult,
                     hasObstacle: hasObstacle) { [weak self] obs in
            self?.obstacles.append(obs)
        }

        for i in obstacles.indices {
            obstacles[i].x += Float(Double(obstacles[i].speed) * speedMult * dt)
        }

        obstacles.removeAll { $0.x > 1.05 || $0.consumed }
    }

    private func handle(_ event: CollisionEvent) {
        switch event.kind {
        case .hit:
            onHit?(event.center)
            killedByKind = event.obstacleKind
            starDust -= 1
            log.info("Hit! starDust=\(self.starDust)")
            if starDust <= 0 {
                starDust = 0
                endGame()
            }
        case .collected:
            onCollect?(event.center)
            starDust += 1
            score    += 50
            log.info("Collected star-dust. starDust=\(self.starDust) score=\(self.score)")
        }
    }

    private func endGame() {
        gameLoopTask?.cancel(); gameLoopTask = nil
        if score > highScore {
            highScore = score
            UserDefaults.standard.set(highScore, forKey: "astro.highScore")
        }
        gameState = .gameOver
        log.info("Game over. score=\(self.score) highScore=\(self.highScore)")
    }
}
