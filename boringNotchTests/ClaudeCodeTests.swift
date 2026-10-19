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

final class ClaudeActivitySummaryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func session(_ id: String, _ state: ClaudeSession.State, cwd: String? = nil) -> ClaudeSession {
        ClaudeSession(id: id, cwd: cwd, state: state, startedAt: start, lastEventAt: start, stateChangedAt: start)
    }

    private func summary(
        _ sessions: [ClaudeSession],
        transient: ClaudeTransient.Kind? = nil,
        mode: ClaudeClosedActivityMode = .whileWorking
    ) -> ClaudeActivitySummary? {
        ClaudeActivitySummary.make(
            sessions: sessions,
            transient: transient.map { ClaudeTransient(kind: $0, expiresAt: start) },
            mode: mode,
            attentionToken: 0
        )
    }

    func testOnlyWorkingAndPermissionPromptsCount() {
        XCTAssertNil(summary([session("a", .idle), session("b", .done), session("c", .waitingForInput), session("d", .stale)]))

        let working = summary([session("a", .runningTool), session("b", .compacting), session("c", .waitingForInput)])
        XCTAssertEqual(working?.look, .working)
        XCTAssertEqual(working?.count, 2)
        XCTAssertEqual(working?.isUrgent, false)

        let asking = summary([session("a", .working), session("b", .needsPermission)])
        XCTAssertEqual(asking?.look, .needsYou)
        XCTAssertEqual(asking?.count, 2)
        XCTAssertEqual(asking?.isUrgent, true)
    }

    func testModes() {
        XCTAssertNil(summary([session("a", .needsPermission)], mode: .off))
        XCTAssertNil(summary([session("a", .working)], mode: .onlyWhenNeedsYou))
        XCTAssertEqual(summary([session("a", .working), session("b", .needsPermission)], mode: .onlyWhenNeedsYou)?.count, 1)
        XCTAssertNil(summary([], transient: .doneFlash, mode: .onlyWhenNeedsYou))
    }

    func testDoneFlashOnlyWhenNothingCounts() {
        XCTAssertEqual(summary([session("a", .done)], transient: .doneFlash)?.look, .done)
        XCTAssertEqual(summary([session("a", .working)], transient: .doneFlash)?.look, .working)
    }

    func testPeekOnlyWhileItsSessionStillNeedsYou() {
        let peeking = summary([session("a", .needsPermission, cwd: "/Users/me/Git/api")], transient: .peek(sessionID: "a"))
        XCTAssertEqual(peeking?.peek?.projectName, "api")
        XCTAssertEqual(peeking?.isUrgent, true)

        let approved = summary([session("a", .working)], transient: .peek(sessionID: "a"))
        XCTAssertNil(approved?.peek)
        XCTAssertEqual(approved?.look, .working)
    }
}

final class ClaudeActivityTransitionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func sessions(_ states: [String: ClaudeSession.State]) -> [String: ClaudeSession] {
        states.mapValues { ClaudeSession(id: "", state: $0, startedAt: start, lastEventAt: start, stateChangedAt: start) }
    }

    func testStartedNeedingYouFiresOncePerTransition() {
        XCTAssertEqual(
            ClaudeActivityTransition.detect(old: sessions(["a": .runningTool]), new: sessions(["a": .needsPermission])),
            [.startedNeedingYou(sessionID: "a")]
        )
        // PermissionRequest followed by Notification(permission_prompt) is one transition, not two.
        XCTAssertEqual(ClaudeActivityTransition.detect(old: sessions(["a": .needsPermission]), new: sessions(["a": .needsPermission])), [])
    }

    func testAllFinishedOnlyWhenTheLastCountingSessionStops() {
        XCTAssertEqual(
            ClaudeActivityTransition.detect(old: sessions(["a": .working, "b": .done]), new: sessions(["a": .done, "b": .done])),
            [.allFinished]
        )
        XCTAssertEqual(
            ClaudeActivityTransition.detect(old: sessions(["a": .working, "b": .working]), new: sessions(["a": .done, "b": .working])),
            []
        )
        // idle_prompt ~60 s after Stop changes done to waitingForInput: no new moment.
        XCTAssertEqual(ClaudeActivityTransition.detect(old: sessions(["a": .done]), new: sessions(["a": .waitingForInput])), [])
    }
}

final class LiveActivityOrderTests: XCTestCase {
    private func summary(_ look: ClaudeActivitySummary.Look, peek: Bool = false) -> ClaudeActivitySummary {
        ClaudeActivitySummary(look: look, count: 1, peek: peek ? .init(projectName: "p") : nil, attentionToken: 0)
    }

    private func order(
        _ claude: ClaudeActivitySummary?,
        music: Bool = true,
        musicPeek: Bool = false,
        claudeInFront: Bool = true
    ) -> [LiveActivityItem] {
        LiveActivityOrder.items(
            notification: nil,
            claudeCode: claude,
            musicShowing: music,
            musicPeekShowing: musicPeek,
            claudeCodeInFrontOfMusic: claudeInFront
        )
    }

