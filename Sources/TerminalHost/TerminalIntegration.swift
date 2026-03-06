import Foundation

public enum TerminalIntegrationEvent: Equatable, Sendable {
    case currentDirectory(String)
    case gitBranch(String?)
    case commandStarted(String)
    case promptReady
}

public struct TerminalIntegrationParseResult: Equatable, Sendable {
    public var visibleLines: [String]
    public var events: [TerminalIntegrationEvent]

    public init(visibleLines: [String] = [], events: [TerminalIntegrationEvent] = []) {
        self.visibleLines = visibleLines
        self.events = events
    }
}

public struct TerminalIntegrationParser: Sendable {
    private static let cwdPrefix = "__FLOUI__CWD\t"
    private static let branchPrefix = "__FLOUI__BRANCH\t"
    private static let runPrefix = "__FLOUI__RUN\t"
    private static let idleLine = "__FLOUI__IDLE"

    private var pendingFragment = ""

    public init() {}

    public mutating func consume(_ text: String) -> TerminalIntegrationParseResult {
        parse(text, flushPending: false)
    }

    public mutating func finish() -> TerminalIntegrationParseResult {
        parse("", flushPending: true)
    }

    private mutating func parse(_ text: String, flushPending: Bool) -> TerminalIntegrationParseResult {
        let normalizedInput = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let combined = pendingFragment + normalizedInput
        let endedWithLineBreak = combined.hasSuffix("\n")
        var lines = combined.components(separatedBy: "\n")

        if !flushPending, !endedWithLineBreak {
            pendingFragment = lines.popLast() ?? ""
        } else {
            pendingFragment = ""
        }

        var result = TerminalIntegrationParseResult()
        for line in lines {
            guard !line.isEmpty else {
                continue
            }

            if let event = parseEvent(line) {
                result.events.append(event)
            } else {
                result.visibleLines.append(line)
            }
        }

        if flushPending, !pendingFragment.isEmpty {
            if let event = parseEvent(pendingFragment) {
                result.events.append(event)
            } else {
                result.visibleLines.append(pendingFragment)
            }
            pendingFragment = ""
        }

        return result
    }

    private func parseEvent(_ line: String) -> TerminalIntegrationEvent? {
        if line == Self.idleLine {
            return .promptReady
        }

        if line.hasPrefix(Self.cwdPrefix) {
            return .currentDirectory(String(line.dropFirst(Self.cwdPrefix.count)))
        }

        if line.hasPrefix(Self.branchPrefix) {
            let value = String(line.dropFirst(Self.branchPrefix.count))
            return .gitBranch(value.isEmpty ? nil : value)
        }

        if line.hasPrefix(Self.runPrefix) {
            let value = String(line.dropFirst(Self.runPrefix.count))
            return value.isEmpty ? nil : .commandStarted(value)
        }

        return nil
    }
}
