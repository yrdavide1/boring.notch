//
//  ClaudeLimits.swift
//  boringNotch
//

import Foundation

/// The fields the app reads from the JSON Claude Code passes to the status line command.
/// Everything else in the payload (paths, model, workspace) is never decoded.
struct ClaudeStatusLine: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let usedPercentage: Double
        let resetsAt: Date
    }

    let sessionID: String?
    /// `null` early in a session and right after `/compact`.
    let contextUsedPercentage: Double?
    /// Present only for Pro and Max subscribers, after the session's first API response.
    let fiveHour: Window?
    let sevenDay: Window?

    init(sessionID: String?, contextUsedPercentage: Double?, fiveHour: Window?, sevenDay: Window?) {
        self.sessionID = sessionID
        self.contextUsedPercentage = contextUsedPercentage
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    init(from data: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        self.init(
            sessionID: payload.sessionID,
            contextUsedPercentage: payload.contextWindow?.usedPercentage,
            fiveHour: payload.rateLimits?.fiveHour?.window,
            sevenDay: payload.rateLimits?.sevenDay?.window
        )
    }

    // MARK: - Payload shape (only the fields needed; all optional)

    private struct Payload: Decodable {
        let sessionID: String?
        let contextWindow: ContextWindow?
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case contextWindow = "context_window"
            case rateLimits = "rate_limits"
        }
    }

    private struct ContextWindow: Decodable {
        let usedPercentage: Double?
        enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage" }
    }

    private struct RateLimits: Decodable {
        let fiveHour: RateWindow?
        let sevenDay: RateWindow?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct RateWindow: Decodable {
        let usedPercentage: Double?
        /// Unix epoch seconds; may carry a fraction.
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        /// A window without a reset time can't be aged out, so it's ignored.
        var window: Window? {
            guard let usedPercentage, let resetsAt else { return nil }
            return Window(usedPercentage: usedPercentage, resetsAt: Date(timeIntervalSince1970: resetsAt))
        }
    }
}

/// One subscription usage window as last reported by any Claude Code session.
struct ClaudeLimitWindow: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case normal, high, critical
    }

    let usedPercentage: Double
    let resetsAt: Date

    var severity: Severity {
        switch usedPercentage {
        case 95...: .critical
        case 80...: .high
        default: .normal
        }
    }

    func isExpired(at now: Date) -> Bool { resetsAt <= now }
}

/// 5-hour and weekly limits. They belong to the account, not a session, so the newest report wins.
struct ClaudeLimits: Equatable, Sendable {
    var fiveHour: ClaudeLimitWindow?
    var sevenDay: ClaudeLimitWindow?

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

    /// Windows in `statusLine` replace the stored ones; a missing window keeps the old value,
    /// since a new session reports no limits until its first API response.
    func merged(with statusLine: ClaudeStatusLine) -> ClaudeLimits {
        func window(_ new: ClaudeStatusLine.Window?, else old: ClaudeLimitWindow?) -> ClaudeLimitWindow? {
            guard let new else { return old }
            return ClaudeLimitWindow(usedPercentage: new.usedPercentage, resetsAt: new.resetsAt)
        }
        return ClaudeLimits(fiveHour: window(statusLine.fiveHour, else: fiveHour), sevenDay: window(statusLine.sevenDay, else: sevenDay))
    }

    /// A window whose reset time has passed no longer says anything about current usage.
    func current(at now: Date) -> ClaudeLimits {
        ClaudeLimits(
            fiveHour: fiveHour.flatMap { $0.isExpired(at: now) ? nil : $0 },
            sevenDay: sevenDay.flatMap { $0.isExpired(at: now) ? nil : $0 }
        )
    }

    static func percentText(_ percentage: Double) -> String {
        "\(Int(percentage.rounded()))%"
    }

    /// "3d 4h", "2h 10m", "12m" or "<1m".
    static func durationText(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval)) / 60
        switch minutes {
        case ..<1: return "<1m"
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h \(minutes % 60)m"
        default: return "\(minutes / (24 * 60))d \(minutes / 60 % 24)h"
        }
    }
}
