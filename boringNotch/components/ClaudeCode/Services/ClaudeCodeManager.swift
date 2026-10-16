//
//  ClaudeCodeManager.swift
//  boringNotch
//

import Combine
import Defaults
import Foundation

/// Owns the Claude Code listener and the live session list. Started and stopped by
/// `BoringViewCoordinator` from the `claudeCodeEnabled` setting.
@MainActor
final class ClaudeCodeManager: ObservableObject {
    static let shared = ClaudeCodeManager()

    /// Sorted for display: sessions needing the user first.
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var status: ClaudeCodeListener.Status = .stopped
    @Published private(set) var lastEventAt: Date?

    /// How long an ended session stays visible.
    static let endedRetention: TimeInterval = 10
    /// Sessions with no event for this long are dropped, whatever their state.
    static let maximumIdle: TimeInterval = 2 * 60 * 60
    private static let sweepInterval: Duration = .seconds(15)

    private var sessionsByID: [String: ClaudeSession] = [:]
    private var sweepTask: Task<Void, Never>?
    private lazy var listener = ClaudeCodeListener(
        onEvent: { event in
            Task { @MainActor in ClaudeCodeManager.shared.handle(event) }
        },
        onStatus: { status in
            Task { @MainActor in ClaudeCodeManager.shared.status = status }
        }
    )

    private init() {}

    func start() {
        listener.start()
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sweepInterval)
                self?.sweep(now: .now)
            }
        }
    }

    func stop() {
        listener.stop()
        sweepTask?.cancel()
        sweepTask = nil
        sessionsByID.removeAll()
        publish()
    }

    func handle(_ event: ClaudeHookEvent, at now: Date = .now) {
        sessionsByID[event.sessionID] = ClaudeSession.reduce(sessionsByID[event.sessionID], with: event, at: now)
        lastEventAt = now
        publish()
    }

    /// Marks quiet active sessions as stale and drops ended or long-idle ones.
    func sweep(now: Date) {
        let staleAfter = TimeInterval(Defaults[.claudeCodeStaleMinutes] * 60)
        for (id, session) in sessionsByID {
            let quiet = now.timeIntervalSince(session.lastEventAt)
            if session.state == .ended && now.timeIntervalSince(session.stateChangedAt) >= Self.endedRetention
                || quiet >= Self.maximumIdle {
                sessionsByID[id] = nil
            } else if session.state.isActive && quiet >= staleAfter {
                sessionsByID[id]?.state = .stale
                sessionsByID[id]?.stateChangedAt = now
            }
        }
        publish()
    }

    private func publish() {
        let sorted = sessionsByID.values.sorted(by: ClaudeSession.displayOrder)
        if sorted != sessions { sessions = sorted }
    }
}
