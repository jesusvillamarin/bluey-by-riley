import XCTest
@testable import GooglyMac

@MainActor
final class ClaudeVoiceSessionTests: XCTestCase {
    private static let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#
    private static let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"Hi"}"#

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes an executable `/bin/sh` fake `claude` and returns its URL.
    private func fake(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("claude-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func session(_ script: String, timeout: TimeInterval = 10) throws -> ClaudeVoiceSession {
        let url = try fake(script)
        let session = ClaudeVoiceSession(binary: { url }, arguments: { [] }, workingDirectory: directory, activityTimeout: timeout)
        addTeardownBlock { await session.stop() }
        return session
    }

    private let replying = """
    while IFS= read -r line; do
      case "$line" in
        *control_request*) ;;
        *) echo '\(delta)'; echo '\(ok)' ;;
      esac
    done
    """

    func testAskStreamsAndReturnsResult() async throws {
        let session = try session(replying)
        var events: [ClaudeEvent] = []
        let reply = try await session.ask("hola") { events.append($0) }
        XCTAssertEqual(reply, "Hi")
        XCTAssertTrue(events.contains(.textDelta("Hi")))
        XCTAssertEqual(events.last, .result(text: "Hi", isError: false))
        XCTAssertEqual(session.recentTurns.map(\.user), ["hola"])
        XCTAssertEqual(session.recentTurns.map(\.reply), ["Hi"])
    }

    func testTwoTurnsUseOneProcess() async throws {
        let session = try session("""
        while IFS= read -r line; do
          echo "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$$\\"}"
        done
        """)
        let first = try await session.ask("a") { _ in }
        let second = try await session.ask("b") { _ in }
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    func testConcurrentAsksRunOneAtATime() async throws {
        let session = try session("""
        n=0
        while IFS= read -r line; do
          n=$((n+1))
          sleep 0.1
          echo "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$n\\"}"
        done
        """)
        async let first = session.ask("a") { _ in }
        async let second = session.ask("b") { _ in }
        let replies = try await [first, second]
        XCTAssertEqual(Set(replies), ["1", "2"])
    }

    func testPartialAndBatchedLines() async throws {
        // One printf writes two lines in a single read; the result line arrives in two halves.
        let session = try session("""
        while IFS= read -r line; do
          printf '%s\\n%s' '\(Self.delta)' '{"type":"result","subtype":"success",'
          sleep 0.2
          printf '%s\\n' '"is_error":false,"result":"joined"}'
        done
        """)
        let reply = try await session.ask("x") { _ in }
        XCTAssertEqual(reply, "joined")
    }

    func testMissingBinary() async {
        let session = ClaudeVoiceSession(binary: { nil }, arguments: { [] }, workingDirectory: directory)
        await assertAskThrows(session, .notInstalled)
    }

    func testProcessExitsImmediately() async throws {
        let session = try session("exit 1")
        await assertAskThrows(session, .exited)
    }

    func testInterrupt() async throws {
        // Answers after 2 s unless it reads a control_request first.
        let session = try session("""
        pending=""
        while IFS= read -r line; do
          case "$line" in
            *control_request*)
              [ -n "$pending" ] && kill $pending 2>/dev/null
              pending=""
              echo '{"type":"control_response"}'
              echo '{"type":"result","subtype":"error_during_execution","is_error":true}' ;;
            *)
              ( sleep 2 >/dev/null 2>&1; echo '\(Self.ok)' ) &
              pending=$! ;;
          esac
        done
        """)
        let started = Date()
        Task { try? await Task.sleep(nanoseconds: 100_000_000); session.interrupt() }
        await assertAskThrows(session, .interrupted)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testProcessSurvivesInterrupt() async throws {
        let session = try session("""
        while IFS= read -r line; do
          case "$line" in
            *control_request*) echo '{"type":"result","subtype":"error_during_execution","is_error":true}' ;;
            *interrupt-me*) ;;
            *) echo "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$$\\"}" ;;
          esac
        done
        """)
        let pid = try await session.ask("first") { _ in }
        Task { try? await Task.sleep(nanoseconds: 100_000_000); session.interrupt() }
        await assertAskThrows(session, .interrupted, text: "interrupt-me")
        let again = try await session.ask("second") { _ in }
        XCTAssertEqual(again, pid)
        XCTAssertEqual(session.recentTurns.map(\.user), ["first", "second"])
    }

    func testInterruptWithNoTurnIsNoOp() async throws {
        let session = try session(replying)
        session.interrupt()
        let reply = try await session.ask("x") { _ in }
        XCTAssertEqual(reply, "Hi")
    }

    func testStopDuringTurnThrows() async throws {
        let session = try session("while IFS= read -r line; do sleep 5; done")
        Task { try? await Task.sleep(nanoseconds: 100_000_000); session.stop() }
        let started = Date()
        await assertAskThrows(session, .interrupted)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testActivityResetsTimeout() async throws {
        // 12 deltas 0.1 s apart outlast the 0.6 s budget only because each line restarts it.
        let session = try session("""
        while IFS= read -r line; do
          for i in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 0.1; echo '\(Self.delta)'; done
          echo '\(Self.ok)'
        done
        """, timeout: 0.6)
        let reply = try await session.ask("x") { _ in }
        XCTAssertEqual(reply, "Hi")
    }

    func testSilentHangTimesOut() async throws {
        let session = try session("while IFS= read -r line; do sleep 5; done", timeout: 0.3)
        await assertAskThrows(session, .timedOut)
    }

    func testErrorResultFails() async throws {
        let session = try session("""
        while IFS= read -r line; do
          echo '{"type":"result","subtype":"success","is_error":true,"result":"usage limit reached"}'
        done
        """)
        await assertAskThrows(session, .failed("usage limit reached"))
        XCTAssertTrue(session.recentTurns.isEmpty)
    }

    func testRespawnReplaysRecentTurns() async throws {
        // Echoes the user's content as the result, then exits after one turn (printf keeps the JSON \\n escapes intact).
        let session = try session("""
        IFS= read -r line
        content=$(printf '%s' "$line" | sed 's/.*"content":"\\(.*\\)","role".*/\\1/')
        printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$content\\"}"
        """)
        let first = try await session.ask("a") { _ in }
        XCTAssertEqual(first, "a", "the very first spawn has no replay prefix")
        try await Task.sleep(nanoseconds: 400_000_000) // let the one-shot fake exit
        let second = try await session.ask("b") { _ in }
        XCTAssertTrue(second.hasPrefix("Earlier in this conversation:"), second)
        XCTAssertTrue(second.contains("User: a"), second)
        XCTAssertTrue(second.contains("You: a"), second)
        XCTAssertTrue(second.hasSuffix("b"), second)
    }

    func testStopClearsHistoryAndReplay() async throws {
        let session = try session("""
        while IFS= read -r line; do
          content=$(printf '%s' "$line" | sed 's/.*"content":"\\(.*\\)","role".*/\\1/')
          printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$content\\"}"
        done
        """)
        _ = try await session.ask("a") { _ in }
        session.stop()
        XCTAssertTrue(session.recentTurns.isEmpty)
        let reply = try await session.ask("b") { _ in }
        XCTAssertEqual(reply, "b")
    }

    func testRecentTurnsKeepsLastTen() async throws {
        let session = try session(replying)
        for i in 0..<12 { _ = try await session.ask("q\(i)") { _ in } }
        XCTAssertEqual(session.recentTurns.count, 10)
        XCTAssertEqual(session.recentTurns.first?.user, "q2")
        XCTAssertEqual(session.recentTurns.last?.user, "q11")
    }

    func testStopCancelsQueuedAsk() async throws {
        // Each spawn appends its PID to a file; a queued ask must not cause a second spawn after stop().
        let spawns = directory.appendingPathComponent("spawns")
        let session = try session("""
        echo $$ >> '\(spawns.path)'
        while IFS= read -r line; do sleep 5; done
        """)
        let started = Date()
        let first = Task { try await session.ask("a") { _ in } }
        let second = Task { try await session.ask("b") { _ in } }
        try await Task.sleep(nanoseconds: 200_000_000)
        session.stop()
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("expected .interrupted")
            } catch {
                XCTAssertEqual(error as? ClaudeVoiceSession.Failure, .interrupted)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await Task.sleep(nanoseconds: 300_000_000)
        let count = ((try? String(contentsOf: spawns, encoding: .utf8)) ?? "").split(separator: "\n").count
        XCTAssertEqual(count, 1, "stop() must not let a queued ask respawn claude")
        XCTAssertTrue(session.recentTurns.isEmpty)
    }

    func testAskAfterStopStartsFresh() async throws {
        let session = try session(replying)
        session.stop()
        let reply = try await session.ask("x") { _ in }
        XCTAssertEqual(reply, "Hi")
    }

    func testWarmUpRespawnStillReplays() async throws {
        // Echoes the user's content, one turn per process.
        let session = try session("""
        IFS= read -r line
        content=$(printf '%s' "$line" | sed 's/.*"content":"\\(.*\\)","role".*/\\1/')
        printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$content\\"}"
        """)
        _ = try await session.ask("a") { _ in }
        try await Task.sleep(nanoseconds: 400_000_000) // the one-shot fake exits
        session.warmUp() // respawns while idle
        let second = try await session.ask("b") { _ in }
        XCTAssertTrue(second.hasPrefix("Earlier in this conversation:"), second)
        XCTAssertTrue(second.contains("User: a"), second)
    }

    func testSuccessResultAfterInterruptStillInterrupted() async throws {
        let session = try session("""
        while IFS= read -r line; do
          case "$line" in
            *control_request*) echo '\(Self.ok)' ;;
          esac
        done
        """)
        Task { try? await Task.sleep(nanoseconds: 100_000_000); session.interrupt() }
        await assertAskThrows(session, .interrupted)
        XCTAssertTrue(session.recentTurns.isEmpty)
    }

    func testGrandchildHoldingStdoutFallsBackToExit() async throws {
        // The fake exits at once but a background job keeps its stdout open, so there is no EOF.
        let session = try session("""
        IFS= read -r line
        sleep 4 &
        exit 0
        """)
        let started = Date()
        await assertAskThrows(session, .exited)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5)
    }

    func testShellLookupTakesLastAbsoluteLine() throws {
        let shell = try fake("echo 'banner'\necho /bin/sh\necho 'trailing noise'\necho /bin/sh")
        XCTAssertEqual(ClaudeBinary.runShellLookup(shell: shell.path), "/bin/sh")
    }

    func testShellLookupBudgetKillsShellThatIgnoresSigterm() throws {
        // Ignored signals survive exec, so this `sleep` ignores SIGTERM like an interactive zsh does.
        let shell = try fake("trap '' TERM\nexec sleep 30")
        let started = Date()
        XCTAssertNil(ClaudeBinary.runShellLookup(shell: shell.path, budget: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testFailureTexts() {
        XCTAssertEqual(ClaudeVoiceSession.Failure.notInstalled.errorDescription, "Install Claude Code to use Subscription voice, or switch Voice to Fast in the menu bar.")
        XCTAssertEqual(ClaudeVoiceSession.Failure.exited.errorDescription, "Claude stopped. Open Terminal, run `claude` and make sure you're signed in.")
        XCTAssertEqual(ClaudeVoiceSession.Failure.timedOut.errorDescription, "Claude took too long. Try again.")
        XCTAssertEqual(ClaudeVoiceSession.Failure.failed("usage limit reached").errorDescription, "Claude couldn't answer: usage limit reached")
    }

    func testLocateIsCheapAndFindsExecutables() {
        // File checks only; must return quickly and never shell out.
        let started = Date()
        _ = ClaudeBinary.locate()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    private func assertAskThrows(_ session: ClaudeVoiceSession, _ expected: ClaudeVoiceSession.Failure, text: String = "x",
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let reply = try await session.ask(text) { _ in }
            XCTFail("expected \(expected), got reply \(reply)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClaudeVoiceSession.Failure, expected, file: file, line: line)
        }
    }
}
