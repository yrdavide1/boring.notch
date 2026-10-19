//
//  ClaudeHookEvent.swift
//  boringNotch
//

import Foundation

/// One Claude Code hook payload, as POSTed by the boring-notch Claude Code plugin.
/// Only the fields the notch needs are decoded; everything else in the payload is ignored.
struct ClaudeHookEvent: Decodable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case permissionRequest = "PermissionRequest"
        case notification = "Notification"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case preCompact = "PreCompact"
        case sessionEnd = "SessionEnd"
        case other
    }

    let sessionID: String
    let hookEventName: String
    var cwd: String?
    var toolName: String?
    var notificationType: String?
    var permissionMode: String?

    var kind: Kind { Kind(rawValue: hookEventName) ?? .other }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case permissionMode = "permission_mode"
    }
}
