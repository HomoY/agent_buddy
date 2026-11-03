import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: Data
    public let errorOutput: Data

    public var text: String { String(decoding: output, as: UTF8.self) }
}

/// Runs a program to its end, with a time limit.
public enum ProcessRunner {
    private final class Collected: @unchecked Sendable {
        var output = Data()
        var errorOutput = Data()
    }

    /// `input`, when given, is written to the program's stdin, which is then closed.
    public static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
        directory: URL? = nil, input: Data? = nil, timeout: TimeInterval = 10
    ) -> ProcessResult? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? Environment.engineEnvironment()
        if let directory {
            process.currentDirectoryURL = directory
        }
        let output = Pipe()
        let errorOutput = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        process.standardOutput = output
        process.standardError = errorOutput
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if let input, let inputPipe {
            DispatchQueue.global().async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        let collected = Collected()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            collected.output = output.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            collected.errorOutput = errorOutput.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard readers.wait(timeout: .now() + 2) == .success else { return nil }
        return ProcessResult(status: process.terminationStatus, output: collected.output, errorOutput: collected.errorOutput)
    }
}

/// A child process spoken to in JSON lines over stdin and stdout, as Claude
/// Code's stream-json mode and Codex's app-server expect.
public final class JSONLineProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var messages: [JSON] = []
    private var outputEnded = false
    private var errorText = Data()

    public init(executable: URL, arguments: [String], environment: [String: String], directory: URL?) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory {
            process.currentDirectoryURL = directory
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
    }

    public func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            self?.receive(data)
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.keepError(data)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            let name = process.executableURL?.lastPathComponent ?? "the engine"
            throw ReadError("Couldn't start \(name): \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data) {
        condition.lock()
        if data.isEmpty {
            outputEnded = true
        } else {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let value = JSON.parse(line) {
                    messages.append(value)
                }
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    private func keepError(_ data: Data) {
        condition.lock()
        if errorText.count < 16_384 {
            errorText.append(data)
        }
        condition.unlock()
    }

    public func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// The next message, or nil once the output ends or the deadline passes.
    public func next(until deadline: Date) -> JSON? {
        condition.lock()
        defer { condition.unlock() }
        while messages.isEmpty && !outputEnded {
            if !condition.wait(until: deadline) {
                break
            }
        }
        return messages.isEmpty ? nil : messages.removeFirst()
    }

    public var hasEnded: Bool {
        condition.lock()
        defer { condition.unlock() }
        return outputEnded || !process.isRunning
    }

    /// The start of what the engine wrote to stderr, for error messages.
    public var errorPreview: String? {
        condition.lock()
        let text = String(decoding: errorText, as: UTF8.self)
        condition.unlock()
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let line, !line.isEmpty else { return nil }
        return String(line.prefix(200))
    }

    public func stop() {
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    deinit {
        stop()
    }
}
