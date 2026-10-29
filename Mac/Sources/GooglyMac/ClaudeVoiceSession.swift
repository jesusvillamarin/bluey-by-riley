import Foundation

/// Finds the `claude` CLI. `locate()` is file checks only; `lookUpInShell()` asks the login shell once at launch.
enum ClaudeBinary {
    private static let shellPath = Locked<String?>(nil)

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [shellPath.value, home + "/.local/bin/claude", home + "/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Runs `$SHELL -ilc 'command -v claude'` off the main thread (5 s budget) and remembers the answer for `locate()`.
    static func lookUpInShell() async {
        guard shellPath.value == nil else { return }
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: runShellLookup()) }
        }
        if let found { shellPath.value = found }
    }

    /// Blocking. Interactive shells ignore SIGTERM and rc files can leave background jobs holding the pipe,
    /// so the deadline is enforced with SIGKILL and by not waiting for EOF past it.
    static func runShellLookup(shell: String? = nil, budget: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "command -v claude"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let collected = Locked(Data())
        let finished = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; finished.signal() } else { collected.value.append(data) }
        }
        // If the shell exits but a background job keeps the pipe open, don't wait out the whole budget.
        process.terminationHandler = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { finished.signal() }
        }
        guard (try? process.run()) != nil else { return nil }
        if finished.wait(timeout: .now() + budget) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        output.fileHandleForReading.readabilityHandler = nil
        // Interactive shells may print banners; the path is the last absolute line.
        let path = String(decoding: collected.value, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }
}

/// A value read and written from any thread.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        _modify { lock.lock(); defer { lock.unlock() }; yield &stored }
    }
}

