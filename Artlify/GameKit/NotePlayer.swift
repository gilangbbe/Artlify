//
//  NotePlayer.swift
//  Artlify / GameKit — universe-tune branch
//
//  AVAudioEngine + AVAudioUnitSampler (GM Grand Piano via the macOS
//  system DLS soundfont) + a hall reverb.  Lives independently of
//  AudioReactor — that engine taps the *input* node; this one drives
//  the *output* chain only.
//
//  Lane→MIDI mapping is provided by the active TileSong so Experience
//  and Für Elise can play completely different pitches.
//

import Foundation
import AVFoundation
import AudioToolbox
import SwiftUI

@MainActor
final class NotePlayer {

    private let laneNotes: [UInt8]    // sourced from TileSong

    private let engine  = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let reverb  = AVAudioUnitReverb()

    private(set) var isReady = false
    var isMuted: Bool = false

    init(song: TileSong) {
        self.laneNotes = song.laneNotes
        setup()
    }

    // MARK: - Public API

    /// Play a lane note at full (player-hit) velocity.
    func play(lane: Int, velocity: UInt8 = 88) {
        trigger(lane: lane, velocity: velocity, sustainSeconds: 1.8)
    }

    /// Play a lane note quietly — missed tile ghost note so the music keeps going.
    func playGhost(lane: Int) {
        trigger(lane: lane, velocity: 28, sustainSeconds: 1.2)
    }

    /// Play any arbitrary MIDI note — used for background accompaniment (arpeggios, bass).
    func playMIDI(_ note: UInt8, velocity: UInt8 = 38, durationSeconds: Double = 0.3) {
        guard isReady, !isMuted else { return }
        sampler.startNote(note, withVelocity: velocity, onChannel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds) { [weak self] in
            self?.sampler.stopNote(note, onChannel: 0)
        }
    }

    func teardown() {
        for note in laneNotes { sampler.stopNote(note, onChannel: 0) }
        if engine.isRunning { engine.stop() }
        isReady = false
    }

    func restart() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            isReady = true
        } catch {
            print("NotePlayer: engine restart failed — \(error)")
        }
    }

    // MARK: - Private

    private func setup() {
        engine.attach(sampler)
        engine.attach(reverb)
        engine.connect(sampler, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)

        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 38

        // macOS ships a General MIDI DLS bank inside CoreAudio.component.
        let dlsPath = "/System/Library/Components/CoreAudio.component" +
                      "/Contents/Resources/gs_instruments.dls"
        if FileManager.default.fileExists(atPath: dlsPath) {
            // kAUSampler_DefaultMelodicBankMSB = 0x79, bankLSB = 0x00
            try? sampler.loadSoundBankInstrument(
                at: URL(fileURLWithPath: dlsPath),
                program: 0,     // Acoustic Grand Piano
                bankMSB: 0x79,
                bankLSB: 0x00
            )
        }

        do {
            try engine.start()
            isReady = true
        } catch {
            print("NotePlayer: engine start failed — \(error)")
        }
    }

    private func trigger(lane: Int, velocity: UInt8, sustainSeconds: Double) {
        guard isReady, !isMuted, lane >= 0, lane < laneNotes.count else { return }
        let note = laneNotes[lane]
        sampler.startNote(note, withVelocity: velocity, onChannel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + sustainSeconds) { [weak self] in
            self?.sampler.stopNote(note, onChannel: 0)
        }
    }
}
