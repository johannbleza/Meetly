import Foundation

nonisolated struct CLIProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

nonisolated enum CLIProcessError: LocalizedError {
    case launchFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            "Couldn't start the AI command-line tool: \(message)"
        case .timedOut:
            "The AI command-line tool took too long to respond."
        }
    }
}

/// Runs a command-line tool with `input` on stdin. Prompts go through stdin rather than arguments
/// because transcripts can exceed the argument size limit and arguments are visible in `ps`.
nonisolated enum CLIProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        input: Data = Data(),
        timeout: TimeInterval
    ) async throws -> CLIProcessResult {
        let execution = CLIProcessExecution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    execution.start(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        workingDirectory: workingDirectory,
                        input: input,
                        timeout: timeout,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            execution.stop(reason: CancellationError())
        }
    }
}

/// Lock-guarded state for one child process; callbacks arrive on several dispatch queues.
private nonisolated final class CLIProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<CLIProcessResult, Error>?
    private var stopReason: Error?
    private var stdoutData = Data()
    private var stderrData = Data()

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        input: Data,
        timeout: TimeInterval,
        continuation: CheckedContinuation<CLIProcessResult, Error>
    ) {
        lock.lock()
        if let stopReason {
            lock.unlock()
            continuation.resume(throwing: stopReason)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // A child that exits before reading all of stdin must not kill Meetly with SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        do {
            try process.run()
        } catch {
            finish(.failure(CLIProcessError.launchFailed(error.localizedDescription)))
            return
        }

        lock.lock()
        self.process = process
        let stoppedDuringLaunch = stopReason != nil
        lock.unlock()
        if stoppedDuringLaunch {
            process.terminate()
        }

        // Drain both pipes concurrently so a full pipe buffer can't deadlock the child.
        readToEnd(stdoutPipe, group: group) { [self] data in stdoutData = data }
        readToEnd(stderrPipe, group: group) { [self] data in stderrData = data }

        DispatchQueue.global(qos: .userInitiated).async {
            let handle = stdinPipe.fileHandleForWriting
            try? handle.write(contentsOf: input)
            try? handle.close()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            stop(reason: CLIProcessError.timedOut)
        }

        group.notify(queue: .global(qos: .userInitiated)) { [self] in
            lock.lock()
            let reason = stopReason
            let result = CLIProcessResult(
                stdout: stdoutData,
                stderr: stderrData,
                exitCode: process.terminationStatus
            )
            lock.unlock()
            if let reason {
                finish(.failure(reason))
            } else {
                finish(.success(result))
            }
        }
    }

    /// Terminates the child, escalates to SIGKILL, then resumes the caller even if a grandchild
    /// is still holding the output pipes open.
    func stop(reason: Error) {
        lock.lock()
        if stopReason == nil {
            stopReason = reason
        }
        let process = process
        lock.unlock()

        guard let process, process.isRunning else { return }
        process.terminate()

        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [self] in
            finish(.failure(reason))
        }
    }

    private func readToEnd(_ pipe: Pipe, group: DispatchGroup, store: @escaping @Sendable (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            lock.lock()
            store(data)
            lock.unlock()
            group.leave()
        }
    }

    private func finish(_ result: Result<CLIProcessResult, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
