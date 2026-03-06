@testable import FlouiApp
import Foundation
import Testing

@Test("Shell integration planner prepares interactive zsh launches and support files")
func shellIntegrationPlannerConfiguresZsh() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("export DEV=1\n".utf8).write(to: home.appendingPathComponent(".zshrc"))

    let controller = ShellIntegrationController(
        supportDirectoryURL: support,
        homeDirectoryURL: home
    )

    let launch = try controller.prepare(command: ["/bin/zsh"], environment: ["A": "1"])

    #expect(launch.command == ["/bin/zsh", "-i"])
    #expect(launch.environment["A"] == "1")
    #expect(launch.environment["ZDOTDIR"] == support.appendingPathComponent("zsh", isDirectory: true).path)
    #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("zsh/.zshrc").path))
    #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("floui.zsh").path))
}

@Test("Shell integration planner leaves scripted commands untouched")
func shellIntegrationPlannerLeavesScriptCommandsUntouched() throws {
    let controller = ShellIntegrationController(
        supportDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
        homeDirectoryURL: FileManager.default.temporaryDirectory
    )

    let launch = try controller.prepare(command: ["/bin/zsh", "-lc", "echo hello"], environment: ["A": "1"])

    #expect(launch.command == ["/bin/zsh", "-lc", "echo hello"])
    #expect(launch.environment == ["A": "1"])
}
