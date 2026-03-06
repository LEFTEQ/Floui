import Foundation

struct ShellLaunchConfiguration: Equatable, Sendable {
    var command: [String]
    var environment: [String: String]
}

final class ShellIntegrationController {
    private let supportDirectoryURL: URL
    private let homeDirectoryURL: URL
    private let fileManager: FileManager

    init(
        supportDirectoryURL: URL = ShellIntegrationController.defaultSupportDirectoryURL,
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.supportDirectoryURL = supportDirectoryURL
        self.homeDirectoryURL = homeDirectoryURL
        self.fileManager = fileManager
    }

    func prepare(command: [String], environment: [String: String] = [:]) throws -> ShellLaunchConfiguration {
        guard let shell = detectShell(command: command) else {
            return ShellLaunchConfiguration(command: command, environment: environment)
        }

        try prepareSupportFiles()

        var mergedEnvironment = environment
        mergedEnvironment["FLOUI_SHELL_INTEGRATION"] = "1"
        mergedEnvironment["TERM_PROGRAM"] = "Floui"

        switch shell {
        case let .zsh(executable):
            mergedEnvironment["ZDOTDIR"] = zshSupportDirectoryURL.path
            mergedEnvironment["FLOUI_ZSH_INTEGRATION_FILE"] = zshIntegrationFileURL.path
            return ShellLaunchConfiguration(
                command: [executable, "-i"],
                environment: mergedEnvironment
            )

        case let .bash(executable):
            mergedEnvironment["FLOUI_BASH_INTEGRATION_FILE"] = bashIntegrationFileURL.path
            return ShellLaunchConfiguration(
                command: [executable, "--init-file", bashInitFileURL.path, "-i"],
                environment: mergedEnvironment
            )
        }
    }

    private func detectShell(command: [String]) -> SupportedShell? {
        let resolvedCommand = command.isEmpty ? ["/bin/zsh"] : command

        guard let first = resolvedCommand.first else {
            return nil
        }

        if first.hasSuffix("/env") || first == "env" {
            let remainder = Array(resolvedCommand.dropFirst())
            guard let executable = remainder.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) else {
                return nil
            }
            let executableIndex = remainder.firstIndex(of: executable) ?? 0
            let shellArguments = Array(remainder.dropFirst(executableIndex + 1))
            return detectShellExecutable(executable, arguments: shellArguments)
        }

        return detectShellExecutable(first, arguments: Array(resolvedCommand.dropFirst()))
    }

    private func detectShellExecutable(_ executable: String, arguments: [String]) -> SupportedShell? {
        guard supportsInteractiveIntegration(arguments: arguments) else {
            return nil
        }

        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        switch name {
        case "zsh":
            return .zsh(executable)
        case "bash":
            return .bash(executable)
        default:
            return nil
        }
    }

    private func supportsInteractiveIntegration(arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "-c" || argument == "-lc" || argument == "--command" {
                return false
            }

            if !argument.hasPrefix("-") {
                return false
            }
        }

        return true
    }

    private func prepareSupportFiles() throws {
        try fileManager.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: zshSupportDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bashSupportDirectoryURL, withIntermediateDirectories: true)

        try writeIfNeeded(zshIntegrationSource, to: zshIntegrationFileURL)
        try writeIfNeeded(zshRcSource, to: zshSupportDirectoryURL.appendingPathComponent(".zshrc"))
        try writeIfNeeded(bashIntegrationSource, to: bashIntegrationFileURL)
        try writeIfNeeded(bashInitSource, to: bashInitFileURL)
    }

    private func writeIfNeeded(_ content: String, to url: URL) throws {
        let data = Data(content.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private var zshSupportDirectoryURL: URL {
        supportDirectoryURL.appendingPathComponent("zsh", isDirectory: true)
    }

    private var bashSupportDirectoryURL: URL {
        supportDirectoryURL.appendingPathComponent("bash", isDirectory: true)
    }

    private var zshIntegrationFileURL: URL {
        supportDirectoryURL.appendingPathComponent("floui.zsh", isDirectory: false)
    }

    private var bashIntegrationFileURL: URL {
        supportDirectoryURL.appendingPathComponent("floui.bash", isDirectory: false)
    }

    private var bashInitFileURL: URL {
        bashSupportDirectoryURL.appendingPathComponent("floui.bashrc", isDirectory: false)
    }

    private var zshRcSource: String {
        """
        if [ -f "\(homeDirectoryURL.appendingPathComponent(".zshrc").path)" ]; then
          source "\(homeDirectoryURL.appendingPathComponent(".zshrc").path)"
        fi

        if [ -n "$FLOUI_ZSH_INTEGRATION_FILE" ] && [ -f "$FLOUI_ZSH_INTEGRATION_FILE" ]; then
          source "$FLOUI_ZSH_INTEGRATION_FILE"
        fi
        """
    }

    private var bashInitSource: String {
        """
        if [ -f "\(homeDirectoryURL.appendingPathComponent(".bashrc").path)" ]; then
          source "\(homeDirectoryURL.appendingPathComponent(".bashrc").path)"
        fi

        if [ -n "$FLOUI_BASH_INTEGRATION_FILE" ] && [ -f "$FLOUI_BASH_INTEGRATION_FILE" ]; then
          source "$FLOUI_BASH_INTEGRATION_FILE"
        fi
        """
    }

    private var zshIntegrationSource: String {
        """
        function _floui_git_branch() {
          if command -v git >/dev/null 2>&1; then
            git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true
          fi
        }

        function _floui_precmd() {
          printf '__FLOUI__CWD\\t%s\\n' "$PWD"
          printf '__FLOUI__BRANCH\\t%s\\n' "$(_floui_git_branch)"
          printf '__FLOUI__IDLE\\n'
        }

        function _floui_preexec() {
          printf '__FLOUI__RUN\\t%s\\n' "$1"
        }

        typeset -ga precmd_functions
        typeset -ga preexec_functions
        precmd_functions+=(_floui_precmd)
        preexec_functions+=(_floui_preexec)
        _floui_precmd
        """
    }

    private var bashIntegrationSource: String {
        """
        __floui_internal=0

        __floui_git_branch() {
          if command -v git >/dev/null 2>&1; then
            git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true
          fi
        }

        __floui_precmd() {
          __floui_internal=1
          printf '__FLOUI__CWD\\t%s\\n' "$PWD"
          printf '__FLOUI__BRANCH\\t%s\\n' "$(__floui_git_branch)"
          printf '__FLOUI__IDLE\\n'
          __floui_internal=0
        }

        __floui_preexec() {
          if [ "$__floui_internal" = "1" ]; then
            return
          fi
          printf '__FLOUI__RUN\\t%s\\n' "$BASH_COMMAND"
        }

        trap '__floui_preexec' DEBUG
        PROMPT_COMMAND='__floui_precmd'
        __floui_precmd
        """
    }

    static var defaultSupportDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Floui/ShellIntegration", isDirectory: true)
    }
}

private enum SupportedShell: Equatable {
    case zsh(String)
    case bash(String)
}
