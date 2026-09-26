import Foundation
import Synchronization

/// The `th` command line for a request. Text goes in on standard input (so any text is safe,
/// however it starts); a page goes in `-u`.
nonisolated enum THArguments {
    /// `th`'s arguments. `--report-start` makes `th` print a line when the voice starts.
    static func arguments(for request: SpeechRequest) -> [String] {
        var arguments = ["--always-on-top", "--report-start"]
        if let voice = request.voice { arguments += ["-v", voice] }
        if let mood = request.mood { arguments += ["-m", mood] }
        if case .url(let url) = request.source { arguments += ["-u", url.absoluteString] }
        return arguments
    }

    /// What to write to `th`'s standard input, if anything.
    static func standardInput(for request: SpeechRequest) -> String? {
        if case .text(let text) = request.source { text } else { nil }
    }

    /// The line `th --report-start` prints on standard output when the voice starts.
    static let startedLine = "started"

    /// The message to show for a `th` that failed: its `th: …` error line, as a sentence.
    static func failureMessage(fromStandardError errorOutput: String, status: Int32) -> String {
        let line = errorOutput.split(separator: "\n").first { $0.hasPrefix("th: ") }
        guard let line else { return "Talking Head couldn't speak (th exited with status \(status))." }
        var message = String(line.dropFirst("th: ".count)).trimmingCharacters(in: .whitespaces)
        message = message.prefix(1).uppercased() + message.dropFirst()
        if let last = message.last, !".!?".contains(last) { message += "." }
        return message
    }
}

/// Speaks by running Talking Head's `th`: the face shows, speaks, and quits when done, so the
/// process ending is the end of the speech. Exit status 2 means `th` couldn't speak, and its
/// standard error says why.
actor THProcessSpeaker: Speaker {
    private struct Exit: Sendable {
        var status: Int32
        var errorOutput: String
    }

    private let executable: URL
    private var process: Process?
    /// Processes ended by `stop`, so their exit counts as stopped rather than failed.
    private var stopped: Set<ObjectIdentifier> = []

    init(executable: URL) {
        self.executable = executable
    }

    func start(_ request: SpeechRequest) async throws -> SpeechHandle {
        let process = Process()
        process.executableURL = executable
        process.arguments = THArguments.arguments(for: request)
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = THArguments.standardInput(for: request) == nil ? FileHandle.nullDevice : input
        // Never the server's own standard output, which carries only JSON-RPC.
        process.standardOutput = output
        process.standardError = errors

        // Read both pipes as they fill, so a chatty process can't block on a full pipe. Neither
        // is read to its end: a child of `th` could hold them open after `th` has gone.
        let errorData = Mutex(Data())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errorData.withLock { $0.append(data) }
            }
        }
        // The first of: the start line on standard output (true), or the process ending (false).
        let (firsts, reportFirst) = AsyncStream.makeStream(of: Bool.self)
        let received = Mutex(Data())
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = received.withLock { buffer in
                buffer.append(data)
                return String(decoding: buffer, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            }
            // Only complete lines (the last piece may still be arriving).
            if lines.dropLast().contains(where: { $0 == THArguments.startedLine }) {
                reportFirst.yield(true)
            }
        }
        let (exits, reportExit) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { ended in
            reportExit.yield(ended.terminationStatus)
            reportExit.finish()
            reportFirst.yield(false)
            reportFirst.finish()
        }
        let exited = Task { () -> Exit in
            var status: Int32 = 0
            for await code in exits { status = code }
            // A failed `th` wrote why just before it exited; let that reach us.
            if status != 0 { try? await Task.sleep(for: .milliseconds(100)) }
            return Exit(status: status, errorOutput: String(decoding: errorData.withLock { $0 }, as: UTF8.self))
        }

        do {
            try process.run()
        } catch {
            throw SpeechFailure("Talking Head couldn't start: \(error.localizedDescription)")
        }
        self.process = process

        if let text = THArguments.standardInput(for: request) {
            let handle = input.fileHandleForWriting
            Task.detached {
                try? handle.write(contentsOf: Data(text.utf8))
                try? handle.close()
            }
        }

        var hasStarted = false
        for await started in firsts {
            hasStarted = started
            break
        }

        let id = ObjectIdentifier(process)
        if hasStarted {
            return SpeechHandle { [self] in
                let exit = await exited.value
                return try await self.ending(of: id, status: exit.status, errorOutput: exit.errorOutput)
            }
        }
        // Ended before the voice started: it failed, was stopped, or had nothing to say.
        let exit = await exited.value
        let end = try ending(of: id, status: exit.status, errorOutput: exit.errorOutput)
        return SpeechHandle { end }
    }

    func stop() async {
        guard let process, process.isRunning else { return }
        stopped.insert(ObjectIdentifier(process))
        process.terminate()
    }

    /// How a `th` process's exit ends its speech.
    private func ending(of id: ObjectIdentifier, status: Int32, errorOutput: String) throws -> SpeechEnd {
        if process.map(ObjectIdentifier.init) == id { process = nil }
        if stopped.remove(id) != nil { return .stopped }
        guard status == 0 else {
            throw SpeechFailure(THArguments.failureMessage(fromStandardError: errorOutput, status: status))
        }
        return .finished
    }
}
