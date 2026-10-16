//
//  ClaudeCodeView.swift
//  boringNotch
//

import SwiftUI

/// Notch tab listing live Claude Code sessions.
struct ClaudeCodeView: View {
    @ObservedObject private var manager = ClaudeCodeManager.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.04))
            .overlay {
                if manager.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
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

    private var sessionList: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(manager.sessions) { session in
                        ClaudeSessionRow(session: session, now: context.date)
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
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