    func testSettingOrdersWorkingClaudeAndMusic() {
        XCTAssertEqual(order(summary(.working)), [.claudeCode, .music])
        XCTAssertEqual(order(summary(.working), claudeInFront: false), [.music, .claudeCode])
        XCTAssertEqual(order(nil), [.music])
        XCTAssertEqual(order(summary(.working), music: false, claudeInFront: false), [.claudeCode])
    }

    func testUrgentClaudeBeatsMusicWhateverTheSetting() {
        XCTAssertEqual(order(summary(.needsYou), claudeInFront: false), [.claudeCode, .music])
        XCTAssertEqual(order(summary(.done), claudeInFront: false), [.claudeCode, .music])
        XCTAssertEqual(order(summary(.working, peek: true), claudeInFront: false), [.claudeCode, .music])
    }

    func testSongChangePeekBeatsWorkingClaude() {
        XCTAssertEqual(order(summary(.working), musicPeek: true), [.music, .claudeCode])
        XCTAssertEqual(order(summary(.needsYou), musicPeek: true), [.claudeCode, .music])
    }
}

@MainActor
final class PixelMascotTests: XCTestCase {
    func testSpritesFitTheGrid() {
        for (pose, rows) in PixelMascot.sprites {
            XCTAssertLessThan(rows.count, PixelMascot.rows, "\(pose) needs a spare row for the bob")
            for row in rows {
                XCTAssertEqual(row.count, PixelMascot.columns, "\(pose): \(row)")
                XCTAssertTrue(row.allSatisfy { "#o.".contains($0) }, "\(pose): \(row)")
            }
        }
    }
}

@MainActor
final class ClaudeCodeManagerActivityTests: XCTestCase {
    private let manager = ClaudeCodeManager.shared
    private let start = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        manager.stop()
        Defaults[.claudeCodeClosedActivity] = .whileWorking
        Defaults[.claudeCodeStaleMinutes] = 15
    }

    override func tearDown() async throws {
        manager.stop()
        Defaults.reset(.claudeCodeClosedActivity, .claudeCodeStaleMinutes)
    }

    private func send(
        _ name: String,
        _ id: String = "s",
        tool: String? = nil,
        notification: String? = nil,
        at offset: TimeInterval = 0
    ) {
        manager.handle(
            ClaudeHookEvent(sessionID: id, hookEventName: name, cwd: "/Users/me/Git/api", toolName: tool, notificationType: notification),
            at: start.addingTimeInterval(offset)
        )
    }

    func testPermissionPromptPeeksAndRaisesAttention() throws {
        send("UserPromptSubmit")
        let working = try XCTUnwrap(manager.activitySummary)
        XCTAssertEqual(working.look, .working)

        send("PreToolUse", tool: "Bash")
        XCTAssertEqual(manager.activitySummary, working, "a tool call must not republish the summary")

        send("PermissionRequest", tool: "Bash")
        let asking = try XCTUnwrap(manager.activitySummary)
        XCTAssertEqual(asking.look, .needsYou)
        XCTAssertEqual(asking.peek?.projectName, "api")
        XCTAssertGreaterThan(asking.attentionToken, working.attentionToken)

        send("PostToolUse", tool: "Bash")
        XCTAssertEqual(manager.activitySummary?.look, .working)
        XCTAssertNil(manager.activitySummary?.peek)
    }

    func testDoneFlashAfterLastSessionStopsAndEndsWhenWorkResumes() throws {
        send("UserPromptSubmit")
        send("Stop")
        XCTAssertEqual(manager.activitySummary?.look, .done)

        send("UserPromptSubmit")
        XCTAssertEqual(manager.activitySummary?.look, .working)
        send("Stop")
        let flash = try XCTUnwrap(manager.activitySummary)

        send("Notification", notification: "idle_prompt", at: 60)
        XCTAssertEqual(manager.sessions.first?.state, .waitingForInput)
        XCTAssertEqual(manager.activitySummary?.attentionToken, flash.attentionToken, "idle_prompt is not a new moment")
        XCTAssertNotEqual(manager.activitySummary?.look, .needsYou)
    }

    func testStalePermissionPromptStopsCounting() {
        send("PermissionRequest", tool: "Edit")
        XCTAssertEqual(manager.activitySummary?.look, .needsYou)

        manager.sweep(now: start.addingTimeInterval(16 * 60))
        XCTAssertEqual(manager.sessions.first?.state, .stale)
        XCTAssertNil(manager.activitySummary)
    }
}

