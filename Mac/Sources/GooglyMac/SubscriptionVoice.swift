import Foundation
import GooglyShared

/// The Mac side of a Subscription-mode turn: the phone sends what was said, a warm `claude -p` answers here,
/// and the reply streams back to the phone as packets and into his bubble.
@MainActor
final class SubscriptionVoice {
    /// Words Scribe should expect.
    static let keyterms = ["Bluey", "Codex", "Claude"]

    /// One question; `speech` is the phone's turn number (0 for turns the Mac started).
    private final class Turn {
        let id: Int
        let speech: Int
        let message: String
        /// Set by `voiceCancel` or sleep: nothing more from this turn reaches the phone.
        var cancelled = false
        var sleepAfter = false
        var text = ""
        init(id: Int, speech: Int, message: String) {
            self.id = id
            self.speech = speech
            self.message = message
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

    /// Turns run one at a time, in the order asked: the running one, then those waiting.
    private var turns: [Turn] = []
    private var running: Turn?
    private var turnCount = 0
    private var chain: Task<Void, Never>?
    private var codexNotes: [String] = []

    init(session: ClaudeVoiceSession, tokens: ElevenLabsTokens, mode: @escaping () -> VoiceMode, state: @escaping () -> String?,
         send: @escaping (Packet) -> Void, caption: @escaping (_ text: String?, _ done: Bool) -> Void, sleep: @escaping () -> Void) {
        self.session = session
        self.tokens = tokens
        self.mode = mode
        self.state = state
        self.send = send
        self.caption = caption
        self.sleep = sleep
    }

    /// Handles the voice commands; false for anything else.
    func handle(_ packet: Packet, reply: @escaping (Packet) -> Void) -> Bool {
        switch packet.command {
        case "voiceStart":
            var body: [String: Any] = ["mode": mode().rawValue]
            if mode() == .subscription {
                body["keyterms"] = Self.keyterms
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
            enqueue((state().map { "Right now (state information only): \($0)\n\n" } ?? "") + text, speech: speech)
        case "voiceCancel":
            let speech = packet.speech ?? 0
            for turn in turns where turn.speech == speech { turn.cancelled = true }
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
        for turn in turns { turn.cancelled = true }
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
        defer { running = nil }
        do {
            let reply = try await session.ask(turn.message) { [weak self, turn] event in self?.received(event, for: turn) }
            guard !turn.cancelled else { return }
            send(Packet(command: "voiceDone", speech: turn.speech, text: reply))
            caption(reply, true)
            if turn.sleepAfter {
                // He just said goodbye: an update that arrived meanwhile must not start a new turn as he drops off.
                codexNotes = []
                sleep()
            }
        } catch {
            guard !turn.cancelled, error as? ClaudeVoiceSession.Failure != .interrupted else { return }
            let message = error.localizedDescription
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
        case .toolUse(let name):
            // The next message starts fresh: `result` holds only the last one, and the streamed text should end equal to it.
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
    static func claudeArguments(mcpConfig: URL) -> [String] {
        ClaudeStream.arguments(model: "haiku",
                               systemPrompt: RealtimeHost.instructions + "\n\n" + RealtimeHost.voiceNotes(mode: .subscription, speakAloud: false),
                               mcpConfig: mcpConfig.path)
    }
}
