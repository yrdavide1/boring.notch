//
//  LocalHTTPRequest.swift
//  boringNotch
//

import Foundation

/// Minimal HTTP/1.1 request parsing for the local Claude Code listener.
/// Supports exactly what curl sends: a request line, headers and a Content-Length body.
struct LocalHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data

    enum ParseResult: Equatable, Sendable {
        case incomplete
        case complete(LocalHTTPRequest)
        case invalid
        case tooLarge
    }

    static func parse(_ data: Data, maxBodySize: Int) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard length >= 0 else { return .invalid }
        guard length <= maxBodySize else { return .tooLarge }

        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }

        return .complete(LocalHTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + length)])
        ))
    }

    static func response(status: Int, reason: String, body: String = "{}") -> Data {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + bodyData
    }
}
