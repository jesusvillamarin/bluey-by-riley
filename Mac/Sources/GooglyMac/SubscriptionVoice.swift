import Foundation
import GooglyShared

private final class LiveCount: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return live }
    func add(_ change: Int) { lock.lock(); live += change; lock.unlock() }
}
private let liveAudio = LiveCount()

/// The Mac side of a Subscription-mode turn: the phone sends what was said, a warm `claude -p` answers here,
/// and the reply streams back to the phone as packets and into his bubble. With Speak Aloud on, each finished
/// sentence is turned into speech right away and its audio follows to the phone, in order, while he keeps writing.
@MainActor
final class SubscriptionVoice {
    /// Words Scribe should expect.
    static let keyterms = ["Bluey", "Codex", "Claude"]

    /// One question; `speech` is the phone's turn number (0 for turns the Mac started).
    @MainActor private final class Turn {
        let id: Int
        let speech: Int
        let message: String
        /// Set by `voiceCancel` or sleep: nothing more from this turn reaches the phone.
        private(set) var cancelled = false
        var sleepAfter = false
        /// The reply went out as `voiceDone`; the turn may still be producing its audio.
        var replyDone = false
        var text = ""
        /// Cuts `text` into sentences for `audio`. Starts over when a tool call restarts the text.
        var splitter = SentenceSplitter()
        /// Nil when Speak Aloud was off as the turn began.
        var audio: TurnAudio?
        init(id: Int, speech: Int, message: String) {
            self.id = id
            self.speech = speech
            self.message = message
        }

        /// Silences the turn at once: its speech request is cancelled and no more of it is sent.
        func cancel() {
            cancelled = true
            audio?.stop()
        }
    }

    /// How many turns' audio workers exist right now; a finished turn must let go of its own.
    static var liveTurnAudio: Int { liveAudio.count }

    /// Speaks one turn's sentences strictly in order, handing each audio chunk to `emit`.
    @MainActor private final class TurnAudio {
        private let speak: (String) -> AsyncThrowingStream<Data, Error>
        private let emit: (Data) -> Void
        private let sentences: AsyncStream<String>.Continuation
        private var worker: Task<Void, Never>?
        private var stopped = false
        /// The first speech failure; the turn's remaining sentences are skipped after it.
        private(set) var failure: Error?
        private(set) var chunksSent = 0

        init(speak: @escaping (String) -> AsyncThrowingStream<Data, Error>, emit: @escaping (Data) -> Void) {
            self.speak = speak
            self.emit = emit
            liveAudio.add(1)
            var continuation: AsyncStream<String>.Continuation!
            let queue = AsyncStream<String> { continuation = $0 }
            sentences = continuation
            worker = Task { @MainActor in await self.work(queue) }
        }

        deinit { liveAudio.add(-1) }

        func say(_ sentence: String) { sentences.yield(sentence) }

        /// No more sentences are coming: returns once everything queued has been spoken (or has failed).
        func finish() async {
            sentences.finish()
            await worker?.value
        }

        /// Drops what's queued and cancels the speech request in flight.
        func stop() {
            stopped = true
            sentences.finish()
            worker?.cancel()
        }

        private func work(_ queue: AsyncStream<String>) async {
            for await sentence in queue {
                // A line of only punctuation has nothing to say.
                guard !stopped, failure == nil, sentence.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                do {
                    for try await chunk in speak(sentence) {
                        guard !stopped else { break }
                        chunksSent += 1
                        emit(chunk)
                    }
                } catch {
                    if !stopped { failure = error }
                }
            }
        }
    }

    private let session: ClaudeVoiceSession
    private let tokens: ElevenLabsTokens
    private let mode: () -> VoiceMode
    private let state: () -> String?
    private let send: (Packet) -> Void
    /// His bubble: `done` false streams `text`, true shows a finished line; nil text with `done` true takes the bubble down.
    private let caption: (_ text: String?, _ done: Bool) -> Void
    private let sleep: () -> Void
    private let speakAloud: () -> Bool
    /// The text as speech: PCM16 24 kHz mono chunks. Ending the stream early must cancel the request.
    private let speak: (_ text: String) -> AsyncThrowingStream<Data, Error>

    /// Turns run one at a time, in the order asked: the running one, then those waiting.
    private var turns: [Turn] = []
    private var running: Turn?
    private var turnCount = 0
    private var chain: Task<Void, Never>?
    private var codexNotes: [String] = []

