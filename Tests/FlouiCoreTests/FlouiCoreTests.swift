import FlouiCore
import Foundation
import Testing

@Test("TerminalSessionID round-trips via Codable")
func terminalSessionIDCodableRoundTrip() throws {
    let original = TerminalSessionID(rawValue: UUID())

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TerminalSessionID.self, from: data)

    #expect(decoded == original)
}

@Test("BrowserLaunchRequest retains debugging configuration")
func browserLaunchRequestConfiguration() {
    let request = BrowserLaunchRequest(
        profileName: "floui-dev",
        urls: ["https://example.com"],
        enableRemoteDebugging: true,
        remoteDebuggingPort: 9333
    )

    #expect(request.profileName == "floui-dev")
    #expect(request.enableRemoteDebugging)
    #expect(request.remoteDebuggingPort == 9333)
}

@Test("SystemClock now increases over time")
func systemClockMonotonic() async throws {
    let clock = SystemClock()
    let start = clock.now
    try await clock.sleep(for: 0.01)
    let end = clock.now

    #expect(end >= start)
}
