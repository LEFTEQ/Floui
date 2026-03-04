import Foundation
import StatusPills

@main
struct FlouiCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("floui-cli error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "run" else {
            printUsage()
            Foundation.exit(2)
            return
        }
        args.removeFirst()

        guard let source = args.first else {
            throw CLIError.invalidArguments("missing source")
        }
        args.removeFirst()

        let workspaceID = try value(for: "--workspace", in: &args)
        let paneID = try value(for: "--pane", in: &args)
        let taskID = (try? value(for: "--task", in: &args)) ?? UUID().uuidString

        let separatorIndex = args.firstIndex(of: "--")
        let command: [String]
        if let separatorIndex {
            command = Array(args.suffix(from: args.index(after: separatorIndex)))
        } else {
            command = args
        }

        guard let executable = command.first else {
            throw CLIError.invalidArguments("missing command after --")
        }

        let codec = StatusEventCodec()
        try emit(
            codec: codec,
            event: StatusEvent(
                event: .taskStarted,
                workspaceID: workspaceID,
                paneID: paneID,
                taskID: taskID,
                source: source,
                timestamp: Date(),
                severity: .info,
                message: "task started"
            )
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        let completionMessage = process.terminationStatus == 0 ? "task completed" : "task failed"
        try emit(
            codec: codec,
            event: StatusEvent(
                event: .taskDone,
                workspaceID: workspaceID,
                paneID: paneID,
                taskID: taskID,
                source: source,
                timestamp: Date(),
                severity: process.terminationStatus == 0 ? .info : .critical,
                message: completionMessage,
                progress: 1,
                metadata: ["exitCode": "\(process.terminationStatus)"]
            )
        )

        Foundation.exit(process.terminationStatus)
    }

    private static func emit(codec: StatusEventCodec, event: StatusEvent) throws {
        let line = try codec.encode(event)
        print(line)

        if let path = ProcessInfo.processInfo.environment["FLOUI_STATUS_FILE"] {
            let url = URL(fileURLWithPath: path)
            let text = line + "\n"
            if FileManager.default.fileExists(atPath: path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
                try handle.close()
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func value(for flag: String, in args: inout [String]) throws -> String {
        guard let index = args.firstIndex(of: flag) else {
            throw CLIError.invalidArguments("missing \(flag)")
        }

        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else {
            throw CLIError.invalidArguments("missing value for \(flag)")
        }

        let value = args[valueIndex]
        args.remove(at: valueIndex)
        args.remove(at: index)
        return value
    }

    private static func printUsage() {
        let usage = """
        Usage:
          floui-cli run <source> --workspace <workspace-id> --pane <pane-id> [--task <task-id>] -- <command> [args...]

        Example:
          floui-cli run claude-code --workspace default --pane pill-claude -- /usr/bin/env echo hello
        """
        print(usage)
    }
}

enum CLIError: Error {
    case invalidArguments(String)
}
