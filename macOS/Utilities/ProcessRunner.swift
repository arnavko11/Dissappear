import Foundation

struct ProcessResult: Sendable {
    var command: String
    var exitCode: Int32
    var standardOutput: String
    var standardError: String

    var succeeded: Bool { exitCode == 0 }

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(tool: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(tool, underlying):
            return "Could not run \(tool): \(underlying)"
        }
    }
}

/// Thin wrapper around Apple's command-line developer tools.
/// Every shell interaction in the app goes through here so that views and
/// view models never touch `Process` directly.
actor ProcessRunner {
    static let shared = ProcessRunner()

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock(); storage.append(data); lock.unlock()
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: storage, as: UTF8.self)
        }
    }

    @discardableResult
    func run(_ executable: String,
             _ arguments: [String],
             currentDirectory: URL? = nil,
             environment: [String: String]? = nil,
             onOutputLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            environment.forEach { merged[$0.key] = $0.value }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outBuffer = Buffer()
        let errBuffer = Buffer()
        let lineAccumulator = LineAccumulator(handler: onOutputLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outBuffer.append(data)
            lineAccumulator.consume(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errBuffer.append(data)
            lineAccumulator.consume(data)
        }

        let command = ([executable] + arguments).joined(separator: " ")

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let trailingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let trailingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !trailingOut.isEmpty { outBuffer.append(trailingOut); lineAccumulator.consume(trailingOut) }
                if !trailingErr.isEmpty { errBuffer.append(trailingErr); lineAccumulator.consume(trailingErr) }
                lineAccumulator.flush()
                continuation.resume(returning: ProcessResult(command: command,
                                                             exitCode: finished.terminationStatus,
                                                             standardOutput: outBuffer.text,
                                                             standardError: errBuffer.text))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ProcessRunnerError.launchFailed(tool: executable,
                                                                              underlying: error.localizedDescription))
            }
        }
    }

    /// Convenience for tools resolved through `xcrun`.
    @discardableResult
    func xcrun(_ arguments: [String],
               currentDirectory: URL? = nil,
               onOutputLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try await run("/usr/bin/xcrun", arguments, currentDirectory: currentDirectory, onOutputLine: onOutputLine)
    }
}

private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let handler: (@Sendable (String) -> Void)?

    init(handler: (@Sendable (String) -> Void)?) {
        self.handler = handler
    }

    func consume(_ data: Data) {
        guard let handler else { return }
        lock.lock()
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let range = pending.range(of: "\n") {
            lines.append(String(pending[pending.startIndex..<range.lowerBound]))
            pending.removeSubrange(pending.startIndex..<range.upperBound)
        }
        lock.unlock()
        lines.filter { !$0.isEmpty }.forEach(handler)
    }

    func flush() {
        guard let handler else { return }
        lock.lock()
        let remainder = pending
        pending = ""
        lock.unlock()
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { handler(remainder) }
    }
}
