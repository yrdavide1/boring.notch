//
//  PixelMascot.swift
//  boringNotch
//

import SwiftUI

/// Retro pixel-art take on the Claude Code mascot, drawn from character grids.
/// Cells are snapped to whole device pixels and drawn without antialiasing, so it stays crisp at ~20 pt.
struct PixelMascot: View {
    enum Pose {
        case standing
        case armsUp
    }

    /// `#` body, `o` eye, `.` empty. All rows of all poses have the same width.
    static let sprites: [Pose: [String]] = [
        .standing: [
            "..#######..",
            "..#o###o#..",
            "###########",
            "..#######..",
            "..#######..",
            "..#.#.#.#..",
            "..#.#.#.#..",
        ],
        .armsUp: [
            "#.#######.#",
            "#.#o###o#.#",
            "###########",
            "..#######..",
            "..#######..",
            "..#.#.#.#..",
            "..#.#.#.#..",
        ],
    ]

    static let columns = 11
    /// One spare row above the sprite leaves room for the bob.
    static let rows = 8
    static let coral = Color(red: 0.85, green: 0.47, blue: 0.34)

    let pose: Pose
    var tint: Color = Self.coral
    /// Bobs at 4 fps while true. Callers turn it off when Reduce Motion is on.
    var bobbing: Bool = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !bobbing)) { context in
            let raised = bobbing && Int(context.date.timeIntervalSinceReferenceDate * 4) % 2 == 0
            Canvas { canvas, size in
                draw(in: &canvas, size: size, raised: raised)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, raised: Bool) {
        guard let sprite = Self.sprites[pose] else { return }
        let scale = max(displayScale, 1)
        let cellPixels = max(1, floor(min(size.width / CGFloat(Self.columns), size.height / CGFloat(Self.rows)) * scale))
        let cell = cellPixels / scale

        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let originX = snapped((size.width - cell * CGFloat(Self.columns)) / 2)
        let originY = snapped((size.height - cell * CGFloat(Self.rows)) / 2)
        let rowOffset = raised ? 0 : 1

        for (row, line) in sprite.enumerated() {
            for (column, character) in line.enumerated() {
                let color: Color
                switch character {
                case "#": color = tint
                case "o": color = .black
                default: continue
                }
                let rect = CGRect(
                    x: originX + CGFloat(column) * cell,
                    y: originY + CGFloat(row + rowOffset) * cell,
                    width: cell,
                    height: cell
                )
                canvas.fill(Path(rect), with: .color(color), style: FillStyle(antialiased: false))
            }
        }
    }
}

/// Three small bars, the Claude Code counterpart of the music spectrogram. Not audio-driven.
struct ClaudeActivityBars: View {
    var animates: Bool
    var color: Color = PixelMascot.coral

    private static let pattern: [[CGFloat]] = [
        [0.4, 1.0, 0.6],
        [0.8, 0.5, 1.0],
        [1.0, 0.7, 0.4],
        [0.6, 0.9, 0.7],
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !animates)) { context in
            let frame = animates ? Int(context.date.timeIntervalSinceReferenceDate * 4) % Self.pattern.count : 0
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 12 * Self.pattern[frame][index])
                }
            }
            .animation(.easeInOut(duration: 0.2), value: frame)
        }
        .frame(width: 13, height: 12)
        .accessibilityHidden(true)
    }
}
