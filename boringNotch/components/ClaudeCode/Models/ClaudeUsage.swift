//
//  ClaudeUsage.swift
//  boringNotch
//

import Foundation

/// Token and cost totals for one Claude Code session, built from Claude Code's
/// OpenTelemetry metrics (`claude_code.token.usage`, `claude_code.cost.usage`).
struct ClaudeUsage: Equatable, Sendable {
    var inputTokens: Double = 0
    var outputTokens: Double = 0
    var cacheReadTokens: Double = 0
    var cacheCreationTokens: Double = 0
    /// Claude Code's own estimate at API list prices; not what a subscription bills.
    var costUSD: Double = 0

    var totalTokens: Double { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    static func tokensText(_ tokens: Double) -> String {
        switch tokens {
        case ..<1_000: return "\(Int(tokens))"
        case ..<10_000: return String(format: "%.1fk", tokens / 1_000)
        case ..<1_000_000: return "\(Int(tokens / 1_000))k"
        default: return String(format: "%.1fM", tokens / 1_000_000)
        }
    }

    static func costText(_ cost: Double) -> String {
        cost > 0 && cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost)
    }
}

/// One usage data point from an OTLP export.
struct ClaudeUsageSample: Equatable, Sendable {
    enum Metric: Equatable, Sendable {
        case tokens(type: String)
        case cost
    }

    let sessionID: String
    let metric: Metric
    /// Identifies the time series (metric plus attributes) so cumulative exports replace instead of add.
    let seriesKey: String
    let value: Double
    let isCumulative: Bool
}

/// Decodes the OTLP/HTTP JSON metrics payload. Only the two usage metrics are read;
/// identity attributes (user, organization) are never kept.
enum OTLPUsageParser {
    private static let ignoredSeriesAttributes: Set<String> = [
        "session.id", "user.email", "user.id", "user.account_uuid", "user.account_id", "organization.id", "terminal.type",
    ]

    static func samples(from data: Data) throws -> [ClaudeUsageSample] {
        let request = try JSONDecoder().decode(Request.self, from: data)
        var samples: [ClaudeUsageSample] = []

        for metric in request.resourceMetrics.flatMap(\.scopeMetrics).flatMap(\.metrics) {
            guard metric.name == "claude_code.token.usage" || metric.name == "claude_code.cost.usage",
                  let sum = metric.sum
            else { continue }

            for point in sum.dataPoints {
                let attributes = Dictionary(
                    point.attributes.compactMap { attribute in attribute.value.stringValue.map { (attribute.key, $0) } },
                    uniquingKeysWith: { first, _ in first }
                )
                guard let sessionID = attributes["session.id"], let value = point.value else { continue }

                let kind: ClaudeUsageSample.Metric
                if metric.name == "claude_code.cost.usage" {
                    kind = .cost
                } else if let type = attributes["type"] {
                    kind = .tokens(type: type)
                } else {
                    continue
                }

                let seriesKey = ([metric.name] + attributes
                    .filter { !ignoredSeriesAttributes.contains($0.key) }
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }).joined(separator: "|")

                samples.append(ClaudeUsageSample(
                    sessionID: sessionID,
                    metric: kind,
                    seriesKey: seriesKey,
                    value: value,
                    isCumulative: sum.isCumulative
                ))
            }
        }
        return samples
    }

    // MARK: - OTLP JSON shapes (only the fields needed)

    private struct Request: Decodable {
        var resourceMetrics: [ResourceMetrics] = []
        enum CodingKeys: CodingKey { case resourceMetrics }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resourceMetrics = try container.decodeIfPresent([ResourceMetrics].self, forKey: .resourceMetrics) ?? []
        }
    }

    private struct ResourceMetrics: Decodable {
        var scopeMetrics: [ScopeMetrics] = []
        enum CodingKeys: CodingKey { case scopeMetrics }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scopeMetrics = try container.decodeIfPresent([ScopeMetrics].self, forKey: .scopeMetrics) ?? []
        }
    }

    private struct ScopeMetrics: Decodable {
        var metrics: [Metric] = []
        enum CodingKeys: CodingKey { case metrics }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metrics = try container.decodeIfPresent([Metric].self, forKey: .metrics) ?? []
        }
    }

    private struct Metric: Decodable {
        let name: String
        let sum: Sum?
    }

    private struct Sum: Decodable {
        var dataPoints: [DataPoint] = []
        var isCumulative = false

        enum CodingKeys: CodingKey { case dataPoints, aggregationTemporality }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dataPoints = try container.decodeIfPresent([DataPoint].self, forKey: .dataPoints) ?? []
            // proto3 JSON allows the enum as a number (2) or its name.
            if let number = try? container.decode(Int.self, forKey: .aggregationTemporality) {
                isCumulative = number == 2
            } else if let name = try? container.decode(String.self, forKey: .aggregationTemporality) {
                isCumulative = name == "AGGREGATION_TEMPORALITY_CUMULATIVE"
            }
        }
    }

    private struct DataPoint: Decodable {
        var attributes: [Attribute] = []
        var value: Double?

        enum CodingKeys: CodingKey { case attributes, asDouble, asInt }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            attributes = try container.decodeIfPresent([Attribute].self, forKey: .attributes) ?? []
            value = Self.number(container, .asDouble) ?? Self.number(container, .asInt)
        }

        /// proto3 JSON encodes 64-bit integers as strings; accept both forms.
        private static func number(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
            if let value = try? container.decode(Double.self, forKey: key) { return value }
            if let text = try? container.decode(String.self, forKey: key) { return Double(text) }
            return nil
        }
    }

    private struct Attribute: Decodable {
        let key: String
        let value: AttributeValue
    }

    private struct AttributeValue: Decodable {
        let stringValue: String?
    }
}
