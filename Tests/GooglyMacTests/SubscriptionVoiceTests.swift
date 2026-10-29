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
    private var speakAloud = false
    /// The sentences asked of `speak`, and how many of those requests were ended early.
    private let speech = SpeechLog()
    /// What `speak` returns for a sentence; by default one chunk holding the sentence's bytes.
    private var speakStream: (String) -> AsyncThrowingStream<Data, Error> = { sentence in
        AsyncThrowingStream { continuation in
            continuation.yield(Data(sentence.utf8))
            continuation.finish()
        }
    }

    /// Thread-safe record of what the fake speech did.
    final class SpeechLog: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = [], ended = 0
        var sentences: [String] { lock.lock(); defer { lock.unlock() }; return asked }
        var endedEarly: Int { lock.lock(); defer { lock.unlock() }; return ended }
        func ask(_ sentence: String) { lock.lock(); asked.append(sentence); lock.unlock() }
        func end() { lock.lock(); ended += 1; lock.unlock() }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = []; sent = []; captions = []; mode = .subscription; state = nil; speakAloud = false
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
                                 sleep: { [unowned self] in self.log.append("SLEEP") },
                                 speakAloud: { [unowned self] in self.speakAloud },
                                 speak: { [unowned self] sentence in
                                     self.speech.ask(sentence)
                                     return self.speakStream(sentence)
                                 })
    }

    private static func text(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
    }

    private static func result(_ text: String) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"\#(text)"}"#
    }

    /// Streams "Hola. Qué" then " tal? Bien" and ends with the whole reply.
    private var greeting: String {
        "while IFS= read -r line; do echo '\(Self.text("Hola. Qué"))'; echo '\(Self.text(" tal? Bien"))'; echo '\(Self.result("Hola. Qué tal? Bien"))'; done"
    }

    private func audio(_ speech: Int) -> [String] {
        sent.filter { $0.command == "voiceAudio" && $0.speech == speech }
            .compactMap { $0.audio.flatMap { Data(base64Encoded: $0) } }.map { String(decoding: $0, as: UTF8.self) }
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

    func testCancelClearsTheBubbleAndNothingElseFollows() async throws {
        // Streams a delta, then would answer after 3 s unless interrupted.
        let voice = try voice("""
        pending=""
        while IFS= read -r line; do
          case "$line" in
            *control_request*)
              [ -n "$pending" ] && kill $pending 2>/dev/null
              pending=""
              echo '{"type":"result","subtype":"error_during_execution","is_error":true}' ;;
            *)
              echo '\(Self.delta)'
              ( sleep 3 >/dev/null 2>&1; echo '\(Self.ok)' ) &
              pending=$! ;;
          esac
        done
        """)
        ask(voice, "first", speech: 1)
        await wait("bubble") { !captions.isEmpty }
        XCTAssertEqual(captions.last?.text, "Hi")
        XCTAssertEqual(captions.last?.done, false)
        let before = captions.count
        XCTAssertTrue(voice.handle(Packet(command: "voiceCancel", speech: 1)) { _ in })
        XCTAssertEqual(captions.count, before + 1)
        XCTAssertNil(captions.last?.text, "the cancelled reply's bubble is cleared")
        XCTAssertEqual(captions.last?.done, true)
        // Let the interrupted turn finish: it must add no caption.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(captions.count, before + 1, "\(captions)")
        XCTAssertNil(done(1))
    }

    func testCancelOfAWaitingTurnLeavesTheRunningBubbleAlone() async throws {
        let voice = try voice("""
        while IFS= read -r line; do echo '\(Self.delta)'; sleep 1; echo '\(Self.ok)'; done
        """)
        ask(voice, "first", speech: 1)
        await wait("bubble") { !captions.isEmpty }
        ask(voice, "second", speech: 2)
        let before = captions.count
        XCTAssertTrue(voice.handle(Packet(command: "voiceCancel", speech: 2)) { _ in })
        XCTAssertEqual(captions.count, before, "turn 1 is still speaking")
        await wait("voiceDone 1") { done(1) != nil }
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

    func testCodexNoteQueuedDuringGoodbyeDoesNotStartATurnAfterSleep() async throws {
        let voice = try voice("""
        while IFS= read -r line; do echo '\(Self.delta)'; sleep 0.3; echo '\(Self.ok)'; done
        """)
        ask(voice, "bye", speech: 2)
        await wait("turn streaming") { sent.contains { $0.command == "voiceDelta" } }
        _ = voice.toolOutput(name: "go_to_sleep", output: "Going to sleep.", turn: voice.toolStarted())
        XCTAssertTrue(voice.codexNote("Job finished"))
        await wait("SLEEP") { log.contains("SLEEP") }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(sent.filter { $0.command == "voiceDone" }.map(\.speech), [2], "\(log)")
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

    func testLegacyBubbleSentenceIsRemovedFromASavedPersonality() {
        let saved = "You are a small blueberry. You're a young British guy. You never speak out loud: your replies pop up as a tiny speech bubble, so keep them to one short line, under fifteen words. Answer immediately."
        XCTAssertEqual(RealtimeHost.withoutLegacySpeechRule(saved),
                       "You are a small blueberry. You're a young British guy. Keep your replies to one short line, under fifteen words. Answer immediately.")
        let edited = "Be a pirate. You never speak out loud: your replies pop up as a tiny speech bubble, so be brief, arr."
        XCTAssertEqual(RealtimeHost.withoutLegacySpeechRule(edited), "Be a pirate. Be brief, arr.")
        let mine = "I never speak out loud, mate. Keep it short."
        XCTAssertEqual(RealtimeHost.withoutLegacySpeechRule(mine), mine, "other text is left alone")
        XCTAssertEqual(RealtimeHost.withoutLegacySpeechRule(RealtimeHost.defaultPersonality), RealtimeHost.defaultPersonality)
    }

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
        let arguments = SubscriptionVoice.claudeArguments(mcpConfig: file, speakAloud: false)
        let index = try XCTUnwrap(arguments.firstIndex(of: "--mcp-config"))
        XCTAssertEqual(arguments[index + 1], file.path)
        XCTAssertFalse(arguments.contains { $0.contains("Bearer") || $0.contains("secret-token") })
        let prompt = try XCTUnwrap(arguments.last)
        XCTAssertTrue(prompt.contains("mcp__bluey__"))
        XCTAssertFalse(prompt.contains("read aloud"))
        let speaking = SubscriptionVoice.claudeArguments(mcpConfig: file, speakAloud: true)
        XCTAssertTrue(try XCTUnwrap(speaking.last).contains("also read aloud in your voice"))
        XCTAssertFalse(try XCTUnwrap(speaking.last).contains("You never speak out loud: your replies pop up"))
    }

    // MARK: Speech

    func testSpeaksSentencesInOrder() async throws {
        speakAloud = true
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 3)
        await wait("voiceAudioEnd") { sent.contains { $0.command == "voiceAudioEnd" } }
        XCTAssertEqual(audio(3), ["Hola.", "Qué tal?", "Bien"])
        XCTAssertEqual(speech.sentences, ["Hola.", "Qué tal?", "Bien"], "each sentence is asked for once")
        XCTAssertEqual(sent.last?.command, "voiceAudioEnd")
        XCTAssertEqual(sent.last?.speech, 3)
        XCTAssertEqual(Set(sent.map(\.speech)), [3])
        let done = try XCTUnwrap(sent.firstIndex { $0.command == "voiceDone" })
        let end = try XCTUnwrap(sent.firstIndex { $0.command == "voiceAudioEnd" })
        XCTAssertLessThan(done, end)
        XCTAssertEqual(sent.filter { $0.command == "voiceAudioEnd" }.count, 1)
    }

    func testSpeakAloudOff() async throws {
        speakAloud = false
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 3)
        await wait("voiceDone") { done(3) != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(sent.contains { $0.command == "voiceAudio" || $0.command == "voiceAudioEnd" })
        XCTAssertTrue(speech.sentences.isEmpty)
    }

    func testLongSpeechArrivesInOrderAsSeparateChunks() async throws {
        speakAloud = true
        speakStream = { sentence in
            AsyncThrowingStream { continuation in
                for part in 1...3 { continuation.yield(Data("\(sentence)#\(part)".utf8)) }
                continuation.finish()
            }
        }
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 1)
        await wait("voiceAudioEnd") { sent.contains { $0.command == "voiceAudioEnd" } }
        XCTAssertEqual(audio(1).count, 9)
        XCTAssertEqual(audio(1).prefix(4), ["Hola.#1", "Hola.#2", "Hola.#3", "Qué tal?#1"])
    }

    func testCancelStopsSpeech() async throws {
        speakAloud = true
        // His first sentence starts being spoken and never ends; the answer would come after 3 s unless interrupted.
        speakStream = { [speech] _ in
            AsyncThrowingStream { continuation in
                continuation.yield(Data("chunk".utf8))
                continuation.onTermination = { _ in speech.end() }
            }
        }
        let voice = try voice("""
        pending=""
        while IFS= read -r line; do
          case "$line" in
            *control_request*)
              [ -n "$pending" ] && kill $pending 2>/dev/null
              pending=""
              echo '{"type":"result","subtype":"error_during_execution","is_error":true}' ;;
            *first*)
              echo '\(Self.text("Hola. Qué"))'
              ( sleep 3 >/dev/null 2>&1; echo '\(Self.result("Hola. Qué tal"))' ) &
              pending=$! ;;
            *) echo '\(Self.result("Ok"))' ;;
          esac
        done
        """)
        ask(voice, "first", speech: 1)
        await wait("audio") { !audio(1).isEmpty }
        let before = sent.count
        XCTAssertTrue(voice.handle(Packet(command: "voiceCancel", speech: 1)) { _ in })
        await wait("the speech request ended") { speech.endedEarly == 1 }
        speakAloud = false
        ask(voice, "second", speech: 2)
        await wait("voiceDone 2") { done(2) != nil }
        XCTAssertFalse(sent[before...].contains { $0.speech == 1 }, "\(sent.map { ($0.command ?? "", $0.speech ?? -1) })")
        XCTAssertFalse(sent.contains { $0.command == "voiceAudioEnd" })
        XCTAssertEqual(speech.sentences, ["Hola."])
    }

    func testCancelWhileTheRestOfAReplyIsBeingSpokenSendsNoMoreAudio() async throws {
        speakAloud = true
        speakStream = { [speech] _ in
            AsyncThrowingStream { continuation in
                continuation.yield(Data("chunk".utf8))
                continuation.onTermination = { _ in speech.end() }
            }
        }
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 4)
        await wait("voiceDone") { done(4) != nil }
        await wait("audio") { !audio(4).isEmpty }
        let before = sent.count
        XCTAssertTrue(voice.handle(Packet(command: "voiceCancel", speech: 4)) { _ in })
        await wait("the speech request ended") { speech.endedEarly >= 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sent.count, before, "no audio and no end after the cancel")
        XCTAssertEqual(speech.sentences, ["Hola."], "the sentences still queued are dropped")
    }

    func testSpeechFailureCaptionsOnceAndTheReplyCompletes() async throws {
        speakAloud = true
        struct Boom: LocalizedError { var errorDescription: String? { "no voice today" } }
        speakStream = { _ in AsyncThrowingStream { $0.finish(throwing: Boom()) } }
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 5)
        await wait("voiceDone") { done(5) != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(done(5)?.text, "Hola. Qué tal? Bien")
        XCTAssertEqual(captions.filter { $0.text == "Couldn't speak: no voice today" }.count, 1, "\(captions)")
        XCTAssertEqual(speech.sentences, ["Hola."], "the rest of the turn is skipped after a failure")
        XCTAssertFalse(sent.contains { $0.command == "voiceAudio" || $0.command == "voiceAudioEnd" || $0.command == "voiceError" })
    }

    func testFailureAfterSomeAudioStillEndsTheAudio() async throws {
        speakAloud = true
        struct Boom: Error {}
        speakStream = { sentence in
            AsyncThrowingStream { continuation in
                continuation.yield(Data(sentence.utf8))
                if sentence != "Hola." { continuation.finish(throwing: Boom()) } else { continuation.finish() }
            }
        }
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 5)
        await wait("voiceAudioEnd") { sent.contains { $0.command == "voiceAudioEnd" } }
        XCTAssertEqual(audio(5), ["Hola.", "Qué tal?"])
        XCTAssertEqual(captions.filter { $0.text?.hasPrefix("Couldn't speak:") == true }.count, 1)
    }

    func testReplyWithNothingToSayHasNoAudioEnd() async throws {
        speakAloud = true
        let voice = try voice("while IFS= read -r line; do echo '\(Self.result(""))'; done")
        ask(voice, "do it", speech: 6)
        await wait("voiceDone") { done(6) != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(sent.contains { $0.command == "voiceAudio" || $0.command == "voiceAudioEnd" })
    }

    func testReplyWithoutStreamedDeltasIsStillSpoken() async throws {
        speakAloud = true
        let voice = try voice("while IFS= read -r line; do echo '\(Self.result("Done. Bye"))'; done")
        ask(voice, "hi", speech: 6)
        await wait("voiceAudioEnd") { sent.contains { $0.command == "voiceAudioEnd" } }
        XCTAssertEqual(audio(6), ["Done.", "Bye"])
    }

    func testLineBeforeAToolIsSpokenOnceAndOnlyTheFinalSegmentRepeatsNothing() async throws {
        speakAloud = true
        let voice = try voice("""
        while IFS= read -r line; do
          echo '\(Self.text("One sec. Doing some research…"))'
          echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__bluey__web_research","input":{}}]}}'
          echo '\(Self.text("It is sunny. Enjoy"))'
          echo '\(Self.result("It is sunny. Enjoy"))'
        done
        """)
        ask(voice, "weather", speech: 7)
        await wait("voiceAudioEnd") { sent.contains { $0.command == "voiceAudioEnd" } }
        XCTAssertEqual(audio(7), ["One sec.", "Doing some research…", "It is sunny.", "Enjoy"])
    }

    func testCodexTurnIsSpokenToo() async throws {
        speakAloud = true
        let voice = try voice(greeting)
        XCTAssertTrue(voice.codexNote("Job finished"))
        await wait("voiceAudioEnd") { sent.contains { $0.command == "voiceAudioEnd" } }
        XCTAssertEqual(audio(0), ["Hola.", "Qué tal?", "Bien"])
    }

    func testGoToSleepWaitsForTheGoodbyeAudio() async throws {
        speakAloud = true
        speakStream = { sentence in
            AsyncThrowingStream { continuation in
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continuation.yield(Data(sentence.utf8))
                    continuation.finish()
                }
            }
        }
        let voice = try voice("""
        while IFS= read -r line; do echo '\(Self.text("Bye."))'; sleep 0.2; echo '\(Self.result("Bye."))'; done
        """)
        ask(voice, "bye", speech: 2)
        await wait("turn streaming") { sent.contains { $0.command == "voiceDelta" } }
        _ = voice.toolOutput(name: "go_to_sleep", output: "Going to sleep.", turn: voice.toolStarted())
        await wait("SLEEP") { log.contains("SLEEP") }
        XCTAssertEqual(log.filter { $0 == "SLEEP" }.count, 1)
        XCTAssertEqual(Array(log.suffix(4)), ["voiceDone", "voiceAudio", "voiceAudioEnd", "SLEEP"], "he sleeps only after the goodbye was heard")
        XCTAssertEqual(audio(2), ["Bye."])
    }

    func testAsleepSilencesSpeech() async throws {
        speakAloud = true
        speakStream = { [speech] _ in
            AsyncThrowingStream { continuation in
                continuation.yield(Data("chunk".utf8))
                continuation.onTermination = { _ in speech.end() }
            }
        }
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 1)
        await wait("audio") { !audio(1).isEmpty }
        let before = sent.count
        voice.asleep()
        await wait("the speech request ended") { speech.endedEarly >= 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sent.count, before)
    }

    // MARK: Barge-in and wind-down

    /// Each sentence takes half a second to arrive, so a three-sentence reply keeps speaking for well over a second.
    private func slowSpeech() {
        speakStream = { sentence in
            AsyncThrowingStream { continuation in
                let wait = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    continuation.yield(Data(sentence.utf8))
                    continuation.finish()
                }
                continuation.onTermination = { _ in wait.cancel() }
            }
        }
    }

    private func index(_ command: String, _ speech: Int) -> Int? {
        sent.firstIndex { $0.command == command && $0.speech == speech }
    }

    func testNewQuestionSilencesTheAudioOfAFinishedReplyAndStartsRightAway() async throws {
        speakAloud = true
        slowSpeech()
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 1)
        await wait("voiceDone 1") { done(1) != nil }
        await wait("first audio") { !audio(1).isEmpty }
        let before = sent.count
        ask(voice, "again", speech: 2)
        await wait("the new turn's first delta") { index("voiceDelta", 2) != nil }
        XCTAssertNil(index("voiceAudioEnd", 1), "the old turn didn't finish its speech first: \(sent.map { ($0.command ?? "", $0.speech ?? -1) })")
        await wait("voiceAudioEnd 2") { index("voiceAudioEnd", 2) != nil }
        XCTAssertFalse(sent[before...].contains { $0.speech == 1 }, "nothing of the old turn after the ask")
        XCTAssertEqual(audio(1), ["Hola."])
        XCTAssertEqual(audio(2), ["Hola.", "Qué tal?", "Bien"])
    }

    func testNewQuestionAsSpeechZeroAlsoSilencesAFinishedReply() async throws {
        speakAloud = true
        slowSpeech()
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 1)
        await wait("voiceDone 1") { done(1) != nil }
        await wait("first audio") { !audio(1).isEmpty }
        let before = sent.count
        ask(voice, "again", speech: 0)
        await wait("voiceAudioEnd 0") { index("voiceAudioEnd", 0) != nil }
        XCTAssertFalse(sent[before...].contains { $0.speech == 1 })
        XCTAssertNil(index("voiceAudioEnd", 1))
    }

    func testNewQuestionAlsoCutsACodexTurnsAudio() async throws {
        speakAloud = true
        slowSpeech()
        let voice = try voice(greeting)
        XCTAssertTrue(voice.codexNote("Job finished"))
        await wait("voiceDone 0") { done(0) != nil }
        await wait("first audio") { !audio(0).isEmpty }
        let before = sent.count
        ask(voice, "hola", speech: 1)
        await wait("voiceAudioEnd 1") { index("voiceAudioEnd", 1) != nil }
        XCTAssertNil(index("voiceAudioEnd", 0), "a cut-off turn gets no end")
        XCTAssertFalse(sent[before...].contains { $0.speech == 0 }, "nothing of the Codex turn after the question")
        XCTAssertEqual(audio(0), ["Hola."])
        XCTAssertEqual(audio(1), ["Hola.", "Qué tal?", "Bien"])
    }

    func testNewQuestionCancelsAPendingSleepOfTheSilencedTurn() async throws {
        speakAloud = true
        slowSpeech()
        let voice = try voice("""
        while IFS= read -r line; do echo '\(Self.text("Bye. See you"))'; echo '\(Self.result("Bye. See you"))'; done
        """)
        ask(voice, "bye", speech: 1)
        await wait("turn streaming") { index("voiceDelta", 1) != nil }
        _ = voice.toolOutput(name: "go_to_sleep", output: "Going to sleep.", turn: voice.toolStarted())
        await wait("voiceDone 1") { done(1) != nil }
        await wait("first audio") { !audio(1).isEmpty }
        ask(voice, "wait, one more thing", speech: 2)
        await wait("voiceAudioEnd 2") { index("voiceAudioEnd", 2) != nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(log.contains("SLEEP"), "he was spoken to again, so he stays awake: \(log)")
    }

    func testCodexNoteWaitsForTheRunningTurnsAudioToEnd() async throws {
        speakAloud = true
        slowSpeech()
        let voice = try voice(greeting)
        ask(voice, "hola", speech: 1)
        await wait("voiceDone 1") { done(1) != nil }
        XCTAssertTrue(voice.codexNote("Job finished"))
        await wait("voiceDone 0") { done(0) != nil }
        let end = try XCTUnwrap(index("voiceAudioEnd", 1), "the first turn's audio ran to its end")
        XCTAssertLessThan(end, try XCTUnwrap(index("voiceDone", 0)))
        XCTAssertEqual(audio(1), ["Hola.", "Qué tal?", "Bien"])
    }

    func testClaudeFailingAfterSomeAudioEndsTheAudioBeforeTheError() async throws {
        speakAloud = true
        slowSpeech()
        let voice = try voice("""
        while IFS= read -r line; do
          echo '\(Self.text("Hola. Qué"))'
          sleep 0.8
          echo '{"type":"result","subtype":"error_during_execution","is_error":true}'
        done
        """)
        ask(voice, "hola", speech: 1)
        await wait("voiceError") { index("voiceError", 1) != nil }
        let end = try XCTUnwrap(index("voiceAudioEnd", 1), "\(sent.map { ($0.command ?? "", $0.speech ?? -1) })")
        XCTAssertLessThan(end, try XCTUnwrap(index("voiceError", 1)))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(sent.filter { $0.command == "voiceAudioEnd" }.count, 1)
        XCTAssertEqual(sent.last?.command, "voiceError", "no audio after the end")
    }

    func testClaudeFailingBeforeAnyAudioSendsNoAudioEnd() async throws {
        speakAloud = true
        let voice = try voice("""
        while IFS= read -r line; do echo '{"type":"result","subtype":"error_during_execution","is_error":true}'; done
        """)
        ask(voice, "hola", speech: 1)
        await wait("voiceError") { index("voiceError", 1) != nil }
        XCTAssertNil(index("voiceAudioEnd", 1))
    }

    func testFinishedTurnsLetGoOfTheirAudio() async throws {
        speakAloud = true
        let voice = try voice(greeting)
        let baseline = SubscriptionVoice.liveTurnAudio
        for speech in 1...3 {
            ask(voice, "hola", speech: speech)
            await wait("voiceAudioEnd \(speech)") { index("voiceAudioEnd", speech) != nil }
        }
        await wait("the audio let go") { SubscriptionVoice.liveTurnAudio <= baseline }
    }

    func testGoToSleepStillSleepsWhenSpeechFails() async throws {
        speakAloud = true
        struct Boom: Error {}
        speakStream = { _ in AsyncThrowingStream { $0.finish(throwing: Boom()) } }
        let voice = try voice("""
        while IFS= read -r line; do echo '\(Self.text("Bye."))'; sleep 0.2; echo '\(Self.result("Bye."))'; done
        """)
        ask(voice, "bye", speech: 2)
        await wait("turn streaming") { index("voiceDelta", 2) != nil }
        _ = voice.toolOutput(name: "go_to_sleep", output: "Going to sleep.", turn: voice.toolStarted())
        await wait("SLEEP") { log.contains("SLEEP") }
        XCTAssertEqual(log.filter { $0 == "SLEEP" }.count, 1)
        XCTAssertFalse(sent.contains { $0.command == "voiceAudio" || $0.command == "voiceAudioEnd" })
    }

    func testGoToSleepStillSleepsWithSpeakAloudOff() async throws {
        speakAloud = false
        let voice = try voice("""
        while IFS= read -r line; do echo '\(Self.text("Bye."))'; sleep 0.2; echo '\(Self.result("Bye."))'; done
        """)
        ask(voice, "bye", speech: 2)
        await wait("turn streaming") { index("voiceDelta", 2) != nil }
        _ = voice.toolOutput(name: "go_to_sleep", output: "Going to sleep.", turn: voice.toolStarted())
        await wait("SLEEP") { log.contains("SLEEP") }
        XCTAssertEqual(Array(log.suffix(2)), ["voiceDone", "SLEEP"])
        XCTAssertTrue(speech.sentences.isEmpty)
    }
}
