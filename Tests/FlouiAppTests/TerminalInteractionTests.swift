@testable import FlouiApp
import Testing

@Test("Transcript search navigator counts matches and cycles through results")
func transcriptSearchNavigatorCyclesMatches() {
    let transcript = """
    pnpm run dev
    server ready
    pnpm test
    """

    let matches = TerminalTranscriptSearchNavigator.matchRanges(
        in: transcript,
        query: "pnpm"
    )

    #expect(matches.count == 2)
    #expect(TerminalTranscriptSearchNavigator.normalizedSelection(current: nil, matchCount: matches.count) == 0)
    #expect(TerminalTranscriptSearchNavigator.nextSelection(after: 0, matchCount: matches.count) == 1)
    #expect(TerminalTranscriptSearchNavigator.nextSelection(after: 1, matchCount: matches.count) == 0)
    #expect(TerminalTranscriptSearchNavigator.previousSelection(before: 0, matchCount: matches.count) == 1)
}

@Test("Transcript search navigator ignores blank queries")
func transcriptSearchNavigatorIgnoresBlankQueries() {
    #expect(TerminalTranscriptSearchNavigator.matchRanges(in: "hello", query: "").isEmpty)
    #expect(TerminalTranscriptSearchNavigator.normalizedSelection(current: 4, matchCount: 0) == nil)
}

@Test("Command history preserves the in-progress draft while navigating recent commands")
func commandHistoryPreservesDraft() {
    var history = TerminalCommandHistoryState()
    let recentCommands = ["pnpm run dev", "docker compose logs -f app", "swift test"]

    let first = history.moveBackward(currentInput: "git status", recentCommands: recentCommands)
    let second = history.moveBackward(currentInput: first, recentCommands: recentCommands)
    let third = history.moveForward(currentInput: second, recentCommands: recentCommands)
    let fourth = history.moveForward(currentInput: third, recentCommands: recentCommands)

    #expect(first == "pnpm run dev")
    #expect(second == "docker compose logs -f app")
    #expect(third == "pnpm run dev")
    #expect(fourth == "git status")
}
