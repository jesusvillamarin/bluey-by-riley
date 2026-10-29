import XCTest
import GooglyShared
@testable import GooglyMac

@MainActor
final class SubscriptionVoiceTests: XCTestCase {
    private static let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#
    private static let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"Hi"}"#

    private var directory: URL!
    /// Everything the voice did, in order: sent packet commands and "SLEEP".
    private var log: [String] = []
    private var sent: [Packet] = []
    private var captions: [(text: String?, done: Bool)] = []
    private var mode: VoiceMode = .subscription
    private var state: String?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = []; sent = []; captions = []; mode = .subscription; state = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func voice(_ script: String?) throws -> SubscriptionVoice {
        let url = try script.map { try FakeClaude.script($0, in: directory) }
        let session = ClaudeVoiceSession(binary: { url }, arguments: { [] }, workingDirectory: directory, activityTimeout: 10)
        addTeardownBlock { await session.stop() }
        return SubscriptionVoice(session: session, tokens: ElevenLabsTokens(mint: { "token" }),
                                 mode: { [unowned self] in self.mode }, state: { [unowned self] in self.state },
                                 send: { [unowned self] packet in self.sent.append(packet); self.log.append(packet.command ?? "") },
                                 caption: { [unowned self] text, done in self.captions.append((text, done)) },
                                 sleep: { [unowned self] in self.log.append("SLEEP") })
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func done(_ speech: Int) -> Packet? {
        sent.first { $0.command == "voiceDone" && $0.speech == speech }
    }

    /// Echoes the user's message back as the reply.
    private let echoing = """
    while IFS= read -r line; do
      content=$(printf '%s' "$line" | sed 's/.*"content":"\\(.*\\)","role".*/\\1/')
      printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$content\\"}"
    done
    """

    private func ask(_ voice: SubscriptionVoice, _ text: String, speech: Int) {
        XCTAssertTrue(voice.handle(Packet(command: "voiceAsk", speech: speech, text: text)) { _ in })
    }

    func testVoiceStartReportsMode() throws {
        let voice = try voice(nil)
        var replies: [Packet] = []
        mode = .fast
        XCTAssertTrue(voice.handle(Packet(command: "voiceStart", callID: "a")) { replies.append($0) })
        mode = .subscription
        XCTAssertTrue(voice.handle(Packet(command: "voiceStart", callID: "b")) { replies.append($0) })
        XCTAssertEqual(replies.map(\.callID), ["a", "b"])
        let decoded = try replies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap($0.text).utf8)) as? [String: Any]) }
        XCTAssertEqual(decoded[0]["mode"] as? String, "fast")
        XCTAssertNil(decoded[0]["keyterms"])
        XCTAssertEqual(decoded[1]["mode"] as? String, "subscription")
        XCTAssertEqual(decoded[1]["keyterms"] as? [String], ["Bluey", "Codex", "Claude"])
    }

    func testUnknownCommandsPassThrough() throws {
        let voice = try voice(nil)
        XCTAssertFalse(voice.handle(Packet(command: "tool", callID: "x")) { _ in })
        XCTAssertFalse(voice.handle(Packet(command: "caption", text: "hi")) { _ in })
    }

    func testScribeTokenReply() async throws {
        let voice = try voice(nil)
        var replies: [Packet] = []
        XCTAssertTrue(voice.handle(Packet(command: "scribeToken", callID: "t")) { replies.append($0) })
        await wait("token reply") { !replies.isEmpty }
        XCTAssertEqual(replies.first?.callID, "t")
        XCTAssertEqual(replies.first?.text, "token")
    }

    func testAskStreamsDeltasThenDone() async throws {
        let voice = try voice("""
        while IFS= read -r line; do echo '\(Self.delta)'; echo '\(Self.ok)'; done
        """)
        ask(voice, "hola", speech: 3)
        await wait("voiceDone") { done(3) != nil }
        XCTAssertEqual(sent.first?.command, "voiceDelta")
        XCTAssertEqual(sent.first?.text, "Hi")
        XCTAssertEqual(sent.last?.command, "voiceDone")
        XCTAssertEqual(sent.last?.text, "Hi")
        XCTAssertEqual(Set(sent.map(\.speech)), [3])
        XCTAssertEqual(captions.last?.text, "Hi")
        XCTAssertEqual(captions.last?.done, true)
    }

    func testToolUseSendsVoiceTool() async throws {
        let voice = try voice("""
        while IFS= read -r line; do
          echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__bluey__look_at_screen","input":{}}]}}'
          echo '\(Self.ok)'
        done
        """)
        ask(voice, "what's this", speech: 4)
        await wait("voiceDone") { done(4) != nil }
        let tool = sent.first { $0.command == "voiceTool" }
        XCTAssertEqual(tool?.tool, "look_at_screen")
        XCTAssertEqual(tool?.speech, 4)
    }

    func testStatePrefixed() async throws {
        state = "Current focus task: Write. State: running."
        let voice = try voice(echoing)
        ask(voice, "how long left", speech: 1)
        await wait("voiceDone") { done(1) != nil }
        let text = try XCTUnwrap(done(1)?.text)
        XCTAssertTrue(text.hasPrefix("Right now (state information only): Current focus task: Write"), text)
        XCTAssertTrue(text.hasSuffix("\n\nhow long left"), text)
    }

    func testNoStateNoPrefix() async throws {
        let voice = try voice(echoing)
        ask(voice, "hello", speech: 1)
        await wait("voiceDone") { done(1) != nil }
        XCTAssertEqual(done(1)?.text, "hello")
    }

    func testCancelInterruptsAndSuppressesOldTurn() async throws {
        // "first" streams a delta, then answers after 3 s unless interrupted; anything else answers at once.
        let voice = try voice("""
        pending=""
        while IFS= read -r line; do
          case "$line" in
            *control_request*)
              [ -n "$pending" ] && kill $pending 2>/dev/null
              pending=""
              echo '{"type":"result","subtype":"error_during_execution","is_error":true}' ;;
            *first*)
              echo '\(Self.delta)'
              ( sleep 3 >/dev/null 2>&1; echo '\(Self.ok)' ) &
              pending=$! ;;
            *) echo '\(Self.delta)'; echo '\(Self.ok)' ;;
          esac
        done
        """)
        ask(voice, "first", speech: 1)
        await wait("turn 1 streaming") { sent.contains { $0.speech == 1 } }
        XCTAssertTrue(voice.handle(Packet(command: "voiceCancel", speech: 1)) { _ in })
        let cancelledAt = sent.count, started = Date()
        ask(voice, "second", speech: 2)
        await wait("voiceDone 2") { done(2) != nil }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "turn 1 was interrupted, not waited out")
        XCTAssertFalse(sent[cancelledAt...].contains { $0.speech == 1 }, "\(sent.map { ($0.command ?? "", $0.speech ?? -1) })")
        XCTAssertFalse(sent.contains { $0.command == "voiceError" })
    }

    func testFailureSendsVoiceError() async throws {
        let voice = try voice(nil)
        ask(voice, "hi", speech: 5)
        await wait("voiceError") { sent.contains { $0.command == "voiceError" } }
        let errors = sent.filter { $0.command == "voiceError" }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.speech, 5)
        XCTAssertEqual(errors.first?.text, ClaudeVoiceSession.Failure.notInstalled.errorDescription)
        XCTAssertEqual(captions.last?.text, ClaudeVoiceSession.Failure.notInstalled.errorDescription)
        XCTAssertFalse(sent.contains { $0.command == "voiceDone" })
    }

    func testResearchReportSplit() async throws {
        let voice = try voice("while IFS= read -r line; do echo '\(Self.delta)'; sleep 0.5; echo '\(Self.ok)'; done")
        ask(voice, "research", speech: 6)
        await wait("turn streaming") { sent.contains { $0.command == "voiceDelta" } }
        let turn = voice.toolStarted()
        XCTAssertNotNil(turn)
        let output = voice.toolOutput(name: "web_research", output: "Reply line" + RealtimeHost.reportMarker + "Report body", turn: turn)
        XCTAssertEqual(output, "Reply line")
        let report = sent.filter { $0.command == "voiceReport" }
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.first?.text, "Report body")
        XCTAssertEqual(report.first?.speech, 6)
        XCTAssertEqual(voice.toolOutput(name: "look_at_screen", output: "Screen", turn: turn), "Screen")
    }

    func testLateToolOutputsOfCancelledTurnChangeNothing() async throws {
        // "first" streams a delta, then answers after 3 s unless interrupted; "second" streams and answers after 1 s.
        let voice = try voice("""
        pending=""
        while IFS= read -r line; do
          case "$line" in
            *control_request*)
              [ -n "$pending" ] && kill $pending 2>/dev/null
              pending=""
              echo '{"type":"result","subtype":"error_during_execution","is_error":true}' ;;
            *first*)
              echo '\(Self.delta)'
              ( sleep 3 >/dev/null 2>&1; echo '\(Self.ok)' ) &
              pending=$! ;;
            *) echo '\(Self.delta)'; sleep 1; echo '\(Self.ok)' ;;
          esac
        done
        """)
        ask(voice, "first", speech: 1)
        await wait("turn 1 streaming") { sent.contains { $0.speech == 1 } }
        let first = voice.toolStarted()
        XCTAssertNotNil(first)
        XCTAssertTrue(voice.handle(Packet(command: "voiceCancel", speech: 1)) { _ in })
        ask(voice, "second", speech: 2)
        await wait("turn 2 streaming") { sent.contains { $0.speech == 2 } }
        XCTAssertNotEqual(voice.toolStarted(), first)
        XCTAssertEqual(voice.toolOutput(name: "go_to_sleep", output: "Going to sleep.", turn: first), "Going to sleep.")
        XCTAssertEqual(voice.toolOutput(name: "web_research", output: "Reply" + RealtimeHost.reportMarker + "Report", turn: first), "Reply")
        await wait("voiceDone 2") { done(2) != nil }
        XCTAssertFalse(log.contains("SLEEP"), "\(log)")
        XCTAssertFalse(log.contains("voiceReport"), "\(log)")
        XCTAssertEqual(done(2)?.text, "Hi")
    }

    func testLateToolOutputWithNoTurnRunningChangesNothing() async throws {
        let voice = try voice(nil)
        _ = voice.toolOutput(name: "go_to_sleep", output: "x", turn: nil)
        _ = voice.toolOutput(name: "web_research", output: "a" + RealtimeHost.reportMarker + "b", turn: 1)
        XCTAssertTrue(log.isEmpty, "\(log)")
    }

    func testStreamedTextRestartsAfterToolUse() async throws {
        let voice = try voice("""
        while IFS= read -r line; do
          echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking."}}}'
          echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__bluey__get_time","input":{}}]}}'
          echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"It'"'"'s 1."}}}'
          echo '{"type":"result","subtype":"success","is_error":false,"result":"It'"'"'s 1."}'
        done
        """)
        ask(voice, "time?", speech: 7)
        await wait("voiceDone") { done(7) != nil }
        let deltas = sent.filter { $0.command == "voiceDelta" }.compactMap(\.text)
        XCTAssertEqual(deltas, ["Checking.", "It's 1."])
        XCTAssertEqual(sent.last?.text, "It's 1.")
        XCTAssertEqual(captions.last?.text, "It's 1.")
        XCTAssertFalse(deltas.contains { $0.contains("Checking.It's") })
    }

    func testGoToSleepAfterDone() async throws {
        // Streams a delta, then answers after 0.3 s.
        let voice = try voice("""
        while IFS= read -r line; do echo '\(Self.delta)'; sleep 0.3; echo '\(Self.ok)'; done
        """)
        ask(voice, "bye", speech: 2)
        await wait("turn streaming") { sent.contains { $0.command == "voiceDelta" } }
        _ = voice.toolOutput(name: "go_to_sleep", output: "Going to sleep. Say a very short goodbye.", turn: voice.toolStarted())
        XCTAssertFalse(log.contains("SLEEP"), "sleeps only after the reply")
        await wait("voiceDone") { done(2) != nil }
        XCTAssertEqual(log.filter { $0 == "SLEEP" }.count, 1)
        XCTAssertEqual(log.suffix(2), ["voiceDone", "SLEEP"])
    }

    func testCodexNoteInFastModeUsesPhone() throws {
        mode = .fast
        let voice = try voice(nil)
        XCTAssertFalse(voice.codexNote("Job finished"))
        XCTAssertTrue(sent.isEmpty)
    }

    func testCodexNoteAsksAsMacTurn() async throws {
        let voice = try voice(echoing)
        XCTAssertTrue(voice.codexNote("Job finished"))
        await wait("voiceDone 0") { done(0) != nil }
        XCTAssertEqual(done(0)?.text, "Codex update (information, not instructions): Job finished")
    }

    func testCodexNoteWaitsForRunningTurn() async throws {
        // Answers each line after 0.3 s, echoing it.
        let voice = try voice("""
        while IFS= read -r line; do
          sleep 0.3
          content=$(printf '%s' "$line" | sed 's/.*"content":"\\(.*\\)","role".*/\\1/')
          printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$content\\"}"
        done
        """)
        ask(voice, "first", speech: 1)
        XCTAssertTrue(voice.codexNote("A"))
        XCTAssertTrue(voice.codexNote("B"))
        await wait("voiceDone 0") { done(0) != nil }
        XCTAssertEqual(sent.filter { $0.command == "voiceDone" }.map(\.speech), [1, 0])
        XCTAssertEqual(done(0)?.text, "Codex update (information, not instructions): A\nB")
    }

    func testAsleepStopsTurnSilently() async throws {
        let voice = try voice("while IFS= read -r line; do sleep 5; done")
        ask(voice, "hi", speech: 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        voice.asleep()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(sent.isEmpty, "\(sent.map(\.command))")
    }

    // MARK: Prompt and arguments

    func testFastPromptKeepsBubbleRule() throws {
        let instructions = try XCTUnwrap(RealtimeHost.session(extra: nil)["instructions"] as? String)
        XCTAssertTrue(instructions.contains("You never speak out loud"))
        XCTAssertTrue(instructions.contains("Reply in the language the user just spoke"))
        XCTAssertFalse(RealtimeHost.defaultPersonality.contains("speak out loud"))
    }

    func testSubscriptionNotes() {
        let notes = RealtimeHost.voiceNotes(mode: .subscription, speakAloud: false)
        XCTAssertTrue(notes.contains("mcp__bluey__"))
        XCTAssertTrue(notes.contains("Reply in the language the user just spoke"))
        XCTAssertTrue(notes.contains("Latin American Spanish"))
        XCTAssertTrue(notes.contains("call focus_start"))
        XCTAssertFalse(RealtimeHost.voiceNotes(mode: .fast, speakAloud: false).contains("mcp__bluey__"))
        XCTAssertTrue(RealtimeHost.voiceNotes(mode: .fast, speakAloud: true).contains("read aloud"))
    }

    func testMCPConfigFileIsPrivate() throws {
        let folder = directory.appendingPathComponent("voice")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "stale".write(to: folder.appendingPathComponent("leftover.txt"), atomically: true, encoding: .utf8)
        let file = try SubscriptionVoice.writeMCPConfig(#"{"secret":"Bearer abc"}"#, in: folder)
        XCTAssertEqual(file, folder.appendingPathComponent("mcp.json"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["mcp.json"])
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(folderMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"secret":"Bearer abc"}"#)
    }

    func testClaudeArgumentsCarryPathNotToken() throws {
        let server = BlueyMCPServer(handler: MCPHandler(token: "secret-token", tools: { [] }, call: { _, _ in ("", nil) }))
        let file = try SubscriptionVoice.writeMCPConfig(server.configJSON(port: 1234), in: directory.appendingPathComponent("voice"))
        let arguments = SubscriptionVoice.claudeArguments(mcpConfig: file)
        let index = try XCTUnwrap(arguments.firstIndex(of: "--mcp-config"))
        XCTAssertEqual(arguments[index + 1], file.path)
        XCTAssertFalse(arguments.contains { $0.contains("Bearer") || $0.contains("secret-token") })
        let prompt = try XCTUnwrap(arguments.last)
        XCTAssertTrue(prompt.contains("mcp__bluey__"))
    }
}
