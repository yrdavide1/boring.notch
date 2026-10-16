//
//  ClaudeCodeTests.swift
//  boringNotchTests
//

import Defaults
import XCTest

@testable import boringNotch

final class ClaudeSessionReducerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func event(_ name: String, tool: String? = nil, notification: String? = nil, cwd: String? = nil) -> ClaudeHookEvent {
        ClaudeHookEvent(sessionID: "s1", hookEventName: name, cwd: cwd, toolName: tool, notificationType: notification)
    }

    private func run(_ events: [ClaudeHookEvent]) -> ClaudeSession {
        var session: ClaudeSession?
        for (offset, event) in events.enumerated() {
            session = ClaudeSession.reduce(session, with: event, at: start.addingTimeInterval(TimeInterval(offset)))
        }
        return session!
    }

    func testTypicalTurn() {
        XCTAssertEqual(run([event("SessionStart", cwd: "/Users/me/Git/boring.notch")]).state, .idle)
        XCTAssertEqual(run([event("UserPromptSubmit")]).state, .working)

        let running = run([event("UserPromptSubmit"), event("PreToolUse", tool: "Bash")])
        XCTAssertEqual(running.state, .runningTool)
        XCTAssertEqual(running.currentTool, "Bash")

        let afterTool = run([event("UserPromptSubmit"), event("PreToolUse", tool: "Bash"), event("PostToolUse", tool: "Bash")])
        XCTAssertEqual(afterTool.state, .working)
        XCTAssertNil(afterTool.currentTool)

        XCTAssertEqual(run([event("UserPromptSubmit"), event("Stop")]).state, .done)
        XCTAssertEqual(run([event("UserPromptSubmit"), event("StopFailure")]).state, .error)
        XCTAssertEqual(run([event("Stop"), event("SessionEnd")]).state, .ended)
    }

    func testPermissionFlow() {
        let asking = run([event("PreToolUse", tool: "Edit"), event("PermissionRequest", tool: "Edit")])
        XCTAssertEqual(asking.state, .needsPermission)
        XCTAssertEqual(asking.currentTool, "Edit")
        XCTAssertTrue(asking.state.needsAttention)

        XCTAssertEqual(run([event("PreToolUse", tool: "Edit"), event("Notification", notification: "permission_prompt")]).currentTool, "Edit")
        XCTAssertEqual(run([event("PermissionRequest", tool: "Edit"), event("PostToolUse", tool: "Edit")]).state, .working)
        XCTAssertEqual(run([event("PermissionRequest", tool: "Edit"), event("PostToolUseFailure", tool: "Edit")]).state, .working)
    }

    func testLateToolEventDoesNotReviveFinishedTurn() {
        XCTAssertEqual(run([event("UserPromptSubmit"), event("Stop"), event("PostToolUse", tool: "Bash")]).state, .done)
        XCTAssertEqual(run([event("Stop"), event("SessionEnd"), event("PostToolUse")]).state, .ended)
    }

    func testIdlePromptAndUnknownNotifications() {
        XCTAssertEqual(run([event("Stop"), event("Notification", notification: "idle_prompt")]).state, .waitingForInput)
        XCTAssertEqual(run([event("UserPromptSubmit"), event("Notification", notification: "auth_success")]).state, .working)
        XCTAssertEqual(run([event("UserPromptSubmit"), event("SomeFutureEvent")]).state, .working)
    }

    func testStateChangedAtOnlyMovesOnTransitions() {
        let session = run([event("UserPromptSubmit"), event("Notification", notification: "auth_success"), event("PostToolUse")])
        XCTAssertEqual(session.stateChangedAt, start)
        XCTAssertEqual(session.lastEventAt, start.addingTimeInterval(2))
    }

    func testProjectNameAndDecoding() throws {
        let json = #"{"session_id":"abc","hook_event_name":"PreToolUse","cwd":"/Users/me/Git/boring.notch","tool_name":"Bash","tool_input":{"command":"ls"},"permission_mode":"auto"}"#
        let decoded = try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .preToolUse)
        XCTAssertEqual(decoded.toolName, "Bash")

        let session = ClaudeSession.reduce(nil, with: decoded, at: start)
        XCTAssertEqual(session.projectName, "boring.notch")
        XCTAssertEqual(session.permissionMode, "auto")
    }

    func testDisplayOrder() {
        func session(_ id: String, _ state: ClaudeSession.State, lastEvent: TimeInterval) -> ClaudeSession {
            ClaudeSession(id: id, state: state, startedAt: start, lastEventAt: start.addingTimeInterval(lastEvent), stateChangedAt: start)
        }
        let sorted = [
            session("done", .done, lastEvent: 30),
            session("working-old", .working, lastEvent: 10),
            session("asking", .needsPermission, lastEvent: 0),
            session("working-new", .runningTool, lastEvent: 20),
        ].sorted(by: ClaudeSession.displayOrder)
        XCTAssertEqual(sorted.map(\.id), ["asking", "working-new", "working-old", "done"])
    }
}