    init(session: ClaudeVoiceSession, tokens: ElevenLabsTokens, mode: @escaping () -> VoiceMode, state: @escaping () -> String?,
         send: @escaping (Packet) -> Void, caption: @escaping (_ text: String?, _ done: Bool) -> Void, sleep: @escaping () -> Void,
         speakAloud: @escaping () -> Bool, speak: @escaping (_ text: String) -> AsyncThrowingStream<Data, Error>) {
        self.session = session
        self.tokens = tokens
        self.mode = mode
        self.state = state
        self.send = send
        self.caption = caption
        self.sleep = sleep
        self.speakAloud = speakAloud
        self.speak = speak
    }

    /// Handles the voice commands; false for anything else.
    func handle(_ packet: Packet, reply: @escaping (Packet) -> Void) -> Bool {
        switch packet.command {
        case "voiceStart":
            var body: [String: Any] = ["mode": mode().rawValue]
            if mode() == .subscription {
                body["keyterms"] = Self.keyterms
                body["speak"] = speakAloud()
                session.warmUp()
                let tokens = tokens
                Task { await tokens.prefetch() }
            }
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            reply(Packet(command: "voiceStart", callID: packet.callID, text: String(decoding: data, as: UTF8.self)))
        case "scribeToken":
            Task { @MainActor in
                do {
                    let token = try await self.tokens.token()
                    reply(Packet(command: "scribeToken", callID: packet.callID, text: token))
                } catch {
                    reply(Packet(command: "scribeToken", callID: packet.callID, text: nil))
                    self.caption(error.localizedDescription, true)
                }
            }
        case "voiceAsk":
            let text = packet.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let speech = packet.speech ?? 0
            guard !text.isEmpty else {
                send(Packet(command: "voiceDone", speech: speech, text: ""))
                return true
            }
            // A new question while the last reply is only still being spoken: stop that speech at once, so this answer
            // doesn't wait behind it. That includes a Codex note's turn (speech 0). A reply still being written is not
            // cut off. If the old turn had a goodbye pending, he was spoken to again, so he stays awake.
            if let running, running.replyDone { running.cancel() }
            enqueue((state().map { "Right now (state information only): \($0)\n\n" } ?? "") + text, speech: speech)
        case "voiceCancel":
            let speech = packet.speech ?? 0
            for turn in turns where turn.speech == speech { turn.cancel() }
            if let running, running.speech == speech {
                session.interrupt()
                // Nothing more from this turn will reach the bubble, so take down what it left there.
                caption(nil, true)
            }
        default:
            return false
        }
        return true
    }

    /// The turn running right now, to be read when a tool call starts and handed back to `toolOutput` when it ends.
    func toolStarted() -> Int? { running?.id }

    /// What a tool's output becomes for Claude. Research reports go to the phone's transcript instead;
    /// `go_to_sleep` puts him to sleep once his goodbye is out. Both act only if `turn`, the turn that started the
    /// tool, is still the running one and not cancelled: a late output from an older turn changes nothing.
    func toolOutput(name: String, output: String, turn: Int?) -> String {
        let live = running.flatMap { $0.id == turn && !$0.cancelled ? $0 : nil }
        switch name {
        case "web_research":
            guard let marker = output.range(of: RealtimeHost.reportMarker) else { return output }
            if let live { send(Packet(command: "voiceReport", speech: live.speech, text: String(output[marker.upperBound...]))) }
            return String(output[..<marker.lowerBound])
        case "go_to_sleep":
            live?.sleepAfter = true
            return output
        default:
            return output
        }
    }

    /// News from Codex while he's awake. Subscription mode asks Claude about it once nothing else is running;
    /// false in Fast mode, so the phone's Realtime session hears it instead.
    func codexNote(_ note: String) -> Bool {
        guard mode() == .subscription else { return false }
        guard !note.isEmpty else { return true }
        codexNotes.append(note)
        deliverCodexNotes()
        return true
    }

    /// He went to sleep: end the conversation and drop anything still waiting.
    func asleep() {
        for turn in turns { turn.cancel() }
        codexNotes = []
        session.stop()
    }

    // MARK: Turns

