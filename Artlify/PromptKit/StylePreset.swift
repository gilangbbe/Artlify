//
//  StylePreset.swift
//  Artlify / PromptKit
//
//  A small curated library of style presets for v1. Each preset is a
//  base prompt + suggested defaults for the diffusion strength and
//  step count so the user gets a coherent look in one click.
//
//  Kept hand-tuned and intentionally short (≤ 8 entries) — every
//  preset must look distinct in 2 steps at strength ~0.55. If a
//  preset can't survive that, we cut it.
//

import Foundation

public struct StylePreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let symbol: String       // SF Symbol
    public let basePrompt: String
    public let suggestedSteps: Int
    public let suggestedStrength: Float

    public init(id: String, name: String, symbol: String,
                basePrompt: String,
                suggestedSteps: Int = 4,
                suggestedStrength: Float = 0.78) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.basePrompt = basePrompt
        self.suggestedSteps = suggestedSteps
        self.suggestedStrength = suggestedStrength
    }
}

public enum StylePresets {
    public static let all: [StylePreset] = [
        StylePreset(
            id: "oil",
            name: "Oil paint",
            symbol: "paintbrush",
            basePrompt: "oil painting, swirling brushstrokes, vivid colors, thick impasto, museum lighting",
            suggestedStrength: 0.78
        ),
        StylePreset(
            id: "watercolor",
            name: "Watercolor",
            symbol: "drop",
            basePrompt: "watercolor painting on cold-press paper, soft washes, bleeding edges, pastel palette",
            suggestedStrength: 0.75
        ),
        StylePreset(
            id: "ink",
            name: "Ink wash",
            symbol: "scribble",
            basePrompt: "japanese sumi-e ink wash on rice paper, monochrome, expressive brushwork, negative space",
            suggestedStrength: 0.82
        ),
        StylePreset(
            id: "pixel",
            name: "Pixel art",
            symbol: "square.grid.3x3.fill",
            basePrompt: "16-bit pixel art, limited palette, dithering, sharp edges, retro game aesthetic",
            suggestedStrength: 0.80
        ),
        StylePreset(
            id: "comic",
            name: "Comic ink",
            symbol: "rectangle.split.2x2",
            basePrompt: "graphic novel ink and color, bold outlines, halftone shading, dramatic lighting",
            suggestedStrength: 0.78
        ),
        StylePreset(
            id: "neon",
            name: "Neon noir",
            symbol: "moon.stars",
            basePrompt: "cyberpunk neon noir portrait, magenta and cyan rim light, rain-slicked surfaces, cinematic",
            suggestedStrength: 0.82
        ),
        StylePreset(
            id: "lowpoly",
            name: "Low-poly",
            symbol: "triangle",
            basePrompt: "low-poly 3D render, faceted geometry, flat shading, pastel gradient background",
            suggestedStrength: 0.80
        ),
        StylePreset(
            id: "charcoal",
            name: "Charcoal",
            symbol: "pencil.tip",
            basePrompt: "expressive charcoal drawing on toned paper, smudged shadows, white highlights, gestural strokes",
            suggestedStrength: 0.78
        ),
    ]

    public static func first() -> StylePreset { all[0] }
}
