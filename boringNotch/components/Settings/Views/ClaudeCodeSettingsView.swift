//
//  ClaudeCodeSettingsView.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

struct ClaudeCodeSettingsView: View {
    @Default(.claudeCodeEnabled) private var enabled
    @Default(.claudeCodeStaleMinutes) private var staleMinutes
    @Default(.claudeCodeClosedActivity) private var closedActivity
    @ObservedObject private var manager = ClaudeCodeManager.shared

    private static let pluginPath = "<path to boring.notch>/extras/claude-code-plugin"
    private static let installCommands = """
        cp ~/.claude/settings.json ~/.claude/settings.json.bak-$(date +%Y%m%d)
        claude plugin marketplace add \(pluginPath)
        claude plugin install boring-notch@boring-notch
        """
    private static let telemetrySettings = """
        "env": {
          "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
          "OTEL_METRICS_EXPORTER": "otlp",
          "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
          "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://127.0.0.1:47800/v1/metrics",
          "OTEL_EXPORTER_OTLP_METRICS_HEADERS": "X-BoringNotch-Client=claude-code",
          "OTEL_METRIC_EXPORT_INTERVAL": "5000"
        }
        """
    private static let uninstallCommands = """
        claude plugin uninstall boring-notch
        claude plugin marketplace remove boring-notch
        """

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .claudeCodeEnabled) {
                    Text("Show Claude Code sessions")
                }
                if enabled {
                    LabeledContent("Status") {
                        Text(statusText)
                            .foregroundStyle(isFailed ? .red : .secondary)
                    }
                    LabeledContent("Last event") {
                        if let lastEventAt = manager.lastEventAt {
                            Text(lastEventAt, style: .relative)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("None yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Mark as inactive after", selection: $staleMinutes) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("A session that stops sending events while working, for example after you press Esc, is shown as inactive.")
            }

            Section {
                Picker("Show in closed notch", selection: $closedActivity) {
                    Text("Off").tag(ClaudeClosedActivityMode.off)
                    Text("While working").tag(ClaudeClosedActivityMode.whileWorking)
                    Text("Only when it needs you").tag(ClaudeClosedActivityMode.onlyWhenNeedsYou)
                }
                Defaults.Toggle(key: .claudeCodeInFrontOfMusic) {
                    Text("Show in front of music")
                }
                .disabled(closedActivity == .off)
            } header: {
                Text("Closed notch")
            } footer: {
                Text("A session waiting for a permission decision always comes to the front. When the last working session finishes, a check mark shows for a few seconds.")
            }

            Section {
                commandBlock(Self.installCommands)
            } header: {
                Text("Install the Claude Code plugin")
            } footer: {
                Text("Run these in Terminal, replacing the path with your checkout. The first line backs up your Claude Code settings; installing a plugin adds one entry to them. The plugin only sends events to this Mac (127.0.0.1) and never changes what Claude Code does.")
            }

            Section {
                LabeledContent("Last usage update") {
                    if let lastMetricsAt = manager.lastMetricsAt {
                        Text(lastMetricsAt, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("None yet")
                            .foregroundStyle(.secondary)
                    }
                }
                commandBlock(Self.telemetrySettings)
            } header: {
                Text("Token usage")
            } footer: {
                Text("To show tokens and cost per session, add these entries to the \"env\" object in ~/.claude/settings.json (merge them if it already exists), then start a new Claude Code session. Claude Code sends usage to this Mac every 5 seconds. The cost is Claude Code's estimate at API prices, not what a subscription bills.")
            }

            Section {
                commandBlock(Self.uninstallCommands)
            } header: {
                Text("Uninstall")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Claude Code")
    }

    private var isFailed: Bool {
        if case .failed = manager.status { return true }
        return false
    }

    private var statusText: String {
        switch manager.status {
        case .stopped:
            String(localized: "Stopped", comment: "Claude Code listener status")
        case .listening(let port):
            String(localized: "Listening on 127.0.0.1:\(String(port))", comment: "Claude Code listener status; argument is a port number")
        case .failed(let message):
            String(localized: "Failed: \(message)", comment: "Claude Code listener status; argument is an error message")
        }
    }

    private func commandBlock(_ commands: String) -> some View {
        HStack(alignment: .top) {
            Text(commands)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commands, forType: .string)
            }
        }
    }
}
