//
//  ClaudeSession.swift
//  boringNotch
//

import Foundation

/// Live state of one Claude Code session, rebuilt from hook events. Never persisted.
struct ClaudeSession: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        /// Session started, no prompt yet.
        case idle
        case working
        case runningTool
        case needsPermission
        case waitingForInput
        case done
        case error
        case compacting
        /// No event for a while during an active state (e.g. the user pressed Esc, which fires no hook).
        case stale
        case ended

        var isActive: Bool {
            self == .working || self == .runningTool || self == .compacting
        }

        var needsAttention: Bool {
            self == .needsPermission || self == .waitingForInput
        }
    }

    let id: String
    var cwd: String?
    var state: State
    var currentTool: String?
    var permissionMode: String?
    let startedAt: Date
    var lastEventAt: Date
    var stateChangedAt: Date

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

extension ClaudeSession {
    /// Applies one hook event. Pure, so the state machine can be unit-tested.
    static func reduce(_ session: ClaudeSession?, with event: ClaudeHookEvent, at now: Date) -> ClaudeSession {
        var session = session ?? ClaudeSession(
            id: event.sessionID,
            state: .idle,
            startedAt: now,
            lastEventAt: now,
            stateChangedAt: now
        )
        session.lastEventAt = now
        if let cwd = event.cwd { session.cwd = cwd }
        if let mode = event.permissionMode { session.permissionMode = mode }

        func transition(to state: State, tool: String? = nil) {
            if session.state != state { session.stateChangedAt = now }
            session.state = state
            session.currentTool = tool
        }

        switch event.kind {
        case .sessionStart:
            transition(to: .idle)
        case .userPromptSubmit:
            transition(to: .working)
        case .preToolUse:
            transition(to: .runningTool, tool: event.toolName)
        case .postToolUse, .postToolUseFailure:
            // Background tools can report after Stop; that must not revive a finished turn.
            if session.state.isActive || session.state == .needsPermission || session.state == .stale {
                transition(to: .working)
            }
        case .permissionRequest:
            transition(to: .needsPermission, tool: event.toolName ?? session.currentTool)
        case .notification:
            switch event.notificationType {
            case "permission_prompt":
                transition(to: .needsPermission, tool: session.currentTool)
            case "idle_prompt":
                transition(to: .waitingForInput)
            default:
                break
            }
        case .stop:
            transition(to: .done)
        case .stopFailure:
            transition(to: .error)
        case .preCompact:
            transition(to: .compacting)
        case .sessionEnd:
            transition(to: .ended)
        case .other:
            break
        }
        return session
    }

    /// Order for display: sessions that need the user first, then active ones, then the rest; newest first within each group.
    static func displayOrder(_ lhs: ClaudeSession, _ rhs: ClaudeSession) -> Bool {
        func rank(_ state: State) -> Int {
            if state.needsAttention { return 0 }
            if state.isActive { return 1 }
            return 2
        }
        let (left, right) = (rank(lhs.state), rank(rhs.state))
        if left != right { return left < right }
        return lhs.lastEventAt > rhs.lastEventAt
    }
}
