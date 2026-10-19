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
    /// What the closed notch draws. Assigned only when it changes, so observers that
    /// mirror just this value don't re-render on every hook event.
    @Published private(set) var activitySummary: ClaudeActivitySummary?

    /// How long an ended session stays visible.
    static let endedRetention: TimeInterval = 10
    /// Sessions with no event for this long are dropped, whatever their state.
    static let maximumIdle: TimeInterval = 2 * 60 * 60
    private static let sweepInterval: Duration = .seconds(15)

    private var sessionsByID: [String: ClaudeSession] = [:]
    private var sweepTask: Task<Void, Never>?
    private var transient: ClaudeTransient?
    private var transientTask: Task<Void, Never>?
    private var attentionToken = 0
    private var settingsCancellable: AnyCancellable?
    private lazy var listener = ClaudeCodeListener(
        onEvent: { event in
            Task { @MainActor in ClaudeCodeManager.shared.handle(event) }
        },
        onStatus: { status in
            Task { @MainActor in ClaudeCodeManager.shared.status = status }
        }
    )

    private init() {
        settingsCancellable = Defaults.publisher(.claudeCodeClosedActivity, options: [])
            .sink { _ in Task { @MainActor in ClaudeCodeManager.shared.publish() } }
    }

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
        setTransient(nil)
        sessionsByID.removeAll()
        publish()
    }

    func handle(_ event: ClaudeHookEvent, at now: Date = .now) {
        let old = sessionsByID
        sessionsByID[event.sessionID] = ClaudeSession.reduce(sessionsByID[event.sessionID], with: event, at: now)
        lastEventAt = now

        for transition in ClaudeActivityTransition.detect(old: old, new: sessionsByID) {
            switch transition {
            case .startedNeedingYou(let sessionID):
                setTransient(ClaudeTransient(kind: .peek(sessionID: sessionID), expiresAt: now + ClaudeTransient.duration))
                attentionToken += 1
            case .allFinished where Defaults[.claudeCodeClosedActivity] == .whileWorking:
                setTransient(ClaudeTransient(kind: .doneFlash, expiresAt: now + ClaudeTransient.duration))
                attentionToken += 1
            case .allFinished:
                break
            }
        }
        // Work resumed: the done flash is over.
        if transient?.kind == .doneFlash,
           sessionsByID.values.contains(where: { $0.state.isActive || $0.state == .needsPermission }) {
            setTransient(nil)
        }
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
            } else if (session.state.isActive || session.state == .needsPermission) && quiet >= staleAfter {
                // Esc fires no hook, so a cancelled turn or permission prompt would otherwise stay forever.
                sessionsByID[id]?.state = .stale
                sessionsByID[id]?.stateChangedAt = now
            }
        }
        publish()
    }

    private func publish() {
        let sorted = sessionsByID.values.sorted(by: ClaudeSession.displayOrder)
        if sorted != sessions { sessions = sorted }

        let summary = ClaudeActivitySummary.make(
            sessions: sorted,
            transient: transient,
            mode: Defaults[.claudeCodeClosedActivity],
            attentionToken: attentionToken
        )
        if summary != activitySummary { activitySummary = summary }
    }

    /// Replaces the transient and schedules its expiry; one Task at a time.
    private func setTransient(_ newValue: ClaudeTransient?) {
        transientTask?.cancel()
        transientTask = nil
        transient = newValue
        guard let newValue else { return }
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, newValue.expiresAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.transient == newValue else { return }
            self.transient = nil
            self.publish()
        }
    }
}