final class LocalHTTPRequestTests: XCTestCase {
    private func request(_ body: String, headers: String = "X-BoringNotch-Client: claude-code\r\n") -> Data {
        Data("POST /hooks HTTP/1.1\r\nHost: 127.0.0.1:47800\r\n\(headers)Content-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }

    func testCompleteRequest() {
        guard case .complete(let parsed) = LocalHTTPRequest.parse(request(#"{"a":1}"#), maxBodySize: 1024) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/hooks")
        XCTAssertEqual(parsed.headers["x-boringnotch-client"], "claude-code")
        XCTAssertEqual(parsed.body, Data(#"{"a":1}"#.utf8))
    }

    func testPartialRequestsAreIncomplete() {
        let full = request(#"{"session_id":"x"}"#)
        XCTAssertEqual(LocalHTTPRequest.parse(full.prefix(20), maxBodySize: 1024), .incomplete)
        XCTAssertEqual(LocalHTTPRequest.parse(full.dropLast(3), maxBodySize: 1024), .incomplete)
    }

    func testRejectsMalformedAndOversizedRequests() {
        XCTAssertEqual(LocalHTTPRequest.parse(Data("garbage\r\n\r\n".utf8), maxBodySize: 1024), .invalid)
        XCTAssertEqual(LocalHTTPRequest.parse(Data("POST /hooks HTTP/1.1\r\nno-colon\r\n\r\n".utf8), maxBodySize: 1024), .invalid)
        XCTAssertEqual(LocalHTTPRequest.parse(request(String(repeating: "x", count: 2048)), maxBodySize: 1024), .tooLarge)
    }

    func testResponseFormat() {
        let response = String(decoding: LocalHTTPRequest.response(status: 200, reason: "OK"), as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(response.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(response.hasSuffix("\r\n\r\n{}"))
    }
}

@MainActor
final class ClaudeCodeManagerSweepTests: XCTestCase {
    private let manager = ClaudeCodeManager.shared
    private let start = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        manager.stop()
        Defaults[.claudeCodeStaleMinutes] = 15
    }

    override func tearDown() async throws {
        manager.stop()
        Defaults.reset(.claudeCodeStaleMinutes)
    }

    func testActiveSessionBecomesStaleAndEndedSessionIsRemoved() {
        manager.handle(ClaudeHookEvent(sessionID: "active", hookEventName: "UserPromptSubmit"), at: start)
        manager.handle(ClaudeHookEvent(sessionID: "ended", hookEventName: "SessionEnd"), at: start)
        manager.handle(ClaudeHookEvent(sessionID: "done", hookEventName: "Stop"), at: start)

        manager.sweep(now: start.addingTimeInterval(5))
        XCTAssertEqual(Set(manager.sessions.map(\.id)), ["active", "ended", "done"])

        manager.sweep(now: start.addingTimeInterval(16 * 60))
        XCTAssertEqual(manager.sessions.first { $0.id == "active" }?.state, .stale)
        XCTAssertNil(manager.sessions.first { $0.id == "ended" })
        XCTAssertEqual(manager.sessions.first { $0.id == "done" }?.state, .done)

        manager.sweep(now: start.addingTimeInterval(ClaudeCodeManager.maximumIdle))
        XCTAssertTrue(manager.sessions.isEmpty)
    }
}
