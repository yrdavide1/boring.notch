//
//  ClaudeCodeListener.swift
//  boringNotch
//

import Foundation
import Network

/// Loopback-only HTTP listener that receives Claude Code hook events from the boring-notch plugin.
///
/// The app is sandboxed; `com.apple.security.network.server` already allows this. The listener is
/// read-only by design: it always answers `{}` so it can never influence Claude Code's decisions.
/// All mutable state lives on `queue`.
final class ClaudeCodeListener: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    static let defaultPort: UInt16 = 47800
    /// Sent by the plugin's curl command. Browsers cannot add custom headers to cross-site
    /// requests without a CORS preflight, so web pages cannot forge events.
    static let clientHeader = "x-boringnotch-client"
    static let hooksPath = "/hooks"
    /// OTLP/HTTP JSON metrics export from Claude Code (token and cost usage).
    static let metricsPath = "/v1/metrics"

    private static let maxBodySize = 1024 * 1024
    private static let connectionTimeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "theboringteam.boringnotch.claudeCode.listener")
    private var listener: NWListener?
    private let decoder = JSONDecoder()

    private let onEvent: @Sendable (ClaudeHookEvent) -> Void
    private let onUsage: @Sendable ([ClaudeUsageSample]) -> Void
    private let onStatus: @Sendable (Status) -> Void

    init(
        onEvent: @escaping @Sendable (ClaudeHookEvent) -> Void,
        onUsage: @escaping @Sendable ([ClaudeUsageSample]) -> Void,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.onEvent = onEvent
        self.onUsage = onUsage
        self.onStatus = onStatus
    }

    func start(port: UInt16 = defaultPort) {
        queue.async { [self] in
            guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            parameters.allowLocalEndpointReuse = true

            do {
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak self] state in self?.handle(state, port: port) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                Log.claudeCode.error("Failed to create listener: \(error.localizedDescription)")
                onStatus(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            onStatus(.stopped)
        }
    }

    private func handle(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            Log.claudeCode.info("Listening on 127.0.0.1:\(port)")
            onStatus(.listening(port: port))
        case .failed(let error):
            Log.claudeCode.error("Listener failed: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
            onStatus(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak connection] in
            connection?.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch LocalHTTPRequest.parse(buffer, maxBodySize: Self.maxBodySize) {
            case .incomplete where error == nil && !isComplete:
                receive(on: connection, buffer: buffer)
            case .incomplete, .invalid:
                respond(on: connection, status: 400, reason: "Bad Request")
            case .tooLarge:
                respond(on: connection, status: 413, reason: "Payload Too Large")
            case .complete(let request):
                route(request, on: connection)
            }
        }
    }

    private func route(_ request: LocalHTTPRequest, on connection: NWConnection) {
        guard request.headers[Self.clientHeader] != nil else {
            respond(on: connection, status: 403, reason: "Forbidden")
            return
        }
        guard request.method == "POST", request.path == Self.hooksPath || request.path == Self.metricsPath else {
            respond(on: connection, status: 404, reason: "Not Found")
            return
        }

        // Answer first so Claude Code never waits on the app.
        respond(on: connection, status: 200, reason: "OK")
        do {
            if request.path == Self.hooksPath {
                onEvent(try decoder.decode(ClaudeHookEvent.self, from: request.body))
            } else {
                let samples = try OTLPUsageParser.samples(from: request.body)
                if !samples.isEmpty { onUsage(samples) }
            }
        } catch {
            // The path is public for debugging; the error text stays private, as payloads carry the user's email.
            Log.claudeCode.error("Ignoring undecodable payload on \(request.path, privacy: .public): \(error.localizedDescription)")
        }
    }

    private func respond(on connection: NWConnection, status: Int, reason: String) {
        connection.send(
            content: LocalHTTPRequest.response(status: status, reason: reason),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