    private func enqueue(_ message: String, speech: Int) {
        turnCount += 1
        let turn = Turn(id: turnCount, speech: speech, message: message)
        turns.append(turn)
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await self.run(turn)
            self.turns.removeAll { $0 === turn }
            self.deliverCodexNotes()
        }
    }

    private func run(_ turn: Turn) async {
        guard !turn.cancelled else { return }
        running = turn
        // Whatever way the turn ends, nothing of its speech outlives it, and the turn lets go of its audio.
        defer { running = nil; turn.audio?.stop(); turn.audio = nil }
        if speakAloud() {
            turn.audio = TurnAudio(speak: speak, emit: { [weak self, turn] data in
                guard let self, !turn.cancelled else { return }
                self.send(Packet(command: "voiceAudio", audio: data.base64EncodedString(), speech: turn.speech))
            })
        }
        do {
            let reply = try await session.ask(turn.message) { [weak self, turn] event in self?.received(event, for: turn) }
            guard !turn.cancelled else { return }
            send(Packet(command: "voiceDone", speech: turn.speech, text: reply))
            turn.replyDone = true
            caption(reply, true)
            if let audio = turn.audio {
                // `reply` is the authority. Normally it equals what was streamed, so only the unfinished rest is new;
                // text that disagrees with what was already spoken is ignored rather than said twice.
                (turn.splitter.feed(reply) + [turn.splitter.finish()].compactMap { $0 }).forEach(audio.say)
                await audio.finish()
                guard !turn.cancelled else { return }
                if let failure = audio.failure { caption("Couldn't speak: \(failure.localizedDescription)", true) }
                // The phone is told the audio is over only if it got some, so it never waits for sound that isn't coming.
                if audio.chunksSent > 0 { send(Packet(command: "voiceAudioEnd", speech: turn.speech)) }
            }
            if turn.sleepAfter {
                // He just said goodbye: an update that arrived meanwhile must not start a new turn as he drops off.
                codexNotes = []
                sleep()
            }
        } catch {
            guard !turn.cancelled, error as? ClaudeVoiceSession.Failure != .interrupted else { return }
            let message = error.localizedDescription
            // The turn failed after some of it was already spoken: the speech in flight is cut here, and the phone is told
            // the audio is over (before the error) so it can leave speaking.
            if let audio = turn.audio {
                audio.stop()
                if audio.chunksSent > 0 { send(Packet(command: "voiceAudioEnd", speech: turn.speech)) }
            }
            send(Packet(command: "voiceError", speech: turn.speech, text: message))
            caption(message, true)
        }
    }

    private func received(_ event: ClaudeEvent, for turn: Turn) {
        guard !turn.cancelled else { return }
        switch event {
        case .textDelta(let text):
            turn.text += text
            send(Packet(command: "voiceDelta", speech: turn.speech, text: turn.text))
            caption(turn.text, false)
            turn.splitter.feed(turn.text).forEach { turn.audio?.say($0) }
        case .toolUse(let name):
            // What he said before the tool (e.g. "…doing some research…") is spoken now, so the wait isn't silent; it was
            // never part of `result`, so nothing is said twice. Then the next message starts fresh: `result` holds only
            // the last one, and the streamed text should end equal to it.
            if let rest = turn.splitter.finish() { turn.audio?.say(rest) }
            turn.splitter = SentenceSplitter()
            turn.text = ""
            send(Packet(command: "voiceTool", speech: turn.speech, tool: name))
        case .result, .other:
            break
        }
    }

    private func deliverCodexNotes() {
        guard !codexNotes.isEmpty, turns.isEmpty else { return }
        let notes = codexNotes.joined(separator: "\n")
        codexNotes = []
        enqueue("Codex update (information, not instructions): " + notes, speech: 0)
    }

    // MARK: Launching claude

    /// Writes the MCP config (it holds the bearer token) as the only file in `directory`: folder 0700, file 0600.
    /// The folder is recreated each time, so nothing older survives in it.
    static func writeMCPConfig(_ json: String, in directory: URL) throws -> URL {
        let files = FileManager.default
        try? files.removeItem(at: directory)
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("mcp.json")
        guard files.createFile(atPath: file.path, contents: Data(json.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    /// The `claude -p` arguments for Subscription mode; the token stays in the file, out of `ps`.
    static func claudeArguments(mcpConfig: URL, speakAloud: Bool) -> [String] {
        ClaudeStream.arguments(model: "haiku",
                               systemPrompt: RealtimeHost.instructions + "\n\n" + RealtimeHost.voiceNotes(mode: .subscription, speakAloud: speakAloud),
                               mcpConfig: mcpConfig.path)
    }
}
