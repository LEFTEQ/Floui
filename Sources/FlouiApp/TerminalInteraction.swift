import AppKit
import Foundation

enum TerminalTranscriptSearchNavigator {
    static func matchRanges(in transcript: String, query: String) -> [NSRange] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let nsTranscript = transcript as NSString
        let searchRange = NSRange(location: 0, length: nsTranscript.length)
        var ranges: [NSRange] = []
        var nextLocation = searchRange.location

        while nextLocation < nsTranscript.length {
            let remaining = NSRange(location: nextLocation, length: nsTranscript.length - nextLocation)
            let found = nsTranscript.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: remaining
            )

            guard found.location != NSNotFound, found.length > 0 else {
                break
            }

            ranges.append(found)
            nextLocation = found.location + found.length
        }

        return ranges
    }

    static func normalizedSelection(current: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else {
            return nil
        }

        guard let current else {
            return 0
        }

        return max(0, min(current, matchCount - 1))
    }

    static func nextSelection(after current: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else {
            return nil
        }

        guard let current else {
            return 0
        }

        return (current + 1) % matchCount
    }

    static func previousSelection(before current: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else {
            return nil
        }

        guard let current else {
            return matchCount - 1
        }

        return current == 0 ? matchCount - 1 : current - 1
    }
}

struct TerminalCommandHistoryState: Equatable, Sendable {
    private var draft: String?
    private var currentIndex: Int?

    mutating func moveBackward(currentInput: String, recentCommands: [String]) -> String {
        guard !recentCommands.isEmpty else {
            return currentInput
        }

        if currentIndex == nil {
            draft = currentInput
            currentIndex = 0
            return recentCommands[0]
        }

        let nextIndex = min((currentIndex ?? 0) + 1, recentCommands.count - 1)
        currentIndex = nextIndex
        return recentCommands[nextIndex]
    }

    mutating func moveForward(currentInput: String, recentCommands: [String]) -> String {
        guard let currentIndex else {
            return currentInput
        }

        guard !recentCommands.isEmpty else {
            reset()
            return currentInput
        }

        if currentIndex == 0 {
            let restoredDraft = draft ?? ""
            reset()
            return restoredDraft
        }

        let nextIndex = currentIndex - 1
        self.currentIndex = nextIndex
        return recentCommands[nextIndex]
    }

    mutating func reset() {
        draft = nil
        currentIndex = nil
    }
}

@MainActor
final class TerminalTranscriptController: ObservableObject {
    private var copySelectionHandler: (() -> Void)?
    private var selectAllHandler: (() -> Void)?
    private var scrollToTopHandler: (() -> Void)?
    private var scrollToBottomHandler: (() -> Void)?
    private var focusHandler: (() -> Void)?

    func bind(
        copySelection: @escaping () -> Void,
        selectAll: @escaping () -> Void,
        scrollToTop: @escaping () -> Void,
        scrollToBottom: @escaping () -> Void,
        focus: @escaping () -> Void
    ) {
        copySelectionHandler = copySelection
        selectAllHandler = selectAll
        scrollToTopHandler = scrollToTop
        scrollToBottomHandler = scrollToBottom
        focusHandler = focus
    }

    func copySelection() {
        copySelectionHandler?()
    }

    func selectAll() {
        selectAllHandler?()
    }

    func scrollToTop() {
        scrollToTopHandler?()
    }

    func scrollToBottom() {
        scrollToBottomHandler?()
    }

    func focusTranscript() {
        focusHandler?()
    }
}