final class OTLPUsageParserTests: XCTestCase {
    /// Shape of a real Claude Code export, with made-up identity values.
    private func payload(temporality: String = "1", tokenValue: String = "98") -> Data {
        Data("""
        {"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}}]},
         "scopeMetrics":[{"metrics":[
          {"name":"claude_code.session.count","sum":{"aggregationTemporality":1,"dataPoints":[{"asInt":1,"attributes":[{"key":"session.id","value":{"stringValue":"s1"}}]}]}},
          {"name":"claude_code.cost.usage","sum":{"aggregationTemporality":\(temporality),"dataPoints":[{"asDouble":0.0062,"attributes":[
            {"key":"session.id","value":{"stringValue":"s1"}},{"key":"model","value":{"stringValue":"claude-haiku"}},
            {"key":"user.email","value":{"stringValue":"someone@example.com"}}]}]}},
          {"name":"claude_code.token.usage","sum":{"aggregationTemporality":\(temporality),"dataPoints":[
            {"asInt":\(tokenValue),"attributes":[{"key":"session.id","value":{"stringValue":"s1"}},{"key":"type","value":{"stringValue":"output"}},{"key":"model","value":{"stringValue":"claude-haiku"}}]},
            {"asInt":"30188","attributes":[{"key":"session.id","value":{"stringValue":"s1"}},{"key":"type","value":{"stringValue":"cacheCreation"}}]},
            {"asInt":5,"attributes":[{"key":"type","value":{"stringValue":"input"}}]}]}}
         ]}]}]}
        """.utf8)
    }

    func testReadsUsageMetricsOnly() throws {
        let samples = try OTLPUsageParser.samples(from: payload())
        XCTAssertEqual(samples.map(\.metric), [.cost, .tokens(type: "output"), .tokens(type: "cacheCreation")])
        XCTAssertEqual(samples.map(\.value), [0.0062, 98, 30188], "asInt may be a number or a string")
        XCTAssertTrue(samples.allSatisfy { $0.sessionID == "s1" && !$0.isCumulative }, "points without session.id are skipped")
        XCTAssertFalse(samples.contains { $0.seriesKey.contains("@") }, "identity attributes never enter the series key")
    }

    func testCumulativeTemporalityAsNumberOrName() throws {
        XCTAssertTrue(try OTLPUsageParser.samples(from: payload(temporality: "2")).allSatisfy(\.isCumulative))
        XCTAssertTrue(try OTLPUsageParser.samples(from: payload(temporality: "\"AGGREGATION_TEMPORALITY_CUMULATIVE\"")).allSatisfy(\.isCumulative))
        XCTAssertThrowsError(try OTLPUsageParser.samples(from: Data("not json".utf8)))
    }

    func testFormatting() {
        XCTAssertEqual(ClaudeUsage.tokensText(950), "950")
        XCTAssertEqual(ClaudeUsage.tokensText(9_840), "9.8k")
        XCTAssertEqual(ClaudeUsage.tokensText(184_300), "184k")
        XCTAssertEqual(ClaudeUsage.tokensText(1_250_000), "1.2M")
        XCTAssertEqual(ClaudeUsage.costText(0), "$0.00")
        XCTAssertEqual(ClaudeUsage.costText(0.004), "<$0.01")
        XCTAssertEqual(ClaudeUsage.costText(1.917), "$1.92")
    }
}

@MainActor
final class ClaudeCodeManagerUsageTests: XCTestCase {
    private let manager = ClaudeCodeManager.shared

    override func setUp() async throws { manager.stop() }
    override func tearDown() async throws { manager.stop() }

    private func sample(_ metric: ClaudeUsageSample.Metric, _ value: Double, cumulative: Bool = false, session: String = "s1") -> ClaudeUsageSample {
        ClaudeUsageSample(sessionID: session, metric: metric, seriesKey: "\(metric)", value: value, isCumulative: cumulative)
    }

    func testDeltasAddUp() {
        manager.handle([sample(.tokens(type: "input"), 10), sample(.tokens(type: "cacheRead"), 1_000), sample(.cost, 0.5)])
        manager.handle([sample(.tokens(type: "input"), 5), sample(.cost, 0.25)])
        let usage = manager.usage["s1"]
        XCTAssertEqual(usage?.inputTokens, 15)
        XCTAssertEqual(usage?.totalTokens, 1_015)
        XCTAssertEqual(usage?.costUSD, 0.75)
        XCTAssertNotNil(manager.lastMetricsAt)
    }

    func testCumulativeValuesReplace() {
        manager.handle([sample(.tokens(type: "output"), 40, cumulative: true)])
        manager.handle([sample(.tokens(type: "output"), 100, cumulative: true)])
        XCTAssertEqual(manager.usage["s1"]?.outputTokens, 100)
    }

    func testSessionsAreSeparateAndRemovedWithTheSession() {
        let start = Date(timeIntervalSince1970: 1_000)
        manager.handle(ClaudeHookEvent(sessionID: "s1", hookEventName: "SessionEnd"), at: start)
        manager.handle([sample(.cost, 1), sample(.cost, 2, session: "s2")], at: start)
        XCTAssertEqual(manager.usage["s2"]?.costUSD, 2)

        manager.sweep(now: start.addingTimeInterval(ClaudeCodeManager.endedRetention))
        XCTAssertNil(manager.usage["s1"], "removed with its ended session")
        XCTAssertEqual(manager.usage["s2"]?.costUSD, 2, "usage without a known session is kept for a while")

        manager.sweep(now: start.addingTimeInterval(11 * 60))
        XCTAssertNil(manager.usage["s2"])
    }
}
