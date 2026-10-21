//
//  ClaudeCodeView.swift
//  boringNotch
//

import SwiftUI

/// Notch tab listing live Claude Code sessions, under the subscription limits when known.
struct ClaudeCodeView: View {
    @ObservedObject private var manager = ClaudeCodeManager.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.04))
            .overlay {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 0) {
                        let limits = manager.limits.current(at: context.date)
                        if !limits.isEmpty {
                            ClaudeLimitsHeader(limits: limits, now: context.date)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                        }
                        if manager.sessions.isEmpty {
                            emptyState
                                .frame(maxHeight: .infinity)
                        } else {
                            sessionList(now: context.date)
                        }
                    }
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)
            Text(manager.lastEventAt == nil
                 ? "Waiting for Claude Code. Install the plugin from Settings › Claude Code."
                 : "No Claude Code sessions")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func sessionList(now: Date) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(manager.sessions) { session in
                    ClaudeSessionRow(
                        session: session,
                        usage: manager.usage[session.id],
                        contextPercentage: manager.contextPercentage[session.id],
                        now: now
                    )
                }
            }
            .padding(6)
        }
    }
}

/// 5-hour and weekly usage bars.
private struct ClaudeLimitsHeader: View {
    let limits: ClaudeLimits
    let now: Date

    var body: some View {
        HStack(spacing: 18) {
            if let fiveHour = limits.fiveHour {
                ClaudeLimitBar(label: String(localized: "5h", comment: "Claude Code 5-hour usage limit, short label"), window: fiveHour, now: now)
            }
            if let sevenDay = limits.sevenDay {
                ClaudeLimitBar(label: String(localized: "7d", comment: "Claude Code weekly usage limit, short label"), window: sevenDay, now: now)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ClaudeLimitBar: View {
    let label: String
    let window: ClaudeLimitWindow
    let now: Date

    private static let barWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.gray)
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: Self.barWidth, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: Self.barWidth * min(1, max(0, window.usedPercentage / 100)))
                }
            Text(ClaudeLimits.percentText(window.usedPercentage))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(window.severity == .normal ? Color.white : color)
            Text(detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch window.severity {
        case .normal: .white
        case .high: .orange
        case .critical: .red
        }
    }

    private var detail: String {
        String(
            localized: "resets in \(ClaudeLimits.durationText(window.resetsAt.timeIntervalSince(now)))",
            comment: "Claude Code usage limit; argument is a duration such as 2h 10m"
        )
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let usage: ClaudeUsage?
    let contextPercentage: Double?
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(session.state == .stale ? 0.4 : 1)
            Text(session.projectName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            Text(stateText)
                .font(.system(size: 12))
                .foregroundStyle(session.state.needsAttention ? Color.orange : Color.gray)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let contextPercentage {
                Text("ctx \(ClaudeLimits.percentText(contextPercentage))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(contextPercentage >= 80 ? Color.orange : Color.gray)
                    .lineLimit(1)
            }
            if let usage {
                Text("\(ClaudeUsage.tokensText(usage.totalTokens)) tok · \(ClaudeUsage.costText(usage.costUSD))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            Text(elapsed)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(session.state.needsAttention ? Color.orange.opacity(0.12) : Color.white.opacity(0.04))
        )
    }

    private var color: Color {
        switch session.state {
        case .working, .runningTool, .compacting: .green
        case .needsPermission, .waitingForInput: .orange
        case .error: .red
        case .idle, .done, .stale, .ended: .gray
        }
    }

    private var stateText: String {
        let tool = session.currentTool ?? ""
        switch session.state {
        case .idle:
            return String(localized: "Ready", comment: "Claude Code session state: started, no prompt yet")
        case .working:
            return String(localized: "Working", comment: "Claude Code session state")
        case .runningTool:
            return tool.isEmpty
                ? String(localized: "Running a tool", comment: "Claude Code session state")
                : String(localized: "Running \(tool)", comment: "Claude Code session state; argument is a tool name such as Bash")
        case .needsPermission:
            return tool.isEmpty
                ? String(localized: "Needs permission", comment: "Claude Code session state")
                : String(localized: "Needs permission: \(tool)", comment: "Claude Code session state; argument is a tool name")
        case .waitingForInput:
            return String(localized: "Waiting for you", comment: "Claude Code session state")
        case .done:
            return String(localized: "Done", comment: "Claude Code session state: turn finished")
        case .error:
            return String(localized: "Error", comment: "Claude Code session state")
        case .compacting:
            return String(localized: "Compacting", comment: "Claude Code session state")
        case .stale:
            return String(localized: "No activity", comment: "Claude Code session state: no events for a while")
        case .ended:
            return String(localized: "Ended", comment: "Claude Code session state")
        }
    }

    private var elapsed: String {
        let seconds = max(0, Int(now.timeIntervalSince(session.stateChangedAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }
}