/// One warm `claude -p` process per awake session. Questions go in as stream-json lines and answers stream
/// back through `onEvent`; the process keeps its own memory between questions.
@MainActor
final class ClaudeVoiceSession {
    enum Failure: LocalizedError, Equatable {
        case notInstalled, exited, timedOut, interrupted
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Install Claude Code to use Subscription voice, or switch Voice to Fast in the menu bar."
            case .exited: "Claude stopped. Open Terminal, run `claude` and make sure you're signed in."
            case .timedOut: "Claude took too long. Try again."
            case .interrupted: "Interrupted."
            case .failed(let text): "Claude couldn't answer: \(text)"
            }
        }
    }

    /// The question in flight; cleared the moment it ends, which is what keeps it from ending twice.
    private final class Turn {
        let user: String
        let onEvent: (ClaudeEvent) -> Void
        let continuation: CheckedContinuation<String, Error>
        var interrupted = false
        var timer: Task<Void, Never>?
        init(user: String, onEvent: @escaping (ClaudeEvent) -> Void, continuation: CheckedContinuation<String, Error>) {
            self.user = user
            self.onEvent = onEvent
            self.continuation = continuation
        }
    }

    private static let maxRecentTurns = 10

    private let binary: () -> URL?
    private let arguments: () -> [String]
    private let workingDirectory: URL
    private let activityTimeout: TimeInterval

    private var process: Process?
    private var output: Pipe?
    private var input: FileHandle?
    private var buffer = Data()
    private var turn: Turn?
    private var hasSpawned = false
    private var needsReplay = false
    /// Bumped by `stop()`; asks that started before it end with `.interrupted` instead of running or recording.
    private var generation = 0
    private var busy = false
    private var queue: [CheckedContinuation<Bool, Never>] = []

    private(set) var recentTurns: [(user: String, reply: String)] = []

    init(binary: @escaping () -> URL? = ClaudeBinary.locate, arguments: @escaping () -> [String], workingDirectory: URL,
         activityTimeout: TimeInterval = 90) {
        self.binary = binary
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.activityTimeout = activityTimeout
    }

    /// Starts the process ahead of the first question so it's ready; failures surface on `ask`.
    func warmUp() {
        try? ensureRunning()
    }

    func ask(_ text: String, onEvent: @escaping (ClaudeEvent) -> Void) async throws -> String {
        let started = generation
        guard await acquire() else { throw Failure.interrupted }
        defer { release() }
        guard started == generation else { throw Failure.interrupted }
        try ensureRunning()
        var message = text
        let replay = needsReplay
        needsReplay = false
        if replay, !recentTurns.isEmpty {
            let lines = recentTurns.map { "User: \($0.user)\nYou: \($0.reply)" }.joined(separator: "\n")
            message = "Earlier in this conversation:\n" + lines + "\n\n" + text
        }
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let turn = Turn(user: text, onEvent: onEvent, continuation: continuation)
            self.turn = turn
            armTimer(turn)
            if !write(ClaudeStream.userLine(message)) {
                discardProcess()
                finish(turn, .failure(Failure.exited))
            }
        }
        guard started == generation else { throw Failure.interrupted }
        recentTurns.append((user: text, reply: reply))
        if recentTurns.count > Self.maxRecentTurns { recentTurns.removeFirst(recentTurns.count - Self.maxRecentTurns) }
        return reply
    }

    /// Cuts the answer in flight short; that `ask` throws `.interrupted`. The process stays warm for the next one.
    func interrupt() {
        guard let turn, !turn.interrupted else { return }
        turn.interrupted = true
        _ = write(ClaudeStream.interruptLine(id: UUID().uuidString))
    }

    /// Kills the process and forgets the conversation.
    func stop() {
        discardProcess()
        hasSpawned = false
        needsReplay = false
        recentTurns = []
        generation += 1
        if let turn { finish(turn, .failure(Failure.interrupted)) }
        let waiting = queue
        queue = []
        for waiter in waiting { waiter.resume(returning: false) }
    }

    // MARK: Serial asks

    /// False when `stop()` woke this waiter without handing it the slot.
    private func acquire() async -> Bool {
        if !busy { busy = true; return true }
        return await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume(returning: true) }
    }

    // MARK: The process

    /// Spawns if needed. Replacing a process that had died sets `needsReplay` so the next ask carries the history.
    private func ensureRunning() throws {
        if process != nil { return }
        guard let url = binary() else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments()
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["CLAUDECODE"] = nil
        env["PATH"] = url.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in
                guard let self, let process else { return }
                if data.isEmpty { self.ended(process) } else { self.received(data, from: process) }
            }
        }
        // EOF on stdout is what normally ends the turn (it arrives after every chunk). This is only the fallback
        // for a grandchild that keeps stdout open after claude exits.
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.ended(process)
            }
        }
        do { try process.run() } catch { throw Failure.exited }
        // A write to a dead child must throw, not raise SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        if hasSpawned { needsReplay = true }
        hasSpawned = true
        self.process = process
        output = stdout
        input = stdin.fileHandleForWriting
        buffer = Data()
    }

    /// Forgets the current process without reporting anything; its handlers become no-ops.
    private func discardProcess() {
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        output = nil
        input = nil
        buffer = Data()
    }

    private func ended(_ process: Process) {
        guard process === self.process else { return }
        discardProcess()
        if let turn { finish(turn, .failure(Failure.exited)) }
    }

    private func write(_ line: String) -> Bool {
        guard let input else { return false }
        return (try? input.write(contentsOf: Data(line.utf8))) != nil
    }

    // MARK: Reading

    private func received(_ data: Data, from process: Process) {
        guard process === self.process else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { handle(line) }
        }
    }

    private func handle(_ line: String) {
        guard let turn else { return }
        armTimer(turn)
        let event = ClaudeStream.parse(line)
        turn.onEvent(event)
        guard case .result(let text, let isError) = event else { return }
        if turn.interrupted {
            finish(turn, .failure(Failure.interrupted))
        } else if isError {
            finish(turn, .failure(Failure.failed(text)))
        } else {
            finish(turn, .success(text))
        }
    }

    // MARK: Ending a turn

    private func armTimer(_ turn: Turn) {
        turn.timer?.cancel()
        let timeout = activityTimeout
        turn.timer = Task { @MainActor [weak self, weak turn] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, let turn, self.turn === turn else { return }
            self.discardProcess()
            self.finish(turn, .failure(Failure.timedOut))
        }
    }

    private func finish(_ turn: Turn, _ result: Result<String, Error>) {
        guard self.turn === turn else { return }
        self.turn = nil
        turn.timer?.cancel()
        turn.continuation.resume(with: result)
    }
}
