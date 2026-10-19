//
//  ClaudeActivitySummary.swift
//  boringNotch
//

import Defaults
import Foundation

/// When the closed notch shows the Claude Code activity.
enum ClaudeClosedActivityMode: String, CaseIterable, Defaults.Serializable, Sendable {
    case off
    case whileWorking
    case onlyWhenNeedsYou
}

/// A short-lived moment shown on top of the steady state: a "needs you" peek or the done flash.
struct ClaudeTransient: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A session started waiting for a permission decision.
        case peek(sessionID: String)
        /// The last working session finished its turn.
        case doneFlash
    }

    let kind: Kind
    let expiresAt: Date

    static let duration: TimeInterval = 4
}

/// Everything the closed notch needs to draw the aggregated Claude Code activity.
/// Deliberately coarse (no tool names, no timestamps) so it only changes when the drawing changes.
struct ClaudeActivitySummary: Equatable, Sendable {
    enum Look: Equatable, Sendable {
        case working
        case needsYou
        case done
    }

    struct Peek: Equatable, Sendable {
        let projectName: String
    }

    let look: Look
    /// Sessions that are working or need the user.
    let count: Int
    let peek: Peek?
    /// Incremented by the manager on every attention moment; a change brings the activity to the front.
    let attentionToken: Int

    /// Urgent activities go in front of music whatever the ordering setting.
    var isUrgent: Bool { look != .working || peek != nil }

    static func make(
        sessions: [ClaudeSession],
        transient: ClaudeTransient?,
        mode: ClaudeClosedActivityMode,
        attentionToken: Int
    ) -> ClaudeActivitySummary? {
        guard mode != .off else { return nil }

        let needingYou = sessions.filter { $0.state == .needsPermission }
        let working = mode == .whileWorking ? sessions.filter { $0.state.isActive } : []
        let count = needingYou.count + working.count

        var peek: Peek?
        if case .peek(let sessionID) = transient?.kind,
           let session = needingYou.first(where: { $0.id == sessionID }) {
            peek = Peek(projectName: session.projectName)
        }

        let look: Look
        if !needingYou.isEmpty {
            look = .needsYou
        } else if !working.isEmpty {
            look = .working
        } else if transient?.kind == .doneFlash && mode == .whileWorking {
            look = .done
        } else {
            return nil
        }

        return ClaudeActivitySummary(look: look, count: count, peek: peek, attentionToken: attentionToken)
    }
}

/// Moments worth an attention transient, detected by comparing session states before and after an event.
enum ClaudeActivityTransition: Equatable, Sendable {
    case startedNeedingYou(sessionID: String)
    case allFinished

    static func detect(old: [String: ClaudeSession], new: [String: ClaudeSession]) -> [ClaudeActivityTransition] {
        var transitions: [ClaudeActivityTransition] = []

        for (id, session) in new where session.state == .needsPermission && old[id]?.state != .needsPermission {
            transitions.append(.startedNeedingYou(sessionID: id))
        }

        func counts(_ session: ClaudeSession) -> Bool {
            session.state.isActive || session.state == .needsPermission
        }
        let finishedTurn = new.contains { id, session in
            session.state == .done && old[id].map(counts) == true
        }
        if finishedTurn && !new.values.contains(where: counts) {
            transitions.append(.allFinished)
        }
        return transitions
    }
}
