//
//  ClaudeLiveActivity.swift
//  boringNotch
//

import SwiftUI

/// Closed-notch activity for all Claude Code sessions: the mascot on the left of the
/// camera cutout, a count or state glyph on the right, and a project-name peek when
/// a session starts waiting for a permission decision.
struct ClaudeLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let summary: ClaudeActivitySummary

    static let peekLabelWidth: CGFloat = 110
    private static let spacing: CGFloat = 8

    /// Width this view adds beyond the closed notch; `computedChinWidth` uses it so the
    /// hover region matches what is drawn.
    static func extraChinWidth(itemSize: CGFloat, showsPeek: Bool) -> CGFloat {
        2 * itemSize + 20 + (showsPeek ? 2 * (peekLabelWidth + spacing) : 0)
    }

    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity = 0.0

    private var itemSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            PixelMascot(
                pose: summary.look == .working ? .standing : .armsUp,
                tint: summary.look == .needsYou ? .orange : PixelMascot.coral,
                bobbing: summary.look == .working && !reduceMotion
            )
            .frame(width: itemSize, height: itemSize)

            if let peek = summary.peek {
                Text(peek.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.peekLabelWidth, alignment: .leading)
            }

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            if summary.peek != nil {
                Text("Needs permission")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .frame(width: Self.peekLabelWidth, alignment: .trailing)
            }

            trailing
                .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .animation(.smooth(duration: 0.3), value: summary.peek)
        .onAppear { pulseIfNeeded() }
        .onChange(of: summary.attentionToken) { _, _ in pulseIfNeeded() }
    }

    @ViewBuilder
    private var trailing: some View {
        switch summary.look {
        case .needsYou:
            ZStack {
                Circle()
                    .stroke(Color.orange, lineWidth: 1.5)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                Text(summary.count > 1 ? "\(summary.count)" : "!")
                    .font(.system(size: 13, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.orange)
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.green)
        case .working:
            if summary.count > 1 {
                Text("\(summary.count)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(PixelMascot.coral)
            } else {
                ClaudeActivityBars(animates: !reduceMotion)
            }
        }
    }

    private func pulseIfNeeded() {
        guard summary.look == .needsYou, !reduceMotion else { return }
        ringScale = 1
        ringOpacity = 0.8
        withAnimation(.easeOut(duration: 0.6)) {
            ringScale = 1.8
            ringOpacity = 0
        }
    }
}
